/*
 * scratch-link-gtk — base WebSocket session.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Protocol {

public enum SessionType {
    BLE,
    BT
}

public string session_type_name (SessionType type) {
    switch (type) {
    case SessionType.BLE:
        return "BLE";
    case SessionType.BT:
        return "BT";
    default:
        return "unknown";
    }
}

/**
 * One WebSocket connection, speaking JSON-RPC 2.0.
 *
 * The base class owns framing, JSON parsing, id handling and error mapping.
 * Transport-specific method handling lives in subclasses (BleSession).
 */
public class Session : GLib.Object {
    private const uint DISCOVERY_TIMEOUT_SECONDS = 60;

    private int ping_serial = 0;
    private bool ping_after_response = false;
    private bool discovery_started = false;
    private uint idle_timeout_id = 0;

    public Soup.WebsocketConnection connection { get; private set; }
    public SessionType session_type { get; private set; }

    public signal void closed ();

    public Session (Soup.WebsocketConnection connection, SessionType session_type) {
        this.connection = connection;
        this.session_type = session_type;

        connection.message.connect (on_message);
        connection.closed.connect (on_closed);

        idle_timeout_id = GLib.Timeout.add_seconds (DISCOVERY_TIMEOUT_SECONDS, on_idle_timeout);

        Log.get_default ().debug ("session opened (%s)", session_type_name (session_type));
    }

    /** Subclasses call this once a valid discovery request was accepted. */
    protected void mark_discovery_started () {
        discovery_started = true;
        cancel_idle_timeout ();
    }

    protected virtual async string? handle_request (string method, string? params_json) throws RpcError {
        switch (method) {
        case "getVersion":
            return "{\"protocol\":\"" + PROTOCOL_VERSION + "\"}";
        case "pingMe":
            ping_after_response = true;
            return "\"willPing\"";
        case "discover":
            // Only concrete transports implement discovery; this base
            // implementation is used by sessions without a transport.
            throw new RpcError.APPLICATION_ERROR ("transport does not support discovery");
        default:
            throw new RpcError.METHOD_NOT_FOUND (method);
        }
    }

    private void on_message (int dtype, GLib.Bytes payload) {
        if ((Soup.WebsocketDataType) dtype != Soup.WebsocketDataType.TEXT) {
            send_error (null, RpcError.PARSE_ERROR, "only text frames are supported");
            return;
        }

        var text = bytes_to_string (payload);
        if (text == "") {
            send_error (null, RpcError.PARSE_ERROR, "empty frame");
            return;
        }

        var parser = new Json.Parser ();
        try {
            parser.load_from_data (text);
        } catch (GLib.Error e) {
            send_error (null, RpcError.PARSE_ERROR, e.message);
            return;
        }

        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            send_error (null, RpcError.INVALID_REQUEST, "request must be a JSON object");
            return;
        }

        var request = root.get_object ();
        var id_json = node_to_json (request.get_member ("id"));

        var jsonrpc_node = request.get_member ("jsonrpc");
        if (jsonrpc_node == null ||
            jsonrpc_node.get_node_type () != Json.NodeType.VALUE ||
            jsonrpc_node.get_value_type () != typeof (string) ||
            jsonrpc_node.get_string () != "2.0") {
            send_error (id_json, RpcError.INVALID_REQUEST, "jsonrpc must be \"2.0\"");
            return;
        }

        var method_node = request.get_member ("method");
        if (method_node == null ||
            method_node.get_node_type () != Json.NodeType.VALUE ||
            method_node.get_value_type () != typeof (string)) {
            // A response to a server-initiated request (currently only "ping").
            if (id_json != null && (request.has_member ("result") || request.has_member ("error"))) {
                Log.get_default ().debug ("received client response id=%s", id_json);
                return;
            }
            send_error (id_json, RpcError.INVALID_REQUEST, "missing or invalid method");
            return;
        }

        var method = method_node.get_string ();
        var params_json = node_to_json (request.get_member ("params"));

        if (id_json == null) {
            Log.get_default ().debug ("notification %s", method);
        }

        dispatch.begin (id_json, method, params_json, null);
    }

    private async void dispatch (string? id_json, string method, string? params_json) {
        try {
            var result_json = yield handle_request (method, params_json);
            if (id_json != null) {
                send_raw (build_result (id_json, result_json));
                if (ping_after_response) {
                    ping_after_response = false;
                    send_ping ();
                }
            }
        } catch (RpcError e) {
            if (id_json != null) {
                send_raw (build_error (id_json, e.code, e.message));
            } else {
                Log.get_default ().warning ("error in notification %s: %s", method, e.message);
            }
        }
    }

    protected void send_notification (string method, string? params_json) {
        send_raw (build_notification (method, params_json));
    }

    protected void send_error (string? id_json, int error, string? detail) {
        send_raw (build_error (id_json, error, detail));
    }

    protected void send_raw (string text) {
        if (connection.state != Soup.WebsocketState.OPEN) {
            Log.get_default ().debug ("dropping frame: connection is not open");
            return;
        }
        Log.get_default ().debug ("-> %s", text);
        connection.send_text (text);
    }

    private void send_ping () {
        ping_serial++;
        var id = "\"server-ping-%d\"".printf (ping_serial);
        send_raw (build_request (id, "ping", null));
    }

    private void on_closed () {
        cancel_idle_timeout ();
        Log.get_default ().debug ("session closed (%s)", session_type_name (session_type));
        closed ();
    }

    private bool on_idle_timeout () {
        idle_timeout_id = 0;
        if (!discovery_started && connection.state == Soup.WebsocketState.OPEN) {
            Log.get_default ().warning ("session did not send discover within %u seconds; closing",
                                        DISCOVERY_TIMEOUT_SECONDS);
            connection.close ((ushort) Soup.WebsocketCloseCode.NORMAL, "discovery did not start");
        }
        return false;
    }

    private void cancel_idle_timeout () {
        if (idle_timeout_id != 0) {
            GLib.Source.remove (idle_timeout_id);
            idle_timeout_id = 0;
        }
    }
}

} // namespace Protocol
} // namespace ScratchLink
