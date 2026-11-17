/*
 * scratch-link-gtk — UI-independent service object.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {

/**
 * Owns the WebSocket listener, the session registry and the BlueZ adapter.
 *
 * Both the GTK application and the headless application drive this object;
 * it never touches GTK directly.
 */
public class LinkService : GLib.Object {
    public signal void session_count_changed (int count);
    public signal void adapter_state_changed (Bluez.AdapterState state);
    public signal void device_seen (string object_path, string? name, int rssi,
                                    bool has_rssi, bool connected);
    public signal void device_lost (string object_path);

    public Protocol.SessionManager sessions { get; private set; }
    public Bluez.BluezAdapter bluez { get; private set; }
    public AppSettings settings { get; private set; }
    public string? listening_uri { get; private set; }
    public string? status_uri { get; private set; }
    public string? adapter { get; private set; }

    private Protocol.WebSocketServer server;
    private int min_rssi;

    public LinkService (AppSettings settings) {
        this.settings = settings;
        this.adapter = settings.adapter;
        this.min_rssi = settings.min_rssi;

        sessions = new Protocol.SessionManager ();
        bluez = new Bluez.BluezAdapter (settings.adapter);
        server = new Protocol.WebSocketServer ();

        server.client_connected.connect ((type, connection) => {
            if (type == Protocol.SessionType.BLE) {
                sessions.add (new BLE.BleSession (connection, bluez, min_rssi));
            } else {
                sessions.add (new BT.BtSession (connection, bluez));
            }
        });

        sessions.count_changed.connect ((count) => {
            session_count_changed (count);
        });

        bluez.device_added.connect (publish_device);
        bluez.device_updated.connect (publish_device);
        bluez.device_disconnected.connect (publish_device);
        bluez.device_removed.connect ((path) => device_lost (path));

        bluez.adapter_removed.connect (() => {
            Log.get_default ().warning (
                "closing all sessions because the Bluetooth adapter was removed");
            sessions.close_all ();
        });

        bluez.state_changed.connect (() => {
            adapter_state_changed (bluez.state);
        });
    }

    private void publish_device (string object_path) {
        var info = bluez.lookup (object_path);
        if (info == null) {
            return;
        }
        device_seen (object_path, info.name ?? info.alias, info.rssi,
                     info.has_rssi, info.connected);
    }

    public bool start (uint port, string address, out string error_message) throws GLib.Error {
        if (!server.start (port, address, out error_message)) {
            return false;
        }

        listening_uri = server.get_uri (Protocol.SessionType.BLE);
        status_uri = server.get_http_uri ();
        Log.get_default ().info ("Scratch Link %s listening on %s", VERSION, listening_uri);

        bluez.ensure_ready.begin ((obj, res) => {
            var ok = bluez.ensure_ready.end (res);
            if (!ok) {
                Log.get_default ().warning ("Bluetooth is not ready; BLE discovery will fail until it is");
            }
        });

        return true;
    }

    public void stop () {
        sessions.close_all ();
        // The main loop stops right after shutdown; release BlueZ resources
        // synchronously so scanning and device connections do not linger.
        bluez.shutdown ();
        server.stop ();
        listening_uri = null;
        status_uri = null;
    }

    /** Apply a new RSSI floor to this and every existing BLE session. */
    public void set_min_rssi (int value) {
        min_rssi = value;
        foreach (var session in sessions.snapshot ()) {
            var ble = session as BLE.BleSession;
            if (ble != null) {
                ble.min_rssi = value;
            }
        }
    }
}

} // namespace ScratchLink
