/*
 * scratch-link-gtk — Web Bluetooth style scan filters.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Filtering semantics follow Documentation/BluetoothLE.md and the Web
 * Bluetooth specification. Code is independent of the upstream C# version.
 */

namespace ScratchLink {
namespace BLE {

public class ManufacturerDataFilter : GLib.Object {
    public uint16 company_id;
    public uint8[] data_prefix = {};
    public uint8[] mask = {};

    public ManufacturerDataFilter (uint16 company_id) {
        this.company_id = company_id;
    }

    public bool matches (GLib.Bytes? advertised) {
        if (advertised == null) {
            return false;
        }

        unowned uint8[] data = advertised.get_data ();
        if (data.length < data_prefix.length) {
            return false;
        }

        for (int i = 0; i < data_prefix.length; i++) {
            if ((data[i] & mask[i]) != (data_prefix[i] & mask[i])) {
                return false;
            }
        }
        return true;
    }
}

public class ScanFilter : GLib.Object {
    public string? name { get; set; }
    public string? name_prefix { get; set; }
    public string[] services { get; set; default = {}; }
    public GLib.GenericArray<ManufacturerDataFilter> manufacturer_data { get; private set; }

    public ScanFilter () {
        manufacturer_data = new GLib.GenericArray<ManufacturerDataFilter> ();
    }

    public bool has_criteria () {
        return name != null || name_prefix != null ||
               services.length > 0 || manufacturer_data.length > 0;
    }

    public bool matches (Bluez.BleDeviceInfo device) {
        if (name != null) {
            if (device.name == null || device.name != name) {
                return false;
            }
        }

        if (name_prefix != null) {
            if (device.name == null || !device.name.has_prefix (name_prefix)) {
                return false;
            }
        }

        foreach (var service in services) {
            if (!contains_uuid (device.uuids, service)) {
                return false;
            }
        }

        foreach (var filter in manufacturer_data) {
            GLib.Bytes? advertised = null;
            if (device.manufacturer_data != null) {
                advertised = device.manufacturer_data.lookup (filter.company_id);
            }
            if (!filter.matches (advertised)) {
                return false;
            }
        }

        return true;
    }

    private static bool contains_uuid (string[] uuids, string needle) {
        foreach (var uuid in uuids) {
            if (uuid == needle) {
                return true;
            }
        }
        return false;
    }

    /**
     * Parse one filter object.
     *
     * Throws RpcError.INVALID_PARAMS for malformed input and
     * RpcError.APPLICATION_ERROR for unsupported-but-valid features.
     */
    public static ScanFilter parse (Json.Object object) throws Protocol.RpcError {
        if (object.has_member ("acceptAllDevices")) {
            throw new Protocol.RpcError.INVALID_PARAMS ("acceptAllDevices is not supported");
        }
        if (object.has_member ("serviceData")) {
            throw new Protocol.RpcError.APPLICATION_ERROR ("filtering on serviceData is not currently supported");
        }

        var filter = new ScanFilter ();

        var member = object.get_member ("name");
        if (member != null) {
            filter.name = require_string (member, "name");
        }

        member = object.get_member ("namePrefix");
        if (member != null) {
            filter.name_prefix = require_string (member, "namePrefix");
        }

        member = object.get_member ("services");
        if (member != null) {
            if (member.get_node_type () != Json.NodeType.ARRAY) {
                throw new Protocol.RpcError.INVALID_PARAMS ("services must be an array");
            }
            var array = member.get_array ();
            if (array.get_length () == 0) {
                throw new Protocol.RpcError.INVALID_PARAMS ("services must not be empty");
            }
            var list = new GLib.GenericArray<string> ();
            for (uint i = 0; i < array.get_length (); i++) {
                var uuid = resolve_service_node (array.get_element (i));
                if (uuid == null) {
                    throw new Protocol.RpcError.INVALID_PARAMS ("unable to resolve service identifier");
                }
                list.add ((!) uuid);
            }
            var services = new string[list.length];
            for (uint i = 0; i < list.length; i++) {
                services[i] = list[i];
            }
            filter.services = services;
        }

        member = object.get_member ("manufacturerData");
        if (member != null) {
            if (member.get_node_type () != Json.NodeType.OBJECT) {
                throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData must be an object");
            }
            var data = member.get_object ();
            if (data.get_size () == 0) {
                throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData must not be empty");
            }
            filter.parse_manufacturer_data (data);
        }

        if (!filter.has_criteria ()) {
            throw new Protocol.RpcError.INVALID_PARAMS ("filter must contain at least one criterion");
        }

        return filter;
    }

