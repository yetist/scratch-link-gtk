/*
 * scratch-link-gtk — BLE protocol session.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace BLE {

public enum BleState {
    INITIAL,
    DISCOVERY,
    CONNECTING,
    CONNECTED
}

public class BleSeenDevice : GLib.Object {
    public int64 last_report_usec;
    public int rssi;
    public string? name;
    public bool reported;
}

/** One active characteristic notification subscription. */
private class NotificationSubscription : GLib.Object {
    public string service_id;
    public string characteristic_id;
    public string encoding;

    public NotificationSubscription (string service_id, string characteristic_id,
                                     string encoding) {
        this.service_id = service_id;
        this.characteristic_id = characteristic_id;
        this.encoding = encoding;
    }
}

/**
 * One BLE client: discovery, throttled device notifications and GATT access.
 * All BlueZ calls are asynchronous and run on the main loop.
 */
public class BleSession : Protocol.Session {
    private const int64 RSSI_QUIET_USEC = 1000 * 1000;
    private const int64 REPORT_KEEPALIVE_USEC = 30 * 1000 * 1000;
    private const int RSSI_CHANGE_THRESHOLD = 4;

    private Bluez.BluezAdapter adapter;
    private BleState state = BleState.INITIAL;

    /** Peripherals weaker than this are not reported to Scratch. */
    public int min_rssi { get; set; default = AppSettings.DEFAULT_MIN_RSSI; }

    private GLib.GenericArray<ScanFilter> filters = new GLib.GenericArray<ScanFilter> ();
    private GLib.HashTable<string, bool> allowed_services = new GLib.HashTable<string, bool> (str_hash, str_equal);
    private GLib.HashTable<string, string> peripheral_ids = new GLib.HashTable<string, string> (str_hash, str_equal);
    private GLib.HashTable<string, BleSeenDevice> seen = new GLib.HashTable<string, BleSeenDevice> (str_hash, str_equal);

    private bool discovery_held = false;
    private string? connected_path;
    private Bluez.GattDevice? gatt;

    private GLib.HashTable<string, NotificationSubscription> subscriptions =
        new GLib.HashTable<string, NotificationSubscription> (str_hash, str_equal);
    private GLib.HashTable<string, GLib.Bytes> pending_changes =
        new GLib.HashTable<string, GLib.Bytes> (str_hash, str_equal);
    private uint flush_id = 0;
    private uint close_id = 0;
    private bool disconnect_reported = false;

    private ulong added_handler = 0;
    private ulong updated_handler = 0;
    private ulong removed_handler = 0;
    private ulong changed_handler = 0;
    private ulong disconnected_handler = 0;

    public BleSession (Soup.WebsocketConnection connection, Bluez.BluezAdapter adapter,
                       int min_rssi = AppSettings.DEFAULT_MIN_RSSI) {
        base (connection, Protocol.SessionType.BLE);
        this.adapter = adapter;
        this.min_rssi = min_rssi;

        added_handler = adapter.device_added.connect (on_device_changed);
        updated_handler = adapter.device_updated.connect (on_device_changed);
        removed_handler = adapter.device_removed.connect (on_device_removed);
        changed_handler = adapter.characteristic_changed.connect (on_characteristic_changed);
        disconnected_handler = adapter.device_disconnected.connect (on_device_disconnected);
        closed.connect (on_session_closed);
    }

    protected override async string? handle_request (string method, string? params_json) throws Protocol.RpcError {
        switch (method) {
        case "discover":
            return yield handle_discover (params_json);
        case "connect":
            return yield handle_connect (params_json);
        case "getServices":
            return handle_get_services ();
        case "read":
            return yield handle_read (params_json);
        case "write":
            return yield handle_write (params_json);
        case "startNotifications":
            return yield handle_start_notifications (params_json);
        case "stopNotifications":
            return yield handle_stop_notifications (params_json);
        default:
            return yield base.handle_request (method, params_json);
        }
    }

