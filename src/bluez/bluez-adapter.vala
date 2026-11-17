/*
 * scratch-link-gtk — BlueZ adapter, device cache and discovery.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Talks to org.bluez on the system bus. Discovery and device connections
 * are process-global BlueZ resources, so this class reference-counts them
 * and is shared by every session.
 */

namespace ScratchLink {
namespace Bluez {

[DBus (name = "org.bluez.Adapter1")]
public interface Adapter1 : GLib.Object {
    [DBus (name = "StartDiscovery")]
    public abstract async void start_discovery () throws GLib.Error;

    [DBus (name = "StopDiscovery")]
    public abstract async void stop_discovery () throws GLib.Error;

    [DBus (name = "SetDiscoveryFilter")]
    public abstract async void set_discovery_filter (GLib.HashTable<string, GLib.Variant> filter) throws GLib.Error;

    public abstract string address { owned get; }
    public abstract bool powered { get; }
    public abstract bool discovering { owned get; }
}

/** Reference-counted Device1 connection, shared between sessions. */
private class DeviceLink : GLib.Object {
    public int users = 0;
    public bool owns_connection = false;
    public GattDevice? gatt;
}

public class BluezAdapter : GLib.Object {
    private const int CONNECT_TIMEOUT_MS = 30 * 1000;
    private const uint SERVICES_TIMEOUT_MS = 15 * 1000;
    private const int GATT_TIMEOUT_MS = 10 * 1000;
    private const int DISCONNECT_TIMEOUT_MS = 5 * 1000;

    public signal void device_added (string object_path);
    public signal void device_updated (string object_path);
    public signal void device_removed (string object_path);
    public signal void characteristic_changed (string object_path, GLib.Bytes value);
    public signal void device_disconnected (string object_path);
    public signal void adapter_removed ();
    public signal void state_changed ();

    public AdapterState state { get; private set; default = AdapterState.UNKNOWN; }
    public string? adapter_path { get; private set; }
    public string? adapter_name { get; private set; }

    private string? requested_adapter;
    private GLib.DBusConnection? bus;
    private Adapter1? adapter;
    private bool signals_connected = false;
    private bool initializing = false;
    private int discovery_users = 0;
    private bool discovery_owned = false;
    private DiscoveryTransport? active_discovery = null;

    private GLib.HashTable<string, BleDeviceInfo> devices =
        new GLib.HashTable<string, BleDeviceInfo> (str_hash, str_equal);

    /** Reference-counted Device1 connections, shared between sessions. */
    private GLib.HashTable<string, DeviceLink> links =
        new GLib.HashTable<string, DeviceLink> (str_hash, str_equal);

    /**
     * @param requested_adapter optional adapter name (``hci0``), ``Name`` or
     * ``Alias``. When set, no other adapter is used.
     */
    public BluezAdapter (string? requested_adapter = null) {
        this.requested_adapter = requested_adapter;
    }

    public BleDeviceInfo? lookup (string object_path) {
        return devices.lookup (object_path);
    }

    public GLib.GenericArray<string> device_paths () {
        var paths = new GLib.GenericArray<string> ();
        var iter = GLib.HashTableIter<string, BleDeviceInfo> (devices);
        unowned string path;
        unowned BleDeviceInfo info;
        while (iter.next (out path, out info)) {
            paths.add (path);
        }
        return paths;
    }

    /**
     * Connect to the system bus, find the adapter and prime the device cache.
     * Safe to call more than once; later calls return quickly.
     */
    public async bool ensure_ready () {
        if (adapter != null) {
            return true;
        }
        if (initializing) {
            return false;
        }

        initializing = true;
        try {
            return yield ensure_ready_internal ();
        } finally {
            initializing = false;
        }
    }

