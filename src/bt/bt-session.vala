/*
 * scratch-link-gtk — Bluetooth Classic (RFCOMM) protocol session.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace BT {

public enum BtState {
    INITIAL,
    DISCOVERY,
    CONNECTING,
    CONNECTED
}

/**
 * One Bluetooth Classic client.
 *
 * Discovery uses the shared BlueZ adapter with a BR/EDR transport filter.
 * Connections use a raw RFCOMM socket because GSocket does not support the
 * Bluetooth address family; the socket is exposed as GIO streams so reads
 * and writes stay on the main loop.
 */
public class BtSession : Protocol.Session {
    private const int READ_BUFFER_SIZE = 4096;
    private const uint8 RFCOMM_CHANNEL = 1;

    private Bluez.BluezAdapter adapter;
    private BtState state = BtState.INITIAL;

    private uint8 requested_major = 0;
    private uint8 requested_minor = 0;
    private bool discovery_held = false;

    private GLib.HashTable<string, string> peripheral_ids =
        new GLib.HashTable<string, string> (str_hash, str_equal);
    private GLib.HashTable<string, string> reported =
        new GLib.HashTable<string, string> (str_hash, str_equal);

    private string? connected_path;
    private bool owned_connection = false;
    private int fd = -1;
    private GLib.UnixInputStream? input;
    private GLib.UnixOutputStream? output;
    private GLib.Cancellable? read_cancel;
    private bool closing = false;

    private ulong added_handler = 0;
    private ulong updated_handler = 0;
    private ulong removed_handler = 0;
    private ulong changed_handler = 0;

    public BtSession (Soup.WebsocketConnection connection, Bluez.BluezAdapter adapter) {
        base (connection, Protocol.SessionType.BT);
        this.adapter = adapter;

        added_handler = adapter.device_added.connect (on_device_changed);
        updated_handler = adapter.device_updated.connect (on_device_changed);
        removed_handler = adapter.device_removed.connect (on_device_removed);
        changed_handler = adapter.device_disconnected.connect (on_device_disconnected);
        closed.connect (on_session_closed);
    }

    protected override async string? handle_request (string method,
                                                     string? params_json) throws Protocol.RpcError {
        switch (method) {
        case "discover":
            return yield handle_discover (params_json);
        case "connect":
            return yield handle_connect (params_json);
        case "send":
            return yield handle_send (params_json);
        default:
            return yield base.handle_request (method, params_json);
        }
    }

    private async string? handle_discover (string? params_json) throws Protocol.RpcError {
        if (state != BtState.INITIAL) {
            throw new Protocol.RpcError.INVALID_REQUEST (
                "discover is only valid before connecting");
        }

        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("discover requires a params object");
        }

        var params = root.get_object ();
        requested_major = required_byte (params, "majorDeviceClass");
        requested_minor = required_byte (params, "minorDeviceClass");

        state = BtState.DISCOVERY;
        mark_discovery_started ();

        try {
            yield adapter.acquire_discovery (Bluez.DiscoveryTransport.BREDR);
        } catch (GLib.Error e) {
            state = BtState.INITIAL;
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        discovery_held = true;

        // Paired devices which are already connected will not produce new
        // inquiry events, so report matching ones from the BlueZ cache.
        foreach (var path in adapter.device_paths ()) {
            var info = adapter.lookup (path);
            if (info != null && info.connected) {
                maybe_report (path);
            }
        }

        return null;
    }

    private async string? handle_connect (string? params_json) throws Protocol.RpcError {
        if (state == BtState.CONNECTED) {
            throw new Protocol.RpcError.INVALID_REQUEST ("cannot connect when already connected");
        }
        if (state != BtState.DISCOVERY) {
            throw new Protocol.RpcError.INVALID_REQUEST ("connect is only valid after discover");
        }

        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("connect requires a params object");
        }

