/*
 * scratch-link-gtk — JSON-RPC helper tests.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

using ScratchLink.Protocol;

static void test_error_codes () {
    assert (code_for (RpcError.PARSE_ERROR) == -32700);
    assert (code_for (RpcError.INVALID_REQUEST) == -32600);
    assert (code_for (RpcError.METHOD_NOT_FOUND) == -32601);
    assert (code_for (RpcError.INVALID_PARAMS) == -32602);
    assert (code_for (RpcError.INTERNAL_ERROR) == -32603);
    assert (code_for (RpcError.APPLICATION_ERROR) == -32500);

    assert (title_for (RpcError.INVALID_PARAMS) == "Invalid Params");
    assert (title_for (RpcError.APPLICATION_ERROR) == "Application Error");
}

static void test_build_result () {
    assert (build_result ("1", "{\"protocol\":\"1.2\"}") ==
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocol\":\"1.2\"}}");
    assert (build_result ("\"abc\"", null) ==
            "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":null}");
}

static void test_build_error () {
    var text = build_error ("7", RpcError.INVALID_PARAMS, "missing peripheralId");
    assert (text == "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602," +
                    "\"message\":\"Invalid Params\",\"data\":\"missing peripheralId\"}}");

    var no_detail = build_error (null, RpcError.METHOD_NOT_FOUND, null);
    assert (no_detail == "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":" +
                         "{\"code\":-32601,\"message\":\"Method Not Found\"}}");
}

static void test_redact_mac () {
    assert (ScratchLink.redact_mac ("AA:BB:CC:DD:EE:FF") == "AA:BB:**:**:EE:FF");
    assert (ScratchLink.redact_mac ("aa:bb:cc:dd:ee:ff") == "aa:bb:**:**:ee:ff");

    assert (ScratchLink.redact_mac ("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF") ==
            "/org/bluez/hci0/dev_AA:BB:**:**:EE:FF");

    // UUIDs must not be mistaken for addresses.
    assert (ScratchLink.redact_mac ("0000180f-0000-1000-8000-00805f9b34fb") ==
            "0000180f-0000-1000-8000-00805f9b34fb");
    assert (ScratchLink.redact_mac ("no address here") == "no address here");

    var text = build_error ("1", RpcError.APPLICATION_ERROR,
                            "connect to AA:BB:CC:DD:EE:FF failed");
    assert (text.contains ("AA:BB:**:**:EE:FF"));
    assert (!text.contains ("CC:DD"));
}

static void test_uri_host () {
    assert (uri_host ("127.0.0.1") == "127.0.0.1");
    assert (uri_host ("localhost") == "localhost");
    assert (uri_host ("::1") == "[::1]");
    assert (uri_host ("2001:db8::1") == "[2001:db8::1]");
}

static void test_settings_roundtrip () {
    string temp;
    try {
        temp = GLib.DirUtils.make_tmp ("scratch-link-settings-XXXXXX");
    } catch (GLib.FileError e) {
        GLib.Test.message ("cannot create temporary directory: %s", e.message);
        GLib.Test.fail ();
        return;
    }
    GLib.Environment.set_variable ("XDG_CONFIG_HOME", temp, true);

    var settings = new ScratchLink.AppSettings ();
    settings.port = 23456;
    settings.listen_address = "::1";
    settings.adapter = "hci1";
    settings.min_rssi = -75;
    settings.verbose = true;

    try {
        settings.save ();
    } catch (GLib.Error e) {
        GLib.Test.message ("save failed: %s", e.message);
        GLib.Test.fail ();
        return;
    }

    var loaded = ScratchLink.AppSettings.load ();
    assert (loaded.port == 23456);
    assert (loaded.listen_address == "::1");
    assert (loaded.adapter == "hci1");
    assert (loaded.min_rssi == -75);
    assert (loaded.verbose);

    // Out-of-range and malformed values fall back to defaults.
    var path = ScratchLink.AppSettings.config_path ();
    try {
        GLib.FileUtils.set_contents (path,
            "[general]\nport=0\nlisten-address=\nadapter=\nmin-rssi=-500\nverbose=maybe\n");
    } catch (GLib.FileError e) {
        GLib.Test.message ("cannot rewrite settings: %s", e.message);
        GLib.Test.fail ();
        return;
    }

    var fallback = ScratchLink.AppSettings.load ();
    assert (fallback.port == ScratchLink.AppSettings.DEFAULT_PORT);
    assert (fallback.listen_address == ScratchLink.AppSettings.DEFAULT_ADDRESS);
    assert (fallback.adapter == null);
    assert (fallback.min_rssi == ScratchLink.AppSettings.DEFAULT_MIN_RSSI);
    assert (!fallback.verbose);

    GLib.FileUtils.remove (path);
    GLib.DirUtils.remove (GLib.Path.get_dirname (path));
    GLib.DirUtils.remove (temp);
}

static void test_escaping () {
    var sb = new GLib.StringBuilder ();
    append_json_string (sb, "a\"b\\c\n");
    assert (sb.str == "\"a\\\"b\\\\c\\n\"");
}

static void test_node_roundtrip () {
    try {
        var node = parse_json ("{\"filters\":[{\"name\":\"x\"}]}");
        assert (node != null);
        var text = node_to_json (node);
        assert (text == "{\"filters\":[{\"name\":\"x\"}]}");

        assert (parse_json ("null") != null);
        assert (node_to_json (parse_json ("null")) == null);
    } catch (RpcError e) {
        GLib.Test.message ("unexpected error: %s", e.message);
        GLib.Test.fail ();
    }
}

static void test_bytes_to_string () {
    var bytes = new GLib.Bytes ("hello".data);
    assert (bytes_to_string (bytes) == "hello");
}

int main (string[] args) {
    GLib.Test.init (ref args);

    GLib.Test.add_func ("/scratch-link/jsonrpc/error-codes", test_error_codes);
    GLib.Test.add_func ("/scratch-link/jsonrpc/build-result", test_build_result);
    GLib.Test.add_func ("/scratch-link/jsonrpc/build-error", test_build_error);
    GLib.Test.add_func ("/scratch-link/jsonrpc/redact-mac", test_redact_mac);
    GLib.Test.add_func ("/scratch-link/jsonrpc/uri-host", test_uri_host);
    GLib.Test.add_func ("/scratch-link/jsonrpc/settings-roundtrip", test_settings_roundtrip);
    GLib.Test.add_func ("/scratch-link/jsonrpc/escaping", test_escaping);
    GLib.Test.add_func ("/scratch-link/jsonrpc/node-roundtrip", test_node_roundtrip);
    GLib.Test.add_func ("/scratch-link/jsonrpc/bytes-to-string", test_bytes_to_string);

    return GLib.Test.run ();
}