    private async bool ensure_ready_internal () {
        try {
            if (bus == null) {
                var connection = yield GLib.Bus.get (GLib.BusType.SYSTEM, null);
                if (connection == null) {
                    update_state (AdapterState.ERROR);
                    return false;
                }
                bus = connection;
            }

            var objects = yield get_managed_objects ();
            adapter_path = find_adapter (objects, requested_adapter);
            if (adapter_path == null) {
                update_state (AdapterState.NO_ADAPTER);
                if (requested_adapter != null) {
                    Log.get_default ().warning (
                        "requested Bluetooth adapter %s not found", requested_adapter);
                } else {
                    Log.get_default ().warning ("no Bluetooth adapter found on the system bus");
                }
                return false;
            }

            var reply = objects;
            absorb_objects (reply);

            adapter = yield bus.get_proxy<Adapter1> ("org.bluez", (!) adapter_path,
                                                     GLib.DBusProxyFlags.NONE, null);
            adapter_name = (!) adapter_path.substring ((!) adapter_path.last_index_of_char ('/') + 1);

            connect_signals ();

            if (!adapter.powered) {
                update_state (AdapterState.POWERED_OFF);
                yield try_power_on ();
            }

            update_state (adapter.powered ? AdapterState.READY : AdapterState.POWERED_OFF);
            Log.get_default ().info ("using Bluetooth adapter %s", adapter_name);
            return adapter.powered;
        } catch (GLib.Error e) {
            var message = e.message;
            update_state (message.contains ("NotAuthorized") || message.contains ("NotPermitted")
                       ? AdapterState.UNAUTHORIZED : AdapterState.ERROR);
            Log.get_default ().warning ("Bluetooth adapter unavailable: %s", message);
            return false;
        }
    }

    /**
     * Start discovery for @transport, reference-counted across sessions.
     *
     * BlueZ only keeps one discovery filter per adapter, so BLE and Classic
     * sessions cannot scan at the same time. The second transport gets a
     * clear error instead of silently stealing the other session's scan.
     */
    public async void acquire_discovery (DiscoveryTransport transport = DiscoveryTransport.LE) throws GLib.Error {
        if (adapter == null) {
            var ok = yield ensure_ready ();
            if (!ok) {
                throw new GLib.IOError.FAILED ("Bluetooth adapter is not available");
            }
        }

        if (discovery_users > 0) {
            if (active_discovery != transport) {
                throw new GLib.IOError.NOT_SUPPORTED (
                    "BLE and Bluetooth Classic discovery cannot run at the same time");
            }
            discovery_users++;
            return;
        }

        var ad = (!) adapter;
        try {
            var filter = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
            filter.insert ("Transport", new GLib.Variant.string (
                transport == DiscoveryTransport.LE ? "le" : "bredr"));
            if (transport == DiscoveryTransport.LE) {
                filter.insert ("DuplicateData", new GLib.Variant.boolean (true));
            }
            yield ad.set_discovery_filter (filter);
        } catch (GLib.Error e) {
            Log.get_default ().debug ("SetDiscoveryFilter failed (ignored): %s", e.message);
        }

        try {
            yield ad.start_discovery ();
            discovery_owned = true;
            discovery_users = 1;
            active_discovery = transport;
            Log.get_default ().debug ("discovery started (%s)",
                                      transport == DiscoveryTransport.LE ? "LE" : "BR/EDR");
        } catch (GLib.Error e) {
            if (e.message.contains ("InProgress")) {
                // Another process owns the scan; do not stop it later.
                discovery_owned = false;
                discovery_users = 1;
                active_discovery = transport;
                Log.get_default ().debug ("discovery already in progress");
            } else {
                discovery_users = 0;
                active_discovery = null;
                throw e;
            }
        }
    }

    /** Release one discovery user; stops the scan when the last one leaves. */
    public async void release_discovery () {
        if (discovery_users <= 0) {
            return;
        }

        discovery_users--;
        if (discovery_users > 0) {
            return;
        }

        var was_owned = discovery_owned;
        discovery_owned = false;
        active_discovery = null;

        if (!was_owned || adapter == null) {
            return;
        }

        var ad = (!) adapter;
        try {
            yield ad.stop_discovery ();
            Log.get_default ().debug ("discovery stopped");
        } catch (GLib.Error e) {
            Log.get_default ().debug ("StopDiscovery failed: %s", e.message);
        }
    }

