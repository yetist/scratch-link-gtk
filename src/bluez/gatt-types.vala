/*
 * scratch-link-gtk — GATT service and characteristic snapshots.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Snapshots are built once after ServicesResolved, from BlueZ's managed
 * objects, and are immutable for the lifetime of a connection.
 */

namespace ScratchLink {
namespace Bluez {

public class GattCharacteristicInfo : GLib.Object {
    public string object_path;
    public string uuid = "";
    public string service_path = "";
    public string[] flags = new string[0];
    public bool notifying;

    public GattCharacteristicInfo (string object_path) {
        this.object_path = object_path;
    }

    public bool has_flag (string flag) {
        foreach (var value in flags) {
            if (value == flag) {
                return true;
            }
        }
        return false;
    }

    public bool can_read () {
        return has_flag ("read");
    }

    public bool can_write () {
        return has_flag ("write") || has_flag ("write-without-response");
    }

    public bool can_notify () {
        return has_flag ("notify") || has_flag ("indicate");
    }

    /**
     * Default write mode, matching Scratch Link: use write-without-response
     * whenever the characteristic advertises support for it.
     */
    public bool prefers_command () {
        return has_flag ("write-without-response");
    }
}

public class GattServiceInfo : GLib.Object {
    public string object_path;
    public string uuid = "";
    public bool primary;
    public GLib.GenericArray<GattCharacteristicInfo> characteristics =
        new GLib.GenericArray<GattCharacteristicInfo> ();

    public GattServiceInfo (string object_path) {
        this.object_path = object_path;
    }

    public GattCharacteristicInfo? characteristic_for (string uuid) {
        foreach (var characteristic in characteristics) {
            if (characteristic.uuid == uuid) {
                return characteristic;
            }
        }
        return null;
    }

    /** First characteristic which is not blocked in any way. */
    public GattCharacteristicInfo? default_characteristic () {
        foreach (var characteristic in characteristics) {
            if (!BLE.is_blocked (characteristic.uuid)) {
                return characteristic;
            }
        }
        return null;
    }
}

public class GattDevice : GLib.Object {
    public string object_path;
    public GLib.GenericArray<GattServiceInfo> services = new GLib.GenericArray<GattServiceInfo> ();

    public GattDevice (string object_path) {
        this.object_path = object_path;
    }

    public GattServiceInfo? service_for (string uuid) {
        foreach (var service in services) {
            if (service.uuid == uuid) {
                return service;
            }
        }
        return null;
    }

    /**
     * Web Bluetooth style default service: the first service on the
     * peripheral which the client is allowed to use and which is not
     * blocked in any way.
     */
    public GattServiceInfo? default_service (GLib.HashTable<string, bool> allowed) {
        foreach (var service in services) {
            if (allowed.contains (service.uuid) && !BLE.is_blocked (service.uuid)) {
                return service;
            }
        }
        return null;
    }
}

} // namespace Bluez
} // namespace ScratchLink