    private static string require_string (Json.Node node, string field) throws Protocol.RpcError {
        if (node.get_node_type () != Json.NodeType.VALUE ||
            node.get_value_type () != typeof (string)) {
            throw new Protocol.RpcError.INVALID_PARAMS ("%s must be a string".printf (field));
        }
        var value = node.get_string ();
        if (value == "") {
            throw new Protocol.RpcError.INVALID_PARAMS ("%s must not be empty".printf (field));
        }
        return value;
    }

    private static string? resolve_service_node (Json.Node node) {
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return null;
        }

        var value_type = node.get_value_type ();
        if (value_type == typeof (string)) {
            return resolve_service (node.get_string ());
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

    private void parse_manufacturer_data (Json.Object data) throws Protocol.RpcError {
        var members = data.get_members ();
        foreach (var name in members) {
            if (!is_decimal (name)) {
                throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData keys must be decimal company IDs");
            }
            int64 company_id = int64.parse (name);
            if (company_id < 0 || company_id > 0xffff) {
                throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData company ID out of range");
            }

            var value = data.get_member (name);
            if (value.get_node_type () != Json.NodeType.OBJECT) {
                throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData values must be objects");
            }

            var filter = new ManufacturerDataFilter ((uint16) company_id);
            var details = value.get_object ();

            var prefix_node = details.get_member ("dataPrefix");
            if (prefix_node != null) {
                filter.data_prefix = parse_byte_array (prefix_node, "dataPrefix");
            }

            var mask_node = details.get_member ("mask");
            if (mask_node != null) {
                if (prefix_node == null) {
                    throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData mask requires dataPrefix");
                }
                filter.mask = parse_byte_array (mask_node, "mask");
                if (filter.mask.length != filter.data_prefix.length) {
                    throw new Protocol.RpcError.INVALID_PARAMS ("manufacturerData mask length must match dataPrefix");
                }
            } else {
                filter.mask = new uint8[filter.data_prefix.length];
                for (int i = 0; i < filter.mask.length; i++) {
                    filter.mask[i] = 0xff;
                }
            }

            manufacturer_data.add (filter);
        }
    }

    private static bool is_decimal (string text) {
        if (text == "") {
            return false;
        }
        for (int i = 0; i < text.length; i++) {
            if (text[i] < '0' || text[i] > '9') {
                return false;
            }
        }
        return true;
    }

    private static uint8[] parse_byte_array (Json.Node node, string field) throws Protocol.RpcError {
        if (node.get_node_type () != Json.NodeType.ARRAY) {
            throw new Protocol.RpcError.INVALID_PARAMS ("%s must be an array".printf (field));
        }

        var array = node.get_array ();
        var bytes = new uint8[array.get_length ()];
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element.get_node_type () != Json.NodeType.VALUE ||
                element.get_value_type () != typeof (int64)) {
                throw new Protocol.RpcError.INVALID_PARAMS ("%s must contain integers".printf (field));
            }
            var value = element.get_int ();
            if (value < 0 || value > 0xff) {
                throw new Protocol.RpcError.INVALID_PARAMS ("%s values must be between 0 and 255".printf (field));
            }
            bytes[i] = (uint8) value;
        }
        return bytes;
    }
}

} // namespace BLE
} // namespace ScratchLink