    /**
     * Best-effort synchronous cleanup used when the process is about to exit.
     *
     * The main loop is no longer running at this point, so the asynchronous
     * release paths cannot finish. Stop our scan and disconnect every device
     * this process connected, ignoring individual failures.
     */
    public void shutdown () {
        var connection = bus;
        if (connection == null) {
            return;
        }

        if (discovery_owned && adapter_path != null) {
            discovery_owned = false;
            discovery_users = 0;
            active_discovery = null;
            try {
                connection.call_sync ("org.bluez", (!) adapter_path,
                                      "org.bluez.Adapter1", "StopDiscovery",
                                      null, null, GLib.DBusCallFlags.NONE,
                                      1000, null);
                Log.get_default ().debug ("discovery stopped during shutdown");
            } catch (GLib.Error e) {
                Log.get_default ().debug ("StopDiscovery during shutdown failed: %s", e.message);
            }
        }

        foreach (var path in links.get_keys ()) {
            var link = links.lookup (path);
            if (link == null || !link.owns_connection) {
                continue;
            }
            try {
                connection.call_sync ("org.bluez", path, "org.bluez.Device1",
                                      "Disconnect", null, null,
                                      GLib.DBusCallFlags.NONE, 2000, null);
                Log.get_default ().debug ("disconnected from %s during shutdown", path);
            } catch (GLib.Error e) {
                Log.get_default ().debug ("Disconnect during shutdown failed: %s", e.message);
            }
        }
        links.remove_all ();
    }

    /**
     * Connect to @object_path (or join an existing connection) and return a
     * GATT snapshot. The connection is reference-counted across sessions;
     * every successful call must be paired with release_device().
     */
    public async GattDevice acquire_device (string object_path) throws GLib.Error {
        if (bus == null) {
            throw new GLib.IOError.NOT_CONNECTED ("Bluetooth adapter is not available");
        }

        var link = links.lookup (object_path);
        if (link != null) {
            if (link.gatt != null) {
                link.users++;
                return (!) link.gatt;
            }
            throw new GLib.IOError.BUSY ("connection to this peripheral is already in progress");
        }

        var new_link = new DeviceLink ();
        new_link.users = 1;
        links.insert (object_path, new_link);

        var owns_connection = false;
        try {
            var info = devices.lookup (object_path);
            if (info == null || !info.connected) {
                try {
                    yield device_call (object_path, "Connect", CONNECT_TIMEOUT_MS);
                    owns_connection = true;
                } catch (GLib.Error e) {
                    if (!e.message.contains ("AlreadyConnected")) {
                        throw e;
                    }
                    Log.get_default ().debug ("device %s was already connected", object_path);
                }
            }
            new_link.owns_connection = owns_connection;

            if (!yield wait_services_resolved (object_path, SERVICES_TIMEOUT_MS)) {
                var latest = devices.lookup (object_path);
                if (latest == null || !latest.connected) {
                    throw new GLib.IOError.NOT_CONNECTED (
                        "peripheral disconnected during connection");
                }
                Log.get_default ().debug ("ServicesResolved timed out for %s; using cached objects",
                                          object_path);
            }

            var objects = yield get_managed_objects ();
            var gatt = build_gatt (object_path, objects);
            if (gatt == null || gatt.services.length == 0) {
                throw new GLib.IOError.FAILED ("no GATT services found");
            }

            new_link.gatt = gatt;
            Log.get_default ().debug ("connected to %s with %u service(s)",
                                      object_path, gatt.services.length);
            var log = Log.get_default ();
            foreach (var service in gatt.services) {
                log.debug ("  service %s primary=%s", service.uuid,
                           service.primary ? "yes" : "no");
                foreach (var characteristic in service.characteristics) {
                    log.debug ("    characteristic %s flags=[%s]",
                               characteristic.uuid,
                               string.joinv (",", characteristic.flags));
                }
            }

            var device_info = devices.lookup (object_path);
            if (device_info != null && device_info.name != null &&
                ((!) device_info.name).has_prefix ("BBC micro:bit") &&
                gatt.service_for ("0000f005-0000-1000-8000-00805f9b34fb") == null) {
                log.warning ("micro:bit is not running the Scratch firmware " +
                             "(missing service 0xf005); flash the Scratch micro:bit hex");
            }
            return gatt;
        } catch (GLib.Error e) {
            links.remove (object_path);
            if (owns_connection) {
                try {
                    yield device_call (object_path, "Disconnect", DISCONNECT_TIMEOUT_MS);
                } catch (GLib.Error ignored) {
                    Log.get_default ().debug ("Disconnect after failed connect: %s", ignored.message);
                }
            }
            throw e;
        }
    }

