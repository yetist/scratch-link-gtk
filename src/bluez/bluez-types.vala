/*
 * scratch-link-gtk — BlueZ data types.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Bluez {

/** Coarse adapter state, used by the UI. */
public enum AdapterState {
    UNKNOWN,
    NO_ADAPTER,
    POWERED_OFF,
    READY,
    UNAUTHORIZED,
    ERROR
}

/** Which transport a shared discovery scan is currently using. */
public enum DiscoveryTransport {
    LE,
    BREDR
}

/** Snapshot of one org.bluez.Device1 object. */
public class BleDeviceInfo : GLib.Object {
    public string object_path { get; construct; }
    public string address { get; set; default = ""; }
    public string? name { get; set; }
    public string? alias { get; set; }
    public int rssi { get; set; }
    public bool has_rssi { get; set; }
    public bool connected { get; set; }
    public bool paired { get; set; }
    public bool trusted { get; set; }
    public bool services_resolved { get; set; }
    public uint32 device_class { get; set; default = 0; }
    public bool has_class { get; set; }
    public string[] uuids { get; set; }
    public GLib.HashTable<uint16, GLib.Bytes>? manufacturer_data { get; set; }
    public GLib.HashTable<string, GLib.Bytes>? service_data { get; set; }
    public int64 last_seen_usec { get; set; default = 0; }

    public BleDeviceInfo (string object_path) {
        Object (object_path: object_path);
    }
}

} // namespace Bluez
} // namespace ScratchLink
