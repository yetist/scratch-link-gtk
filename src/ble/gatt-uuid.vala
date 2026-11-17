/*
 * scratch-link-gtk — GATT UUID helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The short-ID tables only contain the names used by the Web Bluetooth
 * "Service Assigned Numbers" lookup and by common Scratch extensions.
 * Names and 16-bit IDs are factual data from the Bluetooth SIG Assigned
 * Numbers document; no code or comments were copied from Scratch Link.
 */

namespace ScratchLink {
namespace BLE {

public const string BT_BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb";

/** Build the full 128-bit UUID for a 16-bit Bluetooth SIG ID. */
public string uuid_from_short (uint16 id) {
    return "0000%04x%s".printf (id, BT_BASE_SUFFIX);
}

/** True if @text is already a full 128-bit UUID. */
public static bool is_full_uuid (string text) {
    if (text.length != 36) {
        return false;
    }
    for (int i = 0; i < text.length; i++) {
        char c = text[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') {
                return false;
            }
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            return false;
        }
    }
    return true;
}

/** Normalize a full UUID string to lower case, or return null. */
public static string? normalize_full_uuid (string text) {
    return is_full_uuid (text) ? text.down () : null;
}

/** Parse a 16-bit ID from either a JSON integer or a numeric string. */
public static uint16? parse_short_id (string text) {
    string value = text.strip ();
    if (value.has_prefix ("0x") || value.has_prefix ("0X")) {
        value = value.substring (2);
    }
    if (value.length < 1 || value.length > 4) {
        return null;
    }
    uint parsed = 0;
    for (int i = 0; i < value.length; i++) {
        char c = value[i];
        int digit;
        if (c >= '0' && c <= '9') {
            digit = c - '0';
        } else if (c >= 'a' && c <= 'f') {
            digit = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            digit = c - 'A' + 10;
        } else {
            return null;
        }
        parsed = (parsed << 4) | (uint) digit;
    }
    return (uint16) parsed;
}

/** Look up a lowercase SIG service name such as "battery_service". */
public static uint16? service_id_for_name (string name) {
    string key = name.down ().replace (" ", "_").replace ("-", "_");
    // HashTable.lookup() cannot signal a miss for value types (it returns 0),
    // so check membership first.
    if (!get_service_table ().contains (key)) {
        return null;
    }
    return get_service_table ().lookup (key);
}

/** Look up a lowercase SIG characteristic name such as "battery_level". */
public static uint16? characteristic_id_for_name (string name) {
    string key = name.down ().replace (" ", "_").replace ("-", "_");
    if (!get_characteristic_table ().contains (key)) {
        return null;
    }
    return get_characteristic_table ().lookup (key);
}

/**
 * Resolve a service identifier from the protocol.
 *
 * Accepted forms: full 128-bit UUID, 16-bit integer (handled by the caller),
 * "0x1234" string, 4-digit hex string, or a SIG service name.
 * Returns null when the value cannot be resolved.
 */
public static string? resolve_service (string value) {
    var full = normalize_full_uuid (value);
    if (full != null) {
        return full;
    }

    var short_id = parse_short_id (value);
    if (short_id != null) {
        // Ambiguity: a four-letter name like "abcd" is unlikely to be a SIG
        // name, so treating it as a short ID matches Web Bluetooth.
        return uuid_from_short ((!) short_id);
    }

    var named = service_id_for_name (value);
    if (named != null) {
        return uuid_from_short ((!) named);
    }
    return null;
}

/** Resolve a characteristic identifier; same rules as resolve_service. */
public static string? resolve_characteristic (string value) {
    var full = normalize_full_uuid (value);
    if (full != null) {
        return full;
    }

    var short_id = parse_short_id (value);
    if (short_id != null) {
        return uuid_from_short ((!) short_id);
    }

    var named = characteristic_id_for_name (value);
    if (named != null) {
        return uuid_from_short ((!) named);
    }
    return null;
}

private static GLib.HashTable<string, uint16>? service_table = null;
private static GLib.HashTable<string, uint16>? characteristic_table = null;

private static void add_service (GLib.HashTable<string, uint16> table, string name, uint16 id) {
    table.insert (name, id);
}

private static void add_characteristic (GLib.HashTable<string, uint16> table, string name, uint16 id) {
    table.insert (name, id);
}

private static unowned GLib.HashTable<string, uint16> get_service_table () {
    if (service_table != null) {
        return (!) service_table;
    }
    var table = new GLib.HashTable<string, uint16> (str_hash, str_equal);
    add_service (table, "generic_access", 0x1800);
    add_service (table, "generic_attribute", 0x1801);
    add_service (table, "immediate_alert", 0x1802);
    add_service (table, "link_loss", 0x1803);
    add_service (table, "tx_power", 0x1804);
    add_service (table, "current_time", 0x1805);
    add_service (table, "reference_time_update", 0x1806);
    add_service (table, "next_dst_change", 0x1807);
    add_service (table, "glucose", 0x1808);
    add_service (table, "health_thermometer", 0x1809);
    add_service (table, "device_information", 0x180a);
    add_service (table, "heart_rate", 0x180d);
    add_service (table, "phone_alert_status", 0x180e);
    add_service (table, "battery_service", 0x180f);
    add_service (table, "blood_pressure", 0x1810);
    add_service (table, "alert_notification", 0x1811);
    add_service (table, "human_interface_device", 0x1812);
    add_service (table, "scan_parameters", 0x1813);
    add_service (table, "running_speed_and_cadence", 0x1814);
    add_service (table, "automation_io", 0x1815);
    add_service (table, "cycling_speed_and_cadence", 0x1816);
    add_service (table, "cycling_power", 0x1818);
    add_service (table, "location_and_navigation", 0x1819);
    add_service (table, "environmental_sensing", 0x181a);
    add_service (table, "body_composition", 0x181b);
    add_service (table, "user_data", 0x181c);
    add_service (table, "weight_scale", 0x181d);
    add_service (table, "bond_management", 0x181e);
    add_service (table, "continuous_glucose_monitoring", 0x181f);
    add_service (table, "internet_protocol_support", 0x1820);
    add_service (table, "indoor_positioning", 0x1821);
    add_service (table, "pulse_oximeter", 0x1822);
    add_service (table, "http_proxy", 0x1823);
    add_service (table, "transport_discovery", 0x1824);
    add_service (table, "object_transfer", 0x1825);
    add_service (table, "fitness_machine", 0x1826);
    add_service (table, "mesh_provisioning", 0x1827);
    add_service (table, "mesh_proxy", 0x1828);
    add_service (table, "reconnection_configuration", 0x1829);
    add_service (table, "insulin_delivery", 0x183a);
    add_service (table, "binary_sensor", 0x183b);
    add_service (table, "emergency_configuration", 0x183c);
    add_service (table, "physical_activity_monitor", 0x183e);
    add_service (table, "audio_input_control", 0x1843);
    add_service (table, "volume_control", 0x1844);
    add_service (table, "volume_offset_control", 0x1845);
    add_service (table, "coordinated_set_identification", 0x1846);
    add_service (table, "media_control", 0x1848);
    add_service (table, "generic_media_control", 0x1849);
    add_service (table, "generic_telephone_bearer", 0x184c);
    add_service (table, "microphone_control", 0x184d);
    add_service (table, "audio_stream_control", 0x184e);
    add_service (table, "telephone_bearer", 0x184f);
    service_table = table;
    return (!) service_table;
}

private static unowned GLib.HashTable<string, uint16> get_characteristic_table () {
    if (characteristic_table != null) {
        return (!) characteristic_table;
    }
    var table = new GLib.HashTable<string, uint16> (str_hash, str_equal);
    add_characteristic (table, "battery_level", 0x2a19);
    add_characteristic (table, "battery_power_state", 0x2a1a);
    add_characteristic (table, "manufacturer_name_string", 0x2a29);
    add_characteristic (table, "model_number_string", 0x2a24);
    add_characteristic (table, "serial_number_string", 0x2a25);
    add_characteristic (table, "hardware_revision_string", 0x2a27);
    add_characteristic (table, "firmware_revision_string", 0x2a26);
    add_characteristic (table, "software_revision_string", 0x2a28);
    add_characteristic (table, "system_id", 0x2a23);
    add_characteristic (table, "ieee_11073_20601_regulatory_certification_data_list", 0x2a2a);
    add_characteristic (table, "pnp_id", 0x2a50);
    add_characteristic (table, "device_name", 0x2a00);
    add_characteristic (table, "appearance", 0x2a01);
    add_characteristic (table, "peripheral_privacy_flag", 0x2a02);
    add_characteristic (table, "reconnection_address", 0x2a03);
    add_characteristic (table, "service_changed", 0x2a05);
    add_characteristic (table, "heart_rate_measurement", 0x2a37);
    add_characteristic (table, "body_sensor_location", 0x2a38);
    add_characteristic (table, "heart_rate_control_point", 0x2a39);
    add_characteristic (table, "temperature_measurement", 0x2a1c);
    add_characteristic (table, "temperature_type", 0x2a1d);
    add_characteristic (table, "intermediate_temperature", 0x2a1e);
    add_characteristic (table, "measurement_interval", 0x2a21);
    add_characteristic (table, "humidity", 0x2a6f);
    add_characteristic (table, "pressure", 0x2a6d);
    add_characteristic (table, "alert_level", 0x2a06);
    add_characteristic (table, "tx_power_level", 0x2a07);
    add_characteristic (table, "digital", 0x2a56);
    add_characteristic (table, "analog", 0x2a58);
    add_characteristic (table, "analog_output", 0x2a59);
    add_characteristic (table, "client_characteristic_configuration", 0x2902);
    add_characteristic (table, "server_characteristic_configuration", 0x2903);
    add_characteristic (table, "characteristic_user_description", 0x2901);
    add_characteristic (table, "characteristic_presentation_format", 0x2904);
    add_characteristic (table, "characteristic_aggregate_format", 0x2905);
    add_characteristic (table, "valid_range", 0x2906);
    add_characteristic (table, "external_report_reference", 0x2907);
    add_characteristic (table, "report_reference", 0x2908);
    add_characteristic (table, "number_of_digitals", 0x2909);
    characteristic_table = table;
    return (!) characteristic_table;
}

} // namespace BLE
} // namespace ScratchLink