    /** Best-effort disconnect for a classic connection owned by a session. */
    public async void disconnect_device (string object_path) {
        if (bus == null) {
            return;
        }
        try {
            yield device_call (object_path, "Disconnect", DISCONNECT_TIMEOUT_MS);
            Log.get_default ().debug ("disconnected classic device %s", object_path);
        } catch (GLib.Error e) {
            Log.get_default ().debug ("classic Disconnect failed: %s", e.message);
        }
    }

    /** Release one connection user; disconnects when the last one leaves. */
    public async void release_device (string object_path) {
        var link = links.lookup (object_path);
        if (link == null) {
            return;
        }

        link.users--;
        if (link.users > 0) {
            return;
        }

        links.remove (object_path);
        if (!link.owns_connection || bus == null) {
            return;
        }

        try {
            yield device_call (object_path, "Disconnect", DISCONNECT_TIMEOUT_MS);
            Log.get_default ().debug ("disconnected from %s", object_path);
        } catch (GLib.Error e) {
            Log.get_default ().debug ("Disconnect failed: %s", e.message);
        }
    }

    /** Read the current value of a GATT characteristic. */
    public async GLib.Bytes read_characteristic (string object_path) throws GLib.Error {
        var params = new GLib.VariantBuilder (new GLib.VariantType ("(a{sv})"));
        params.add_value (build_options (null));
        var reply = yield call_bluez (object_path, "org.bluez.GattCharacteristic1", "ReadValue",
                                      params.end (),
                                      new GLib.VariantType ("(ay)"), GATT_TIMEOUT_MS);
        return reply.get_child_value (0).get_data_as_bytes ();
    }

    /** Write a value to a GATT characteristic, with or without response. */
    public async void write_characteristic (string object_path, uint8[] data,
                                            bool with_response) throws GLib.Error {
        var options = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        options.insert ("type", new GLib.Variant.string (with_response ? "request" : "command"));

        var params = new GLib.VariantBuilder (new GLib.VariantType ("(aya{sv})"));
        params.add_value (new GLib.Variant.from_bytes (new GLib.VariantType ("ay"),
                                                       new GLib.Bytes (data), true));
        params.add_value (build_options (options));
        yield call_bluez (object_path, "org.bluez.GattCharacteristic1", "WriteValue",
                          params.end (), null, GATT_TIMEOUT_MS);
    }

    /** Subscribe to characteristic value changes. */
    public async void start_notify (string object_path) throws GLib.Error {
        yield call_bluez (object_path, "org.bluez.GattCharacteristic1", "StartNotify",
                          null, null, GATT_TIMEOUT_MS);
    }

    /** Cancel characteristic value notifications. */
    public async void stop_notify (string object_path) throws GLib.Error {
        yield call_bluez (object_path, "org.bluez.GattCharacteristic1", "StopNotify",
                          null, null, GATT_TIMEOUT_MS);
    }

    private static GLib.Variant build_options (GLib.HashTable<string, GLib.Variant>? entries) {
        var dict = new GLib.VariantDict (null);
        if (entries != null) {
            var iter = GLib.HashTableIter<string, GLib.Variant> (entries);
            unowned string key;
            unowned GLib.Variant value;
            while (iter.next (out key, out value)) {
                dict.insert_value (key, value);
            }
        }
        return dict.end ();
    }

    private async void device_call (string object_path, string method, int timeout_ms) throws GLib.Error {
        yield call_bluez (object_path, "org.bluez.Device1", method, null, null, timeout_ms);
    }

    private async GLib.Variant call_bluez (string object_path, string interface_name, string method,
                                           GLib.Variant? parameters, GLib.VariantType? reply_type,
                                           int timeout_ms) throws GLib.Error {
        var connection = bus;
        if (connection == null) {
            throw new GLib.IOError.NOT_CONNECTED ("Bluetooth adapter is not available");
        }
        return yield connection.call ("org.bluez", object_path, interface_name, method,
                                      parameters, reply_type, GLib.DBusCallFlags.NONE,
                                      timeout_ms, null);
    }

