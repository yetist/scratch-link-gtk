/*
 * scratch-link-gtk — libsoup WebSocket server.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Protocol {

/**
 * Owns the HTTP/WebSocket listener.
 *
 * Only the two Scratch Link paths are upgraded; any other request gets a
 * small plain-text/HTML status page so users can check the service from a
 * browser.
 */
public class WebSocketServer : GLib.Object {
    public signal void client_connected (SessionType type, Soup.WebsocketConnection connection);

    private Soup.Server server;
    private string bind_address = "127.0.0.1";
    private uint bind_port = 20111;
    private bool running = false;

    public WebSocketServer () {
        server = new Soup.Server ("server-header", "ScratchLink/" + VERSION);

        server.add_handler ("/", handle_http);

        server.add_websocket_handler ("/scratch/ble", null, null,
            (srv, msg, path, conn) => client_connected (SessionType.BLE, conn));
        server.add_websocket_handler ("/scratch/bt", null, null,
            (srv, msg, path, conn) => client_connected (SessionType.BT, conn));
    }

    public bool start (uint port, string address, out string error_message) throws GLib.Error {
        error_message = "";

        if (port == 0 || port > 65535) {
            error_message = "invalid port: %u".printf (port);
            return false;
        }

        bind_address = address;
        bind_port = port;

        if (address == "127.0.0.1" || address == "localhost") {
            if (!server.listen_local (port, 0)) {
                error_message = "unable to listen on 127.0.0.1:%u".printf (port);
                return false;
            }
        } else {
            var inet_address = new GLib.InetAddress.from_string (address);
            if (inet_address == null) {
                error_message = "invalid listen address: %s".printf (address);
                return false;
            }

            var socket_address = new GLib.InetSocketAddress (inet_address, (uint16) port);
            if (!server.listen (socket_address, 0)) {
                error_message = "unable to listen on %s:%u".printf (address, port);
                return false;
            }
        }

        running = true;
        if (address != "127.0.0.1" && address != "localhost") {
            var parsed = new GLib.InetAddress.from_string (address);
            if (parsed == null || !((!) parsed).is_loopback) {
                Log.get_default ().warning (
                    "listening on %s exposes Scratch Link to the network", address);
            }
        }
        Log.get_default ().debug ("WebSocket server started on %s:%u", address, port);
        return true;
    }

    public void stop () {
        if (!running) {
            return;
        }
        running = false;
        server.disconnect ();
        Log.get_default ().debug ("WebSocket server stopped");
    }

    public string get_uri (SessionType type) {
        return "ws://%s:%u/scratch/%s".printf (
            uri_host (bind_address), bind_port, type == SessionType.BLE ? "ble" : "bt");
    }

    /** Human-facing status page, mirrored from the listening address. */
    public string get_http_uri () {
        return "http://%s:%u/".printf (uri_host (bind_address), bind_port);
    }

    private void handle_http (Soup.Server srv, Soup.ServerMessage msg, string path,
                              GLib.HashTable<string, string>? query) {
        if (path != "/" && path != "/index.html") {
            msg.set_status (404, null);
            msg.set_response ("text/plain; charset=utf-8", Soup.MemoryUse.COPY, "Not Found".data);
            return;
        }

        var body = new GLib.StringBuilder ();
        body.append ("<!doctype html>\n<html lang=\"en\">\n<head>\n");
        body.append ("<meta charset=\"utf-8\">\n<title>Scratch Link</title>\n");
        body.append ("<style>body{font-family:sans-serif;margin:2rem;max-width:40rem}");
        body.append ("code{background:#eee;padding:.1rem .3rem;border-radius:.2rem}</style>\n");
        body.append ("</head>\n<body>\n");
        body.append ("<h1>Scratch Link is running</h1>\n");
        body.append ("<p>Version %s &mdash; network protocol %s</p>\n".printf (VERSION, PROTOCOL_VERSION));
        body.append ("<p>BLE endpoint: <code>%s</code></p>\n".printf (get_uri (SessionType.BLE)));
        body.append ("<p>BT endpoint: <code>%s</code></p>\n".printf (get_uri (SessionType.BT)));
        body.append ("<p>This service is for Scratch only. Open Scratch and load a Bluetooth extension.</p>\n");
        body.append ("</body>\n</html>\n");

        msg.set_status (200, null);
        msg.set_response ("text/html; charset=utf-8", Soup.MemoryUse.COPY, body.str.data);
    }
}

} // namespace Protocol
} // namespace ScratchLink
