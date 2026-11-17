/*
 * scratch-link-gtk — JSON-RPC 2.0 helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Protocol {

/**
 * JSON-RPC / Scratch Link errors.
 *
 * The error's message carries the human-readable detail; the canonical
 * short title and numeric code are derived from the error domain value.
 */
public errordomain RpcError {
    PARSE_ERROR,
    INVALID_REQUEST,
    METHOD_NOT_FOUND,
    INVALID_PARAMS,
    INTERNAL_ERROR,
    APPLICATION_ERROR
}

public int code_for (int error) {
    switch (error) {
    case RpcError.PARSE_ERROR:
        return -32700;
    case RpcError.INVALID_REQUEST:
        return -32600;
    case RpcError.METHOD_NOT_FOUND:
        return -32601;
    case RpcError.INVALID_PARAMS:
        return -32602;
    case RpcError.INTERNAL_ERROR:
        return -32603;
    case RpcError.APPLICATION_ERROR:
        return -32500;
    default:
        return -32603;
    }
}

public string title_for (int error) {
    switch (error) {
    case RpcError.PARSE_ERROR:
        return "Parse Error";
    case RpcError.INVALID_REQUEST:
        return "Invalid Request";
    case RpcError.METHOD_NOT_FOUND:
        return "Method Not Found";
    case RpcError.INVALID_PARAMS:
        return "Invalid Params";
    case RpcError.INTERNAL_ERROR:
        return "Internal Error";
    case RpcError.APPLICATION_ERROR:
        return "Application Error";
    default:
        return "Internal Error";
    }
}

/** Append a JSON string literal (including quotes) to @sb. */
public void append_json_string (GLib.StringBuilder sb, string value) {
    sb.append_c ('"');
    for (int i = 0; i < value.length; i++) {
        char c = value[i];
        switch (c) {
        case '"':
            sb.append ("\\\"");
            break;
        case '\\':
            sb.append ("\\\\");
            break;
        case '\b':
            sb.append ("\\b");
            break;
        case '\f':
            sb.append ("\\f");
            break;
        case '\n':
            sb.append ("\\n");
            break;
        case '\r':
            sb.append ("\\r");
            break;
        case '\t':
            sb.append ("\\t");
            break;
        default:
            if ((uint8) c < 0x20) {
                sb.append ("\\u%04x".printf ((uint8) c));
            } else {
                sb.append_c (c);
            }
            break;
        }
    }
    sb.append_c ('"');
}

/**
 * Serialize a JSON node back to text.
 *
 * Returns null for a missing or JSON-null node. The result is a plain
 * string so it can safely cross async boundaries: Json.Node is a compact
 * (non-refcounted) type and must not be captured by an async method.
 */
public string? node_to_json (Json.Node? node) {
    if (node == null || node.get_node_type () == Json.NodeType.NULL) {
        return null;
    }

    return Json.to_string (node, false);
}

/** Parse JSON text into a detached (owned) node. */
public Json.Node? parse_json (string? text) throws RpcError {
    if (text == null) {
        return null;
    }

    var parser = new Json.Parser ();
    try {
        parser.load_from_data (text);
    } catch (GLib.Error e) {
        throw new RpcError.PARSE_ERROR (e.message);
    }

    var root = parser.get_root ();
    if (root == null) {
        return null;
    }
    return root.copy ();
}

/** Convert a GLib.Bytes payload to a Vala string without relying on NUL termination. */
public string bytes_to_string (GLib.Bytes bytes) {
    unowned uint8[]? data = bytes.get_data ();
    if (data == null || data.length == 0) {
        return "";
    }
    var sb = new GLib.StringBuilder ();
    sb.append_len ((string) data, data.length);
    return sb.str;
}

public string build_result (string? id_json, string? result_json) {
    return "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}".printf (
        id_json ?? "null", result_json ?? "null");
}

public string build_error (string? id_json, int error, string? detail) {
    var sb = new GLib.StringBuilder ();
    sb.append ("{\"jsonrpc\":\"2.0\",\"id\":");
    sb.append (id_json ?? "null");
    sb.append (",\"error\":{\"code\":");
    sb.append (code_for (error).to_string ());
    sb.append (",\"message\":");
    append_json_string (sb, title_for (error));
    if (detail != null && detail != "") {
        sb.append (",\"data\":");
        append_json_string (sb, redact_mac (detail));
    }
    sb.append ("}}");
    return sb.str;
}

public string build_notification (string method, string? params_json) {
    var sb = new GLib.StringBuilder ();
    sb.append ("{\"jsonrpc\":\"2.0\",\"method\":");
    append_json_string (sb, method);
    if (params_json != null) {
        sb.append (",\"params\":");
        sb.append (params_json);
    }
    sb.append ("}");
    return sb.str;
}

public string build_request (string id_json, string method, string? params_json) {
    var sb = new GLib.StringBuilder ();
    sb.append ("{\"jsonrpc\":\"2.0\",\"id\":");
    sb.append (id_json);
    sb.append (",\"method\":");
    append_json_string (sb, method);
    if (params_json != null) {
        sb.append (",\"params\":");
        sb.append (params_json);
    }
    sb.append ("}");
    return sb.str;
}

/** Build a notification from a Json.Node payload, if the payload is non-null. */
public string build_notification_node (string method, Json.Node? params_node) {
    return build_notification (method, node_to_json (params_node));
}

} // namespace Protocol
} // namespace ScratchLink