    private async bool wait_services_resolved (string object_path, uint timeout_ms) {
        var info = devices.lookup (object_path);
        if (info != null && info.services_resolved) {
            return true;
        }
        if (info != null && !info.connected) {
            // The cached value may predate a successful Connect(), so confirm
            // with BlueZ before declaring the connection dead.
            if (bus == null) {
                return false;
            }
            try {
                var reply = yield bus.call ("org.bluez", object_path,
                                            "org.freedesktop.DBus.Properties", "Get",
                                            new GLib.Variant ("(ss)", "org.bluez.Device1",
                                                              "Connected"),
                                            new GLib.VariantType ("(v)"),
                                            GLib.DBusCallFlags.NONE, 1000, null);
                var connected = reply.get_child_value (0).get_variant ();
                if (!connected.get_boolean ()) {
                    return false;
                }
            } catch (GLib.Error e) {
                return false;
            }
        }

        var waiter = new AsyncWaiter (wait_services_resolved.callback, timeout_ms);
        ulong updated = device_updated.connect ((changed) => {
            if (changed != object_path) {
                return;
            }
            var current = devices.lookup (object_path);
            if (current == null) {
                return;
            }
            if (current.services_resolved) {
                waiter.finish (true);
            } else if (!current.connected) {
                // The peripheral dropped the link while BlueZ was still
                // resolving GATT, so waiting for the full timeout is pointless.
                waiter.finish (false);
            }
        });
        ulong removed = device_removed.connect ((changed) => {
            if (changed == object_path) {
                waiter.finish (false);
            }
        });

        yield;

        if (updated != 0) {
            disconnect (updated);
        }
        if (removed != 0) {
            disconnect (removed);
        }
        return waiter.succeeded;
    }

    private static GattDevice? build_gatt (string device_path, GLib.Variant objects) {
        var gatt = new GattDevice (device_path);
        var by_path = new GLib.HashTable<string, GattServiceInfo> (str_hash, str_equal);

        for (size_t i = 0; i < objects.n_children (); i++) {
            var entry = objects.get_child_value (i);
            var path = entry.get_child_value (0).get_string ();
            var interfaces = entry.get_child_value (1);

            var props = interfaces.lookup_value ("org.bluez.GattService1",
                                                 new GLib.VariantType ("a{sv}"));
            if (props == null) {
                continue;
            }

            var service_props = (!) props;
            var owner = service_props.lookup_value ("Device", null);
            if (owner == null || owner.get_string () != device_path) {
                continue;
            }

            var service = new GattServiceInfo (path);
            var uuid = service_props.lookup_value ("UUID", null);
            if (uuid != null) {
                service.uuid = BLE.normalize_full_uuid (uuid.get_string ()) ?? uuid.get_string ().down ();
            }
            var primary = service_props.lookup_value ("Primary", null);
            if (primary != null) {
                service.primary = primary.get_boolean ();
            }

            gatt.services.add (service);
            by_path.insert (path, service);
        }

        for (size_t i = 0; i < objects.n_children (); i++) {
            var entry = objects.get_child_value (i);
            var path = entry.get_child_value (0).get_string ();
            var interfaces = entry.get_child_value (1);

            var props = interfaces.lookup_value ("org.bluez.GattCharacteristic1",
                                                 new GLib.VariantType ("a{sv}"));
            if (props == null) {
                continue;
            }

            var characteristic_props = (!) props;
            var service_path = characteristic_props.lookup_value ("Service", null);
            if (service_path == null) {
                continue;
            }

            var service = by_path.lookup (service_path.get_string ());
            if (service == null) {
                continue;
            }

            var characteristic = new GattCharacteristicInfo (path);
            characteristic.service_path = service_path.get_string ();

            var uuid = characteristic_props.lookup_value ("UUID", null);
            if (uuid != null) {
                characteristic.uuid = BLE.normalize_full_uuid (uuid.get_string ()) ??
                                      uuid.get_string ().down ();
            }

            var flags = characteristic_props.lookup_value ("Flags", null);
            if (flags != null) {
                characteristic.flags = flags.dup_strv ();
            }

            var notifying = characteristic_props.lookup_value ("Notifying", null);
            if (notifying != null) {
                characteristic.notifying = notifying.get_boolean ();
            }

            service.characteristics.add (characteristic);
        }

        return gatt.services.length > 0 ? gatt : null;
    }