    private async string? handle_discover (string? params_json) throws Protocol.RpcError {
        if (state != BleState.INITIAL) {
            throw new Protocol.RpcError.INVALID_REQUEST ("discover is only valid before connecting");
        }

        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("discover requires a params object");
        }

        var params = root.get_object ();
        var filters_node = params.get_member ("filters");
        if (filters_node == null || filters_node.get_node_type () != Json.NodeType.ARRAY) {
            throw new Protocol.RpcError.INVALID_PARAMS ("filters must be an array");
        }

        var filters_array = filters_node.get_array ();
        if (filters_array.get_length () == 0) {
            throw new Protocol.RpcError.INVALID_PARAMS ("filters must not be empty");
        }

        var parsed_filters = new GLib.GenericArray<ScanFilter> ();
        for (uint i = 0; i < filters_array.get_length (); i++) {
            var node = filters_array.get_element (i);
            if (node.get_node_type () != Json.NodeType.OBJECT) {
                throw new Protocol.RpcError.INVALID_PARAMS ("each filter must be an object");
            }
            parsed_filters.add (ScanFilter.parse (node.get_object ()));
        }

        var allowed = new GLib.HashTable<string, bool> (str_hash, str_equal);
        var optional = params.get_member ("optionalServices");
        if (optional != null) {
            if (optional.get_node_type () != Json.NodeType.ARRAY) {
                throw new Protocol.RpcError.INVALID_PARAMS ("optionalServices must be an array");
            }
            var array = optional.get_array ();
            for (uint i = 0; i < array.get_length (); i++) {
                var uuid = resolve_uuid_node (array.get_element (i), true);
                if (uuid == null) {
                    throw new Protocol.RpcError.INVALID_PARAMS ("unable to resolve optionalServices entry");
                }
                allowed.insert ((!) uuid, true);
            }
        }

        foreach (var filter in parsed_filters) {
            foreach (var service in filter.services) {
                allowed.insert (service, true);
            }
        }

        // Everything the request needs has been copied out of the Json.Node,
        // which must not be kept across an async boundary.
        filters = parsed_filters;
        allowed_services = allowed;

        state = BleState.DISCOVERY;
        mark_discovery_started ();

        try {
            yield adapter.acquire_discovery ();
        } catch (GLib.Error e) {
            state = BleState.INITIAL;
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        discovery_held = true;
        return null;
    }

    private async string? handle_connect (string? params_json) throws Protocol.RpcError {
        if (state == BleState.CONNECTED) {
            throw new Protocol.RpcError.INVALID_REQUEST ("cannot connect when already connected");
        }
        if (state != BleState.DISCOVERY) {
            throw new Protocol.RpcError.INVALID_REQUEST ("connect is only valid after discover");
        }

        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("connect requires a params object");
        }

        var params = root.get_object ();
        var peripheral_id = optional_string (params, "peripheralId");
        if (peripheral_id == null) {
            throw new Protocol.RpcError.INVALID_PARAMS ("connect request must include peripheralId");
        }

        var path = path_for_peripheral ((!) peripheral_id);
        if (path == null || adapter.lookup ((!) path) == null) {
            throw new Protocol.RpcError.INVALID_REQUEST (
                "peripheral %s not available for connection".printf ((!) peripheral_id));
        }

        state = BleState.CONNECTING;

        // Some controllers abort a connection attempt while an LE scan is
        // running (BlueZ reports le-connection-abort-by-local), so stop
        // scanning before asking BlueZ to connect. If the connection fails we
        // resume scanning and stay in DISCOVERY.
        yield release_discovery_if_held ();

        Bluez.GattDevice? connected_gatt = null;
        try {
            connected_gatt = yield adapter.acquire_device ((!) path);
        } catch (GLib.Error e) {
            state = BleState.DISCOVERY;
            try {
                yield adapter.acquire_discovery ();
                discovery_held = true;
            } catch (GLib.Error resume_error) {
                Log.get_default ().warning ("unable to resume discovery: %s",
                                            resume_error.message);
            }
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        gatt = connected_gatt;
        connected_path = (!) path;
        state = BleState.CONNECTED;

        if (connection.state != Soup.WebsocketState.OPEN) {
            yield adapter.release_device ((!) path);
            connected_path = null;
            gatt = null;
            state = BleState.INITIAL;
        }

        return null;
    }

