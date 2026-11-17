/*
 * scratch-link-gtk — Web Bluetooth style GATT access policy.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The UUIDs below are the GATT block list defined by the Web Bluetooth
 * specification and by the Bluetooth SIG Assigned Numbers document:
 * https://webbluetoothcg.github.io/web-bluetooth/#the-gatt-blocklist
 * Only factual UUID/flag pairs are recorded here.
 */

namespace ScratchLink {
namespace BLE {

[Flags]
public enum GattAccess {
    NONE = 0,
    READ = 1,
    WRITE = 2
}

private static GLib.HashTable<string, GattAccess>? block_table = null;

private static void block (GLib.HashTable<string, GattAccess> table, string uuid, GattAccess access) {
    table.insert (uuid, access);
}

private static unowned GLib.HashTable<string, GattAccess> get_block_table () {
    if (block_table != null) {
        return (!) block_table;
    }

    var table = new GLib.HashTable<string, GattAccess> (str_hash, str_equal);

    // Services.

    // Human Interface Device: direct access would let a web page become a keylogger.
    block (table, "00001812-0000-1000-8000-00805f9b34fb", GattAccess.READ | GattAccess.WRITE);

    // Firmware update services which may not verify signatures.
    block (table, "00001530-1212-efde-1523-785feabcd123", GattAccess.READ | GattAccess.WRITE); // Nordic legacy DFU
    block (table, "f000ffc0-0451-4000-b000-000000000000", GattAccess.READ | GattAccess.WRITE); // TI OAD
    block (table, "00060000-0000-1000-8000-00805f9b34fb", GattAccess.READ | GattAccess.WRITE); // Cypress bootloader
    block (table, "0000fffd-0000-1000-8000-00805f9b34fb", GattAccess.READ | GattAccess.WRITE); // FIDO

    // Characteristics.

    // GAP peripheral privacy flag: do not let web pages disable privacy mode.
    block (table, "00002a02-0000-1000-8000-00805f9b34fb", GattAccess.WRITE);
    // GAP reconnection address: do not let web pages change connection parameters.
    block (table, "00002a03-0000-1000-8000-00805f9b34fb", GattAccess.READ | GattAccess.WRITE);
    // Serial number string: standardized unique identifier, blocked for privacy.
    block (table, "00002a25-0000-1000-8000-00805f9b34fb", GattAccess.READ | GattAccess.WRITE);

    // Descriptors.

    // Client/server characteristic configuration: writing would interfere with
    // notifications belonging to other clients.
    block (table, "00002902-0000-1000-8000-00805f9b34fb", GattAccess.WRITE);
    block (table, "00002903-0000-1000-8000-00805f9b34fb", GattAccess.WRITE);

    block_table = table;
    return (!) block_table;
}

/** Access modes denied for @uuid, or GattAccess.NONE if it is not blocked. */
public static GattAccess blocked_access (string uuid) {
    var table = get_block_table ();
    if (!table.contains (uuid)) {
        return GattAccess.NONE;
    }
    return table.lookup (uuid);
}

/** True when reading and writing are both denied for @uuid. */
public static bool is_fully_blocked (string uuid) {
    return blocked_access (uuid) == (GattAccess.READ | GattAccess.WRITE);
}

/** True when any access mode is denied for @uuid. */
public static bool is_blocked (string uuid) {
    return blocked_access (uuid) != GattAccess.NONE;
}

/** True when @uuid may be used for the requested access mode. */
public static bool is_access_allowed (string uuid, GattAccess access) {
    return (blocked_access (uuid) & access) == 0;
}

} // namespace BLE
} // namespace ScratchLink