    private async GLib.Variant get_managed_objects () throws GLib.Error {
        var connection = (!) bus;
        var reply = yield connection.call ("org.bluez", "/", "org.freedesktop.DBus.ObjectManager",
                                        "GetManagedObjects", null,
                                        new GLib.VariantType ("(a{oa{sa{sv}}})"),
                                        GLib.DBusCallFlags.NONE, -1, null);
        return reply.get_child_value (0);
    }

    /** Adapter names currently exported by BlueZ, for the preferences dialog. */
    public static async string[] list_adapters () {
        var names = new GLib.GenericArray<string> ();
        try {
            var connection = yield GLib.Bus.get (GLib.BusType.SYSTEM, null);
            if (connection == null) {
                return new string[0];
            }

            var reply = yield connection.call ("org.bluez", "/",
                                               "org.freedesktop.DBus.ObjectManager",
                                               "GetManagedObjects", null,
                                               new GLib.VariantType ("(a{oa{sa{sv}}})"),
                                               GLib.DBusCallFlags.NONE, 3000, null);
            var objects = reply.get_child_value (0);
            for (size_t i = 0; i < objects.n_children (); i++) {
                var entry = objects.get_child_value (i);
                var interfaces = entry.get_child_value (1);
                if (interfaces.lookup_value ("org.bluez.Adapter1",
                                             new GLib.VariantType ("a{sv}")) == null) {
                    continue;
                }
                var path = entry.get_child_value (0).get_string ();
                names.add (path.substring (path.last_index_of_char ('/') + 1));
            }
        } catch (GLib.Error e) {
            Log.get_default ().debug ("unable to list Bluetooth adapters: %s", e.message);
        }

        var result = new string[names.length];
        for (uint i = 0; i < names.length; i++) {
            result[i] = names[i];
        }
        return result;
    }

    private static string? find_adapter (GLib.Variant objects, string? requested) {        for (size_t i = 0; i < objects.n_children (); i++) {
            var entry = objects.get_child_value (i);
            var interfaces = entry.get_child_value (1);
            var props = interfaces.lookup_value ("org.bluez.Adapter1",
                                                 new GLib.VariantType ("a{sv}"));
            if (props == null) {
                continue;
            }

            var path = entry.get_child_value (0).get_string ();
            if (requested == null) {
                return path;
            }

            var basename = path.substring (path.last_index_of_char ('/') + 1);
            if (basename == requested || adapter_property_matches (props, "Name", requested)
                || adapter_property_matches (props, "Alias", requested)) {
                return path;
            }
        }
        return null;
    }

    private static bool adapter_property_matches (GLib.Variant props, string key,
                                                  string requested) {
        var value = props.lookup_value (key, new GLib.VariantType ("s"));
        return value != null && ((!) value).get_string () == requested;
    }

    private void absorb_objects (GLib.Variant objects) {
        for (size_t i = 0; i < objects.n_children (); i++) {
            var entry = objects.get_child_value (i);
            var path = entry.get_child_value (0).get_string ();
            var interfaces = entry.get_child_value (1);
            var props = interfaces.lookup_value ("org.bluez.Device1",
                                                 new GLib.VariantType ("a{sv}"));
            if (props != null) {
                absorb_device_interface (path, (!) props);
            }
        }
    }

    private void connect_signals () {
        if (signals_connected || bus == null) {
            return;
        }

        bus.signal_subscribe ("org.bluez", "org.freedesktop.DBus.ObjectManager",
                              "InterfacesAdded", "/", null,
                              GLib.DBusSignalFlags.NONE, on_interfaces_added);
        bus.signal_subscribe ("org.bluez", "org.freedesktop.DBus.ObjectManager",
                              "InterfacesRemoved", "/", null,
                              GLib.DBusSignalFlags.NONE, on_interfaces_removed);
        bus.signal_subscribe ("org.bluez", "org.freedesktop.DBus.Properties",
                              "PropertiesChanged", null, null,
                              GLib.DBusSignalFlags.NONE, on_properties_changed);
        signals_connected = true;
    }