    private string? handle_get_services () throws Protocol.RpcError {
        require_connected ("getServices");

        var device = (!) gatt;
        var available = new GLib.GenericArray<string> ();
        foreach (var service in device.services) {
            if (allowed_services.contains (service.uuid)) {
                available.add (service.uuid);
            }
        }
        available.sort ((a, b) => strcmp (a, b));

        var builder = new Json.Builder ();
        builder.begin_array ();
        foreach (var uuid in available) {
            builder.add_string_value (uuid);
        }
        builder.end_array ();

        var root = builder.get_root ();
        if (root == null) {
            return "[]";
        }
        return Json.to_string ((!) root, false);
    }

    private async string? handle_read (string? params_json) throws Protocol.RpcError {
        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("read requires a params object");
        }

        var params = root.get_object ();
        var encoding = optional_string (params, "encoding") ?? "base64";
        if (encoding != "base64") {
            throw new Protocol.RpcError.INVALID_PARAMS ("unsupported encoding: %s".printf (encoding));
        }

        var start_notifications = optional_bool (params, "startNotifications");
        var endpoint = resolve_endpoint ("read", params, GattAccess.READ);
        if (!endpoint.characteristic.can_read ()) {
            throw new Protocol.RpcError.APPLICATION_ERROR (
                "characteristic is not readable: %s".printf (endpoint.characteristic.uuid));
        }

        GLib.Bytes value;
        try {
            value = yield adapter.read_characteristic (endpoint.characteristic.object_path);
        } catch (GLib.Error e) {
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        if (start_notifications) {
            yield start_notify (endpoint, "base64");
        }

        var data = value.get_data ();
        if (data == null) {
            return "\"\"";
        }
        return "\"%s\"".printf (encode_base64 ((!) data));
    }

    private async string? handle_start_notifications (string? params_json) throws Protocol.RpcError {
        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("startNotifications requires a params object");
        }

        var params = root.get_object ();
        var encoding = optional_string (params, "encoding") ?? "base64";
        if (encoding != "base64") {
            throw new Protocol.RpcError.INVALID_PARAMS ("unsupported encoding: %s".printf (encoding));
        }

