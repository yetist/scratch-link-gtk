/*
 * scratch-link-gtk — BLE helper and filter tests.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

using ScratchLink.BLE;
using ScratchLink.BT;

private const string BATTERY_SERVICE = "0000180f-0000-1000-8000-00805f9b34fb";
private const string BATTERY_LEVEL = "00002a19-0000-1000-8000-00805f9b34fb";
private const string XIAOMI_SERVICE = "0000fe95-0000-1000-8000-00805f9b34fb";

static void test_uuids () {
    assert (uuid_from_short (0x180f) == BATTERY_SERVICE);
    assert (uuid_from_short (0xfe95) == XIAOMI_SERVICE);

    assert (is_full_uuid ("0000180F-0000-1000-8000-00805F9B34FB"));
    assert (!is_full_uuid ("180f"));
    assert (!is_full_uuid ("0000180f-0000-1000-8000-00805f9b34f"));

    assert (normalize_full_uuid ("0000180F-0000-1000-8000-00805F9B34FB") == BATTERY_SERVICE);
    assert (normalize_full_uuid ("not-a-uuid") == null);

    assert (parse_short_id ("0x180f") == 0x180f);
    assert (parse_short_id ("180f") == 0x180f);
    assert (parse_short_id ("0XFE95") == 0xfe95);
    assert (parse_short_id ("12345") == null);
    assert (parse_short_id ("zz") == null);
}

static void test_resolve () {
    assert (resolve_service ("battery_service") == BATTERY_SERVICE);
    assert (resolve_service ("Battery-Service") == BATTERY_SERVICE);
    assert (resolve_service ("180f") == BATTERY_SERVICE);
    assert (resolve_service ("0x180f") == BATTERY_SERVICE);
    assert (resolve_service ("0000fe95-0000-1000-8000-00805f9b34fb") == XIAOMI_SERVICE);
    assert (resolve_service ("not_a_service") == null);
    assert (resolve_service ("") == null);

    assert (resolve_characteristic ("battery_level") == BATTERY_LEVEL);
    assert (resolve_characteristic ("2a19") == BATTERY_LEVEL);
    assert (resolve_characteristic ("no_such_characteristic") == null);
}

private ScanFilter parse_filter (string json) throws ScratchLink.Protocol.RpcError {
    // Keep JSON parsing separate: catch (GLib.Error) would also catch
    // RpcError, which is itself a GLib.Error domain.
    Json.Node? node = null;
    try {
        node = Json.from_string (json);
    } catch (GLib.Error e) {
        throw new ScratchLink.Protocol.RpcError.INVALID_PARAMS (e.message);
    }

    assert (node != null);
    assert (node.get_node_type () == Json.NodeType.OBJECT);
    return ScanFilter.parse (node.get_object ());
}

private ScratchLink.Bluez.BleDeviceInfo make_device (string? name, string[] uuids) {
    var device = new ScratchLink.Bluez.BleDeviceInfo ("/org/bluez/hci0/dev_test");
    device.name = name;
    device.uuids = uuids;
    return device;
}

static void test_name_filters () {
    try {
        var exact = parse_filter ("{\"name\":\"zimi.switch\"}");
        assert (exact.matches (make_device ("zimi.switch", {})));
        assert (!exact.matches (make_device ("zimi.switch.dhkg02", {})));
        assert (!exact.matches (make_device (null, {})));

        var prefix = parse_filter ("{\"namePrefix\":\"zimi\"}");
        assert (prefix.matches (make_device ("zimi.switch.dhkg02", {})));
        assert (!prefix.matches (make_device ("other", {})));
        assert (!prefix.matches (make_device (null, {})));
    } catch (ScratchLink.Protocol.RpcError e) {
        GLib.Test.message ("unexpected error: %s", e.message);
        GLib.Test.fail ();
    }
}

static void test_service_filters () {
    try {
        var numeric = parse_filter ("{\"services\":[65173]}");
        assert (numeric.matches (make_device ("x", { XIAOMI_SERVICE })));
        assert (!numeric.matches (make_device ("x", { BATTERY_SERVICE })));
        assert (!numeric.matches (make_device ("x", {})));

        var short_string = parse_filter ("{\"services\":[\"180f\"]}");
        assert (short_string.matches (make_device (null, { BATTERY_SERVICE })));

        var named = parse_filter ("{\"services\":[\"battery_service\"]}");
        assert (named.matches (make_device (null, { BATTERY_SERVICE })));

        var full = parse_filter ("{\"services\":[\"" + XIAOMI_SERVICE + "\"]}");
        assert (full.matches (make_device (null, { XIAOMI_SERVICE })));

        // Two services means both must be present.
        var both = parse_filter ("{\"services\":[\"180f\",\"" + XIAOMI_SERVICE + "\"]}");
        assert (!both.matches (make_device (null, { BATTERY_SERVICE })));
        assert (both.matches (make_device (null, { BATTERY_SERVICE, XIAOMI_SERVICE })));
    } catch (ScratchLink.Protocol.RpcError e) {
        GLib.Test.message ("unexpected error: %s", e.message);
        GLib.Test.fail ();
    }
}

static void test_manufacturer_filters () {
    try {
        var any_data = parse_filter ("{\"manufacturerData\":{\"76\":{}}}");
        var device = make_device ("x", {});
        device.manufacturer_data = new GLib.HashTable<uint16, GLib.Bytes> (direct_hash, direct_equal);

        uint8[] raw = { 0x02, 0x15, 0xaa };
        var bytes = new GLib.Bytes (raw);
        device.manufacturer_data.insert (76, bytes);
        assert (any_data.matches (device));

        var prefix = parse_filter ("{\"manufacturerData\":{\"76\":{\"dataPrefix\":[2,21]}}}");
        assert (prefix.matches (device));

        var wrong_prefix = parse_filter ("{\"manufacturerData\":{\"76\":{\"dataPrefix\":[2,22]}}}");
        assert (!wrong_prefix.matches (device));

        // Masked comparison: only the low nibble of byte 0 matters.
        var masked = parse_filter (
            "{\"manufacturerData\":{\"76\":{\"dataPrefix\":[2],\"mask\":[15]}}}");
        assert (masked.matches (device));

        var masked_out = parse_filter (
            "{\"manufacturerData\":{\"76\":{\"dataPrefix\":[3],\"mask\":[15]}}}");
        assert (!masked_out.matches (device));

        // A different company ID must not match.
        var other_company = parse_filter ("{\"manufacturerData\":{\"77\":{}}}");
        assert (!other_company.matches (device));
    } catch (ScratchLink.Protocol.RpcError e) {
        GLib.Test.message ("unexpected error: %s", e.message);
        GLib.Test.fail ();
    }
}

static bool expect_invalid_params (string json) {
    try {
        parse_filter (json);
    } catch (ScratchLink.Protocol.RpcError e) {
        return e.code == ScratchLink.Protocol.RpcError.INVALID_PARAMS;
    }
    return false;
}

static bool expect_application_error (string json) {
    try {
        parse_filter (json);
    } catch (ScratchLink.Protocol.RpcError e) {
        return e.code == ScratchLink.Protocol.RpcError.APPLICATION_ERROR;
    }
    return false;
}

static void test_filter_errors () {
    assert (expect_invalid_params ("{}"));
    assert (expect_invalid_params ("{\"services\":[]}"));
    assert (expect_invalid_params ("{\"services\":[\"not_a_service\"]}"));
    assert (expect_invalid_params ("{\"name\":\"\"}"));
    assert (expect_invalid_params ("{\"name\":7}"));
    assert (expect_invalid_params ("{\"services\":\"180f\"}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"x\":{}}}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"70000\":{}}}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"76\":5}}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"76\":{\"dataPrefix\":[1,2],\"mask\":[1]}}}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"76\":{\"dataPrefix\":[256]}}}"));
    assert (expect_invalid_params ("{\"manufacturerData\":{\"76\":{\"mask\":[1]}}}"));

    assert (expect_invalid_params ("{\"acceptAllDevices\":true}"));
    assert (expect_application_error ("{\"serviceData\":{}}"));
}

static void test_blocklist () {
    assert (is_fully_blocked ("00001812-0000-1000-8000-00805f9b34fb"));
    assert (is_fully_blocked ("00001530-1212-efde-1523-785feabcd123"));
    assert (is_fully_blocked ("f000ffc0-0451-4000-b000-000000000000"));
    assert (is_fully_blocked ("00060000-0000-1000-8000-00805f9b34fb"));
    assert (is_fully_blocked ("0000fffd-0000-1000-8000-00805f9b34fb"));
    assert (is_fully_blocked ("00002a03-0000-1000-8000-00805f9b34fb"));
    assert (is_fully_blocked ("00002a25-0000-1000-8000-00805f9b34fb"));

    // Write-only blocks keep reads available.
    assert (!is_access_allowed ("00002a02-0000-1000-8000-00805f9b34fb", GattAccess.WRITE));
    assert (is_access_allowed ("00002a02-0000-1000-8000-00805f9b34fb", GattAccess.READ));
    assert (is_blocked ("00002a02-0000-1000-8000-00805f9b34fb"));
    assert (!is_fully_blocked ("00002a02-0000-1000-8000-00805f9b34fb"));
    assert (!is_access_allowed ("00002902-0000-1000-8000-00805f9b34fb", GattAccess.WRITE));
    assert (is_access_allowed ("00002902-0000-1000-8000-00805f9b34fb", GattAccess.READ));

    // Ordinary services are not affected.
    assert (!is_fully_blocked (BATTERY_SERVICE));
    assert (is_access_allowed (BATTERY_LEVEL, GattAccess.READ | GattAccess.WRITE));
    assert (blocked_access (BATTERY_LEVEL) == GattAccess.NONE);
}

static void test_message_encoding () {
    uint8[] raw = { 0x01, 0x02, 0xfe, 0xff };
    assert (encode_base64 (raw) == "AQL+/w==");

    uint8[]? decoded = null;
    try {
        decoded = decode_base64 ("AQL+/w==");
        assert (decode_base64 ("").length == 0);
    } catch (ScratchLink.Protocol.RpcError e) {
        assert_not_reached ();
    }
    assert (decoded != null);
    assert (decoded.length == 4);
    assert (decoded[0] == 0x01 && decoded[1] == 0x02);
    assert (decoded[2] == 0xfe && decoded[3] == 0xff);

    assert (utf8_bytes ("abc").length == 3);
    assert (utf8_bytes ("héllo").length == 6);
    assert (utf8_bytes ("").length == 0);

    string[] invalid = { "A", "AQL+/w=", "AQL+/w===", "A===", "AA=A", "!!!!", "AB=C" };
    foreach (var text in invalid) {
        assert (!is_valid_base64 (text));
        try {
            decode_base64 (text);
            assert_not_reached ();
        } catch (ScratchLink.Protocol.RpcError e) {
            assert (e.code == ScratchLink.Protocol.RpcError.PARSE_ERROR);
        }
    }
}

private ScratchLink.Bluez.GattServiceInfo make_service (string path, string uuid) {
    var service = new ScratchLink.Bluez.GattServiceInfo (path);
    service.uuid = uuid;
    return service;
}

private ScratchLink.Bluez.GattCharacteristicInfo make_characteristic (string path,
                                                                     string service_path,
                                                                     string uuid,
                                                                     string[] flags) {
    var characteristic = new ScratchLink.Bluez.GattCharacteristicInfo (path);
    characteristic.service_path = service_path;
    characteristic.uuid = uuid;
    characteristic.flags = flags;
    return characteristic;
}

static void test_gatt_defaults () {
    var device = new ScratchLink.Bluez.GattDevice ("/org/bluez/hci0/dev_test");

    var hid = make_service ("/svc0001", "00001812-0000-1000-8000-00805f9b34fb");
    hid.characteristics.add (make_characteristic ("/char0002", hid.object_path,
                                                  "00002a4a-0000-1000-8000-00805f9b34fb",
                                                  { "read", "write", "notify" }));

    var battery = make_service ("/svc0003", BATTERY_SERVICE);
    var level = make_characteristic ("/char0004", battery.object_path, BATTERY_LEVEL,
                                     { "read", "notify" });
    battery.characteristics.add (level);
    battery.characteristics.add (make_characteristic ("/char0005", battery.object_path,
                                                      "00002a1a-0000-1000-8000-00805f9b34fb",
                                                      { "read", "write", "write-without-response" }));

    device.services.add (hid);
    device.services.add (battery);

    assert (device.service_for (BATTERY_SERVICE) == battery);
    assert (device.service_for (XIAOMI_SERVICE) == null);
    assert (battery.characteristic_for (BATTERY_LEVEL) == level);
    assert (battery.characteristic_for (XIAOMI_SERVICE) == null);

    // Blocked services are skipped when choosing defaults.
    var allowed = new GLib.HashTable<string, bool> (str_hash, str_equal);
    allowed.insert (hid.uuid, true);
    allowed.insert (battery.uuid, true);
    assert (device.default_service (allowed) == battery);

    // Characteristics are returned in declared order.
    assert (battery.default_characteristic () == level);

    // Flags drive the endpoint capabilities.
    assert (level.can_read () && level.can_notify () && !level.can_write ());
    assert (!level.prefers_command ());
    var command_only = battery.characteristic_for ("00002a1a-0000-1000-8000-00805f9b34fb");
    assert (command_only != null);
    assert (command_only.can_write ());
    assert (command_only.can_read ());
    assert (command_only.prefers_command ());

    // A service which is not allowed cannot become the default.
    allowed.remove (battery.uuid);
    assert (device.default_service (allowed) == null);
}

static void test_bt_class () {
    // 0x240404: major 4, minor 1, with audio service bits set.
    assert (class_major (0x240404) == 4);
    assert (class_minor (0x240404) == 1);
    assert (class_matches (0x240404, 4, 1));
    assert (!class_matches (0x240404, 4, 2));
    assert (!class_matches (0x240404, 5, 1));

    // Minor class 0 is treated as a wildcard, like the macOS client.
    assert (class_matches (0x0400, 4, 7));
    assert (class_matches (0x0400, 4, 0));
}

int main (string[] args) {
    GLib.Test.init (ref args);

    GLib.Test.add_func ("/scratch-link/ble/uuids", test_uuids);
    GLib.Test.add_func ("/scratch-link/ble/resolve", test_resolve);
    GLib.Test.add_func ("/scratch-link/ble/name-filters", test_name_filters);
    GLib.Test.add_func ("/scratch-link/ble/service-filters", test_service_filters);
    GLib.Test.add_func ("/scratch-link/ble/manufacturer-filters", test_manufacturer_filters);
    GLib.Test.add_func ("/scratch-link/ble/filter-errors", test_filter_errors);
    GLib.Test.add_func ("/scratch-link/ble/blocklist", test_blocklist);
    GLib.Test.add_func ("/scratch-link/ble/message-encoding", test_message_encoding);
    GLib.Test.add_func ("/scratch-link/ble/gatt-defaults", test_gatt_defaults);
    GLib.Test.add_func ("/scratch-link/bt/class", test_bt_class);

    return GLib.Test.run ();
}