    private void on_interfaces_added (GLib.DBusConnection connection, string? sender,
                                      string object_path, string interface_name,
                                      string signal_name, GLib.Variant parameters) {
        var added_path = parameters.get_child_value (0).get_string ();
        var interfaces = parameters.get_child_value (1);

        if (interfaces.lookup_value ("org.bluez.Adapter1",
                                     new GLib.VariantType ("a{sv}")) != null) {
            if (adapter == null && !initializing) {
                Log.get_default ().info ("Bluetooth adapter appeared; initializing it");
                ensure_ready.begin ();
            }
            return;
        }

        var props = interfaces.lookup_value ("org.bluez.Device1",
                                             new GLib.VariantType ("a{sv}"));
        if (props == null) {
            return;
        }

        absorb_device_interface (added_path, (!) props);
        device_added (added_path);
    }

    private void on_interfaces_removed (GLib.DBusConnection connection, string? sender,
                                        string object_path, string interface_name,
                                        string signal_name, GLib.Variant parameters) {
        // The signal is emitted by the ObjectManager at "/", so the path of
        // the removed object is the first parameter, not the emitter path.
        var removed_path = parameters.get_child_value (0).get_string ();
        var removed = parameters.get_child_value (1).dup_strv ();
        foreach (var name in removed) {
            if (name == "org.bluez.Adapter1" &&
                adapter_path != null && removed_path == adapter_path) {
                handle_adapter_removed ();
                return;
            }
            if (name == "org.bluez.Device1") {
                var info = devices.lookup (removed_path);
                var was_connected = info != null && info.connected;
                if (devices.remove (removed_path)) {
                    device_removed (removed_path);
                }
                if (was_connected) {
                    device_disconnected (removed_path);
                }
                return;
            }
        }
    }

    /**
     * The adapter we were using disappeared (typically a USB unplug).
     *
     * Drop every cached object and connection reference, tell the UI, and let
     * LinkService close the sessions which can no longer work. If an adapter
     * appears later, InterfacesAdded triggers ensure_ready() again so the
     * service can recover without a restart.
     */
    private void handle_adapter_removed () {
        Log.get_default ().warning ("Bluetooth adapter %s was removed",
                                    adapter_name ?? "(unknown)");

        adapter = null;
        adapter_path = null;
        adapter_name = null;
        discovery_users = 0;
        discovery_owned = false;
        active_discovery = null;

        var paths = device_paths ();
        devices.remove_all ();
        links.remove_all ();
        foreach (var path in paths) {
            device_removed (path);
        }

        update_state (AdapterState.NO_ADAPTER);
        adapter_removed ();
    }

    private void on_properties_changed (GLib.DBusConnection connection, string? sender,
                                        string object_path, string interface_name,
                                        string signal_name, GLib.Variant parameters) {
        var changed_interface = parameters.get_child_value (0).get_string ();
        var changed = parameters.get_child_value (1);

        if (changed_interface == "org.bluez.Device1") {
            var info = devices.lookup (object_path);
            if (info == null) {
                return;
            }
            var was_connected = info.connected;
            update_device (info, changed);
            device_updated (object_path);
            if (was_connected && !info.connected) {
                device_disconnected (object_path);
            }
            return;
        }

        if (changed_interface == "org.bluez.GattCharacteristic1") {
            var value = changed.lookup_value ("Value", new GLib.VariantType ("ay"));
            if (value != null) {
                characteristic_changed (object_path, value.get_data_as_bytes ());
            }
            return;
        }

        if (changed_interface == "org.bluez.Adapter1" && object_path == adapter_path) {
            var powered = changed.lookup_value ("Powered", null);
            if (powered != null) {
                update_state (powered.get_boolean () ? AdapterState.READY : AdapterState.POWERED_OFF);
            }
        }
    }