        var endpoint = resolve_endpoint ("startNotifications", params, GattAccess.READ);
        yield start_notify (endpoint, encoding);
        return null;
    }

    private async string? handle_stop_notifications (string? params_json) throws Protocol.RpcError {
        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("stopNotifications requires a params object");
        }

        var endpoint = resolve_endpoint ("stopNotifications", root.get_object (), GattAccess.READ);
        yield stop_notify (endpoint);
        return null;
    }

    private async string? handle_write (string? params_json) throws Protocol.RpcError {
        var root = Protocol.parse_json (params_json);
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new Protocol.RpcError.INVALID_PARAMS ("write requires a params object");
        }

        var params = root.get_object ();
        var message = optional_string (params, "message");
        if (message == null) {
            throw new Protocol.RpcError.INVALID_PARAMS ("missing or invalid 'message' property");
        }

        var encoding = optional_string (params, "encoding");
        uint8[] data;
        if (encoding == null) {
            data = utf8_bytes ((!) message);
        } else if (encoding == "base64") {
            data = decode_base64 ((!) message);
        } else {
            throw new Protocol.RpcError.INVALID_PARAMS ("unsupported encoding: %s".printf ((!) encoding));
        }

        var endpoint = resolve_endpoint ("write", params, GattAccess.WRITE);
        if (!endpoint.characteristic.can_write ()) {
            throw new Protocol.RpcError.APPLICATION_ERROR (
                "characteristic is not writable: %s".printf (endpoint.characteristic.uuid));
        }

        bool explicit_response = false;
        bool with_response = !endpoint.characteristic.prefers_command ();
        if (params.has_member ("withResponse")) {
            with_response = optional_bool (params, "withResponse");
            explicit_response = true;
        }

        try {
            yield adapter.write_characteristic (endpoint.characteristic.object_path,
                                                data, with_response);
        } catch (GLib.Error e) {
            // Some peripherals do not accept "command"; retry as "request" when
            // the client did not explicitly ask for a response-less write.
            if (!with_response && !explicit_response && e.message.contains ("NotSupported")) {
                try {
                    yield adapter.write_characteristic (endpoint.characteristic.object_path,
                                                        data, true);
                } catch (GLib.Error retry_error) {
                    throw new Protocol.RpcError.APPLICATION_ERROR (retry_error.message);
                }
            } else {
                throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
            }
        }

        return data.length.to_string ();
    }

    private class Endpoint : GLib.Object {
        public Bluez.GattServiceInfo service;
        public Bluez.GattCharacteristicInfo characteristic;

        public Endpoint (Bluez.GattServiceInfo service,
                         Bluez.GattCharacteristicInfo characteristic) {
            this.service = service;
            this.characteristic = characteristic;
        }
    }

    private Endpoint resolve_endpoint (string method, Json.Object params,
                                       GattAccess access) throws Protocol.RpcError {
        require_connected (method);
        var device = (!) gatt;

        Bluez.GattServiceInfo? service = null;
        var service_node = params.get_member ("serviceId");
        if (service_node != null) {
            var service_uuid = resolve_uuid_node (service_node, true);
            if (service_uuid == null) {
                throw new Protocol.RpcError.INVALID_PARAMS ("unable to resolve service identifier");
            }
            if (!allowed_services.contains ((!) service_uuid)) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "service not allowed: %s".printf ((!) service_uuid));
            }
            service = device.service_for ((!) service_uuid);
            if (service == null) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "service not found on peripheral: %s".printf ((!) service_uuid));
            }
        } else {
            service = device.default_service (allowed_services);
            if (service == null) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "could not determine GATT service for %s".printf (method));
            }
        }

        var actual_service = (!) service;
        if (!is_access_allowed (actual_service.uuid, access)) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "service is blocked: %s".printf (actual_service.uuid));
        }

        Bluez.GattCharacteristicInfo? characteristic = null;
        var characteristic_node = params.get_member ("characteristicId");
        if (characteristic_node != null) {
            var characteristic_uuid = resolve_uuid_node (characteristic_node, false);
            if (characteristic_uuid == null) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "unable to resolve characteristic identifier");
            }
            characteristic = actual_service.characteristic_for ((!) characteristic_uuid);
            if (characteristic == null) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "characteristic not found on service: %s".printf ((!) characteristic_uuid));
            }
        } else {
            characteristic = actual_service.default_characteristic ();
            if (characteristic == null) {
                throw new Protocol.RpcError.INVALID_PARAMS (
                    "could not determine GATT characteristic for %s".printf (method));
            }
        }

        var actual_characteristic = (!) characteristic;
        if (!is_access_allowed (actual_characteristic.uuid, access)) {
            throw new Protocol.RpcError.INVALID_PARAMS (
                "characteristic is blocked: %s".printf (actual_characteristic.uuid));
        }

        return new Endpoint (actual_service, actual_characteristic);
    }

    private async void start_notify (Endpoint endpoint, string encoding) throws Protocol.RpcError {
        var path = endpoint.characteristic.object_path;
        if (subscriptions.contains (path)) {
            return;
        }

        if (!endpoint.characteristic.can_notify ()) {
            throw new Protocol.RpcError.APPLICATION_ERROR (
                "characteristic does not support notifications: %s".printf (
                    endpoint.characteristic.uuid));
        }

        if (encoding != "base64") {
            throw new Protocol.RpcError.INVALID_PARAMS ("unsupported encoding: %s".printf (encoding));
        }

        try {
            yield adapter.start_notify (path);
        } catch (GLib.Error e) {
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }

        subscriptions.insert (path, new NotificationSubscription (endpoint.service.uuid,
                                                                 endpoint.characteristic.uuid,
                                                                 encoding));
        Log.get_default ().debug ("notifications started for %s", endpoint.characteristic.uuid);
    }

    private async void stop_notify (Endpoint endpoint) throws Protocol.RpcError {
        var path = endpoint.characteristic.object_path;
        if (!subscriptions.contains (path)) {
            return;
        }

        // Stop delivering values immediately, even if the D-Bus call fails.
        subscriptions.remove (path);
        pending_changes.remove (path);

        try {
            yield adapter.stop_notify (path);
            Log.get_default ().debug ("notifications stopped for %s", endpoint.characteristic.uuid);
        } catch (GLib.Error e) {
            throw new Protocol.RpcError.APPLICATION_ERROR (e.message);
        }
    }

    private void on_characteristic_changed (string path, GLib.Bytes value) {
        if (state != BleState.CONNECTED) {
            return;
        }
        if (!subscriptions.contains (path)) {
            return;
        }

        // Keep only the newest value per characteristic: a slow client must not
        // make the pending queue grow without bound.
        pending_changes.insert (path, new GLib.Bytes.from_bytes (value, 0, value.get_size ()));
        if (flush_id == 0) {
            flush_id = GLib.Idle.add (flush_notifications);
        }
    }

    private bool flush_notifications () {
        flush_id = 0;
        if (state != BleState.CONNECTED || pending_changes.size () == 0) {
            pending_changes.remove_all ();
            return false;
        }

        var paths = pending_changes.get_keys ();
        foreach (var path in paths) {
            var subscription = subscriptions.lookup (path);
            var value = pending_changes.lookup (path);
            if (subscription == null || value == null) {
                continue;
            }

            var data = value.get_data ();
            if (data == null) {
                continue;
            }

            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("serviceId");
            builder.add_string_value (subscription.service_id);
            builder.set_member_name ("characteristicId");
            builder.add_string_value (subscription.characteristic_id);
            builder.set_member_name ("message");
            builder.add_string_value (encode_base64 ((!) data));
            builder.end_object ();

            var root = builder.get_root ();
            if (root != null) {
                send_notification ("characteristicDidChange",
                                   Json.to_string ((!) root, false));
            }
        }

        pending_changes.remove_all ();
        return false;
    }

    private void on_device_disconnected (string path) {
        if (state != BleState.CONNECTED || connected_path != path || disconnect_reported) {
            return;
        }

        disconnect_reported = true;
        Log.get_default ().info ("peripheral disconnected unexpectedly");

        clear_notifications (false);

        var lost_path = (!) connected_path;
        connected_path = null;
        gatt = null;
        state = BleState.INITIAL;
        adapter.release_device.begin (lost_path);

        send_error (null, Protocol.RpcError.APPLICATION_ERROR, "peripheral disconnected");

        // Give libsoup a chance to flush the error frame before closing.
        close_id = GLib.Timeout.add (50, () => {
            close_id = 0;
            if (connection.state == Soup.WebsocketState.OPEN) {
                connection.close ((ushort) Soup.WebsocketCloseCode.NORMAL,
                                  "peripheral disconnected");
            }
            return false;
        });
    }

    private void clear_notifications (bool stop_remote) {
        if (stop_remote) {
            foreach (var path in subscriptions.get_keys ()) {
                stop_notify_quietly (path);
            }
        }

        subscriptions.remove_all ();
        pending_changes.remove_all ();

        if (flush_id != 0) {
            GLib.Source.remove (flush_id);
            flush_id = 0;
        }
    }

    private void stop_notify_quietly (string path) {
        adapter.stop_notify.begin (path, on_stop_notify_done);
    }

    private void on_stop_notify_done (GLib.Object? source, GLib.AsyncResult res) {
        try {
            adapter.stop_notify.end (res);
        } catch (GLib.Error e) {
            Log.get_default ().debug ("StopNotify failed during cleanup: %s", e.message);
        }
    }

    private void require_connected (string method) throws Protocol.RpcError {
        if (state != BleState.CONNECTED || gatt == null) {
            throw new Protocol.RpcError.APPLICATION_ERROR (
                "Peripheral is not connected for %s".printf (method));
        }
    }

    private static string? resolve_uuid_node (Json.Node node, bool service) {
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return null;
        }

        var value_type = node.get_value_type ();
        if (value_type == typeof (string)) {
            return service ? resolve_service (node.get_string ())
                           : resolve_characteristic (node.get_string ());
        }
        if (value_type == typeof (int64)) {
            var id = node.get_int ();
            if (id < 0 || id > 0xffff) {
                return null;
            }
            return uuid_from_short ((uint16) id);
        }
        return null;
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

    private static bool optional_bool (Json.Object object, string name) throws Protocol.RpcError {
        var node = object.get_member (name);
        if (node == null) {
            return false;
        }
        if (node.get_node_type () != Json.NodeType.VALUE ||
            node.get_value_type () != typeof (bool)) {
            throw new Protocol.RpcError.INVALID_PARAMS ("%s must be a boolean".printf (name));
        }
        return node.get_boolean ();
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

    private async void release_discovery_if_held () {
        if (!discovery_held) {
            return;
        }
        discovery_held = false;
        yield adapter.release_discovery ();
    }

    private void on_device_changed (string path) {
        if (state != BleState.DISCOVERY) {
            return;
        }
        maybe_report (path);
    }

    private void on_device_removed (string path) {
        if (state != BleState.DISCOVERY) {
            return;
        }
        seen.remove (path);
    }

    private void maybe_report (string path) {
        var info = adapter.lookup (path);
        if (info == null) {
            return;
        }

        if (info.rssi < min_rssi) {
            return;
        }

        var matches = false;
        foreach (var filter in filters) {
            if (filter.matches (info)) {
                matches = true;
                break;
            }
        }

        var log = Log.get_default ();
        log.debug ("device %s name=%s rssi=%d uuids=[%s] matches=%s",
                   info.address, info.name ?? "(none)", info.rssi,
                   string.joinv (",", info.uuids), matches ? "yes" : "no");

        if (!matches) {
            return;
        }

        var now = GLib.get_monotonic_time ();
        var record = seen.lookup (path);
        if (record == null) {
            record = new BleSeenDevice ();
            seen.insert (path, record);
        }

        if (record.reported) {
            var name_appeared = info.name != null && record.name == null;
            var delta = info.rssi - record.rssi;
            if (delta < 0) {
                delta = -delta;
            }
            var rssi_changed = delta >= RSSI_CHANGE_THRESHOLD &&
                               now - record.last_report_usec >= RSSI_QUIET_USEC;
            var keepalive = now - record.last_report_usec >= REPORT_KEEPALIVE_USEC;
            if (!name_appeared && !rssi_changed && !keepalive) {
                return;
            }
        }

        var peripheral_id = peripheral_ids.lookup (path);
        if (peripheral_id == null) {
            peripheral_id = GLib.Uuid.string_random ();
            peripheral_ids.insert (path, (!) peripheral_id);
        }

        record.reported = true;
        record.rssi = info.rssi;
        record.name = info.name;
        record.last_report_usec = now;

        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("peripheralId");
        builder.add_string_value ((!) peripheral_id);
        builder.set_member_name ("name");
        if (info.name != null) {
            builder.add_string_value ((!) info.name);
        } else {
            builder.add_null_value ();
        }
        builder.set_member_name ("rssi");
        builder.add_int_value (info.rssi);
        builder.end_object ();

        var root = builder.get_root ();
        if (root == null) {
            return;
        }

        send_notification ("didDiscoverPeripheral", Json.to_string ((!) root, false));
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
        if (disconnected_handler != 0) {
            adapter.disconnect (disconnected_handler);
            disconnected_handler = 0;
        }

        if (close_id != 0) {
            GLib.Source.remove (close_id);
            close_id = 0;
        }

        clear_notifications (true);
        release_discovery_if_held.begin ();

        if (connected_path != null) {
            adapter.release_device.begin ((!) connected_path);
            connected_path = null;
        }

        gatt = null;
        state = BleState.INITIAL;

        seen.remove_all ();
        peripheral_ids.remove_all ();
    }
}

} // namespace BLE
} // namespace ScratchLink