        var params = root.get_object ();
        var peripheral_id = optional_string (params, "peripheralId");
        if (peripheral_id == null) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "connect request must include peripheralId");
        }

        var path = path_for_peripheral ((!) peripheral_id);
        var info = path != null ? adapter.lookup ((!) path) : null;
        if (path == null || info == null) {
            throw new Protocol.RpcError.INVALID_REQUEST (
                "peripheral %s not available for connection".printf ((!) peripheral_id));
        }

        var pin = optional_string (params, "pin");
        if (pin != null) {
            Log.get_default ().warning (
                "Bluetooth Classic PIN pairing is not implemented; pair the device first");
        }

        state = BtState.CONNECTING;
        yield release_discovery_if_held ();

        var device = (!) info;
        var address = device.address;
        var was_connected = device.connected;
        var rfcomm_fd = -1;

        try {
            rfcomm_fd = yield connect_rfcomm (address);
        } catch (GLib.Error e) {
            state = BtState.DISCOVERY;
            try {
                yield adapter.acquire_discovery (Bluez.DiscoveryTransport.BREDR);
                discovery_held = true;
                // The scan was restarted; announce matching devices again.
                reported.remove_all ();
            } catch (GLib.Error resume_error) {
                Log.get_default ().warning ("unable to resume classic discovery: %s",
                                            resume_error.message);
            }
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        fd = rfcomm_fd;
        input = new GLib.UnixInputStream (fd, false);
        output = new GLib.UnixOutputStream (fd, false);
        read_cancel = new GLib.Cancellable ();
        connected_path = (!) path;
        owned_connection = !was_connected;
        state = BtState.CONNECTED;

        if (connection.state != Soup.WebsocketState.OPEN) {
            close_connection ();
            connected_path = null;
            return null;
        }

        read_loop.begin ();
        Log.get_default ().info ("connected to Bluetooth Classic peripheral");
        return null;
    }

    private async string? handle_send (string? params_json) throws Protocol.RpcError {
        require_connected ("send");

        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("send requires a params object");
        }

        var params = root.get_object ();
        var message = optional_string (params, "message");
        if (message == null) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "missing or invalid 'message' property");
        }

        var encoding = optional_string (params, "encoding");
        uint8[] data;
        if (encoding == null) {
            data = BLE.utf8_bytes ((!) message);
        } else if (encoding == "base64") {
            data = BLE.decode_base64 ((!) message);
        } else {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "unsupported encoding: %s".printf (encoding));
        }

        var stream = output;
        if (stream == null) {
            throw new Protocol.RpcError.INVALID_REQUEST ("cannot send when not connected");
        }

        size_t written = 0;
        try {
            yield ((!) stream).write_all_async (data, GLib.Priority.DEFAULT, null,
                                                out written);
        } catch (GLib.Error e) {
            throw new Protocol.RpcError.INTERNAL_ERROR (e.message);
        }

        return ((uint64) written).to_string ();
    }

    private async int connect_rfcomm (string address) throws GLib.Error {
        int result_fd = -1;
        string? error_message = null;
        SourceFunc callback = connect_rfcomm.callback;

        new GLib.Thread<int> ("rfcomm-connect", () => {
            try {
                result_fd = scratch_link_rfcomm_connect (address, RFCOMM_CHANNEL);
            } catch (GLib.Error e) {
                error_message = e.message;
            }
            GLib.Idle.add (() => {
                callback ();
                return false;
            });
            return 0;
        });

        yield;

        if (error_message != null) {
            throw new GLib.IOError.FAILED ((!) error_message);
        }
        return result_fd;
    }

    private async void read_loop () {
        var stream = input;
        var cancellable = read_cancel;
        if (stream == null || cancellable == null) {
            return;
        }

        while (state == BtState.CONNECTED) {
            GLib.Bytes bytes;
            try {
                bytes = yield ((!) stream).read_bytes_async (
                    READ_BUFFER_SIZE, GLib.Priority.DEFAULT, cancellable);
            } catch (GLib.IOError.CANCELLED e) {
                break;
            } catch (GLib.Error e) {
                if (!closing) {
                    Log.get_default ().debug ("classic read failed: %s", e.message);
                }
                break;
            }

            var size = bytes.get_size ();
            if (size == 0) {
                break;
            }

            var data = new uint8[size];
            var raw = bytes.get_data ();
            for (size_t i = 0; i < size; i++) {
                data[i] = raw[i];
            }
            send_received (data);
        }

        if (!closing) {
            Log.get_default ().info ("Bluetooth Classic peripheral disconnected");
            close_connection ();
            if (connection.state == Soup.WebsocketState.OPEN) {
                connection.close ((ushort) Soup.WebsocketCloseCode.NORMAL,
                                  "peripheral disconnected");
            }
        }
    }

    private void send_received (uint8[] data) {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("message");
        builder.add_string_value (BLE.encode_base64 (data));
        builder.set_member_name ("encoding");
        builder.add_string_value ("base64");
        builder.end_object ();

        var root = builder.get_root ();
        if (root == null) {
            return;
        }
        send_notification ("didReceiveMessage", Json.to_string ((!) root, false));
    }

    private void on_device_changed (string path) {
        if (state == BtState.DISCOVERY) {
            maybe_report (path);
        }
    }

    private void on_device_removed (string path) {
        reported.remove (path);
    }

    private void on_device_disconnected (string path) {
        if (state == BtState.CONNECTED && connected_path == path) {
            // The RFCOMM read loop normally notices first, but BlueZ may
            // report the ACL drop before the socket becomes readable.
            Log.get_default ().debug ("BlueZ reports classic peripheral disconnected");
        }
    }

    private void maybe_report (string path) {
        var info = adapter.lookup (path);
        if (info == null || !info.has_class) {
            return;
        }
        if (!class_matches (info.device_class, requested_major, requested_minor)) {
            return;
        }

        var name = info.name ?? info.alias ?? info.address;
        var previous = reported.lookup (path);
        if (previous != null && previous == name) {
            return;
        }
        reported.insert (path, name);

        var peripheral_id = peripheral_ids.lookup (path);
        if (peripheral_id == null) {
            peripheral_id = GLib.Uuid.string_random ();
            peripheral_ids.insert (path, (!) peripheral_id);
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("peripheralId");
        builder.add_string_value ((!) peripheral_id);
        builder.set_member_name ("name");
        builder.add_string_value (name);
        builder.set_member_name ("rssi");
        builder.add_int_value (info.has_rssi ? info.rssi : 0);
        builder.end_object ();

        var root = builder.get_root ();
        if (root == null) {
            return;
        }

        Log.get_default ().debug ("classic device %s matches class %u:%u",
                                  info.address, requested_major, requested_minor);
        send_notification ("didDiscoverPeripheral", Json.to_string ((!) root, false));
    }

    private async void release_discovery_if_held () {
        if (!discovery_held) {
            return;
        }
        discovery_held = false;
        yield adapter.release_discovery ();
    }

    private void require_connected (string method) throws Protocol.RpcError {
        if (state != BtState.CONNECTED || output == null) {
            throw new Protocol.RpcError.INVALID_REQUEST (
                "cannot %s when not connected".printf (method));
        }
    }

    private string? path_for_peripheral (string peripheral_id) {
        var iter = GLib.HashTableIter<string, string> (peripheral_ids);
        unowned string path;
        unowned string value;
        while (iter.next (out path, out value)) {
            if (value == peripheral_id) {
                return path;
            }
        }
        return null;
    }

    private static uint8 required_byte (Json.Object params, string name) throws Protocol.RpcError {
        var node = params.get_member (name);
        if (node == null || node.get_node_type () != Json.NodeType.VALUE ||
            node.get_value_type () != typeof (int64)) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "%s must be an integer".printf (name));
        }
        var value = node.get_int ();
        if (value < 0 || value > 255) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "%s must be between 0 and 255".printf (name));
        }
        return (uint8) value;
    }

    private static string? optional_string (Json.Object object, string name) throws Protocol.RpcError {
        var node = object.get_member (name);
        if (node == null) {
            return null;
        }
        if (node.get_node_type () != Json.NodeType.VALUE ||
            node.get_value_type () != typeof (string)) {
            throw new Protocol.RpcError.INVALID_PARAMS ("%s must be a string".printf (name));
        }
        return node.get_string ();
    }

    private void close_connection () {
        closing = true;

        if (read_cancel != null) {
            read_cancel.cancel ();
            read_cancel = null;
        }

        if (input != null) {
            try {
                input.close (null);
            } catch (GLib.Error e) {
                Log.get_default ().debug ("classic input close: %s", e.message);
            }
            input = null;
        }

        if (output != null) {
            try {
                output.close (null);
            } catch (GLib.Error e) {
                Log.get_default ().debug ("classic output close: %s", e.message);
            }
            output = null;
        }

        if (fd >= 0) {
            scratch_link_rfcomm_close (fd);
            fd = -1;
        }

        state = BtState.INITIAL;
    }

    private void on_session_closed () {
        if (added_handler != 0) {
            adapter.disconnect (added_handler);
            added_handler = 0;
        }
        if (updated_handler != 0) {
            adapter.disconnect (updated_handler);
            updated_handler = 0;
        }
        if (removed_handler != 0) {
            adapter.disconnect (removed_handler);
            removed_handler = 0;
        }
        if (changed_handler != 0) {
            adapter.disconnect (changed_handler);
            changed_handler = 0;
        }

        close_connection ();

        if (discovery_held) {
            discovery_held = false;
            adapter.release_discovery.begin ();
        }

        if (owned_connection && connected_path != null) {
            adapter.disconnect_device.begin ((!) connected_path);
            owned_connection = false;
        }

        connected_path = null;
        peripheral_ids.remove_all ();
        reported.remove_all ();
    }

}

} // namespace BT
} // namespace ScratchLink