    private void absorb_device_interface (string path, GLib.Variant props) {
        var info = devices.lookup (path);
        if (info == null) {
            info = new BleDeviceInfo (path);
            update_device (info, props);
            devices.insert (path, info);
        } else {
            update_device (info, props);
        }
    }

    private void update_device (BleDeviceInfo info, GLib.Variant props) {
        var value = props.lookup_value ("Address", null);
        if (value != null) {
            info.address = value.get_string ();
        }

        value = props.lookup_value ("Name", null);
        if (value != null) {
            info.name = value.dup_string ();
        }

        value = props.lookup_value ("Alias", null);
        if (value != null) {
            info.alias = value.dup_string ();
        }

        value = props.lookup_value ("RSSI", null);
        if (value != null) {
            info.rssi = value.get_int16 ();
            info.has_rssi = true;
            info.last_seen_usec = GLib.get_monotonic_time ();
        }

        value = props.lookup_value ("Connected", null);
        if (value != null) {
            info.connected = value.get_boolean ();
        }

        value = props.lookup_value ("Paired", null);
        if (value != null) {
            info.paired = value.get_boolean ();
        }

        value = props.lookup_value ("Trusted", null);
        if (value != null) {
            info.trusted = value.get_boolean ();
        }

        value = props.lookup_value ("Class", null);
        if (value != null) {
            info.device_class = value.get_uint32 ();
            info.has_class = true;
        }

        value = props.lookup_value ("ServicesResolved", null);
        if (value != null) {
            info.services_resolved = value.get_boolean ();
        }

        value = props.lookup_value ("UUIDs", null);
        if (value != null) {
            var raw = value.dup_strv ();
            var normalized = new GLib.GenericArray<string> ();
            foreach (var uuid in raw) {
                var full = BLE.normalize_full_uuid (uuid);
                normalized.add (full ?? uuid.down ());
            }
            var uuids = new string[normalized.length];
            for (uint i = 0; i < normalized.length; i++) {
                uuids[i] = normalized[i];
            }
            info.uuids = uuids;
        }

        value = props.lookup_value ("ManufacturerData", null);
        if (value != null) {
            info.manufacturer_data = parse_manufacturer_data ((!) value);
        }

        value = props.lookup_value ("ServiceData", null);
        if (value != null) {
            info.service_data = parse_service_data ((!) value);
        }
    }

    private static GLib.HashTable<uint16, GLib.Bytes> parse_manufacturer_data (GLib.Variant variant) {
        var table = new GLib.HashTable<uint16, GLib.Bytes> (direct_hash, direct_equal);
        for (size_t i = 0; i < variant.n_children (); i++) {
            var entry = variant.get_child_value (i);
            var key = entry.get_child_value (0).get_uint16 ();
            var boxed = entry.get_child_value (1).get_variant ();
            table.insert (key, boxed.get_data_as_bytes ());
        }
        return table;
    }

    private static GLib.HashTable<string, GLib.Bytes> parse_service_data (GLib.Variant variant) {
        var table = new GLib.HashTable<string, GLib.Bytes> (str_hash, str_equal);
        for (size_t i = 0; i < variant.n_children (); i++) {
            var entry = variant.get_child_value (i);
            var key = entry.get_child_value (0).get_string ();
            var boxed = entry.get_child_value (1).get_variant ();
            table.insert (key, boxed.get_data_as_bytes ());
        }
        return table;
    }

    private async void try_power_on () {
        if (bus == null || adapter_path == null) {
            return;
        }
        try {
            yield bus.call ("org.bluez", (!) adapter_path, "org.freedesktop.DBus.Properties", "Set",
                            new GLib.Variant ("(ssv)", "org.bluez.Adapter1", "Powered",
                                              new GLib.Variant.boolean (true)),
                            null, GLib.DBusCallFlags.NONE, -1, null);
            Log.get_default ().info ("asked BlueZ to power on the adapter");
        } catch (GLib.Error e) {
            Log.get_default ().warning ("unable to power on the adapter: %s", e.message);
        }
    }

    private void update_state (AdapterState new_state) {
        if (state == new_state) {
            return;
        }
        state = new_state;
        state_changed ();
    }
}

} // namespace Bluez
} // namespace ScratchLink
