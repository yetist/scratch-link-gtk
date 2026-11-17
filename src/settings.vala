/*
 * scratch-link-gtk — persisted application settings.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Settings live in $XDG_CONFIG_HOME/scratch-link/settings.ini. Command line
 * arguments are applied on top of the stored values by main(); the file is
 * only written from the preferences dialog.
 */

namespace ScratchLink {

public class AppSettings : GLib.Object {
    public const uint DEFAULT_PORT = 20111;
    public const string DEFAULT_ADDRESS = "127.0.0.1";
    public const int DEFAULT_MIN_RSSI = -90;

    private const string GROUP = "general";

    public uint port = DEFAULT_PORT;
    public string listen_address = DEFAULT_ADDRESS;
    public string? adapter = null;
    public int min_rssi = DEFAULT_MIN_RSSI;
    public bool verbose = false;

    public static string config_path () {
        return GLib.Path.build_filename (
            GLib.Environment.get_user_config_dir (), "scratch-link", "settings.ini");
    }

    /** Load stored settings, falling back to defaults for missing or invalid keys. */
    public static AppSettings load () {
        var settings = new AppSettings ();
        var file = new GLib.KeyFile ();

        try {
            file.load_from_file (config_path (), GLib.KeyFileFlags.NONE);
        } catch (GLib.Error e) {
            return settings;
        }

        settings.port = (uint) read_int (file, "port", (int) DEFAULT_PORT, 1, 65535);

        var address = read_string (file, "listen-address", DEFAULT_ADDRESS);
        settings.listen_address = address.strip () == "" ? DEFAULT_ADDRESS : address;

        var adapter = read_string (file, "adapter", "");
        settings.adapter = adapter == "" ? null : adapter;

        settings.min_rssi = read_int (file, "min-rssi", DEFAULT_MIN_RSSI, -100, 0);
        settings.verbose = read_bool (file, "verbose", false);

        return settings;
    }

    public void save () throws GLib.Error {
        var path = config_path ();
        GLib.DirUtils.create_with_parents (GLib.Path.get_dirname (path), 0700);

        var file = new GLib.KeyFile ();
        file.set_integer (GROUP, "port", (int) port);
        file.set_string (GROUP, "listen-address", listen_address);
        file.set_string (GROUP, "adapter", adapter ?? "");
        file.set_integer (GROUP, "min-rssi", min_rssi);
        file.set_boolean (GROUP, "verbose", verbose);

        size_t length;
        var data = file.to_data (out length);
        GLib.FileUtils.set_contents (path, data);
        Log.get_default ().debug ("saved settings to %s", path);
    }

    private static int read_int (GLib.KeyFile file, string key, int fallback,
                                 int minimum, int maximum) {
        try {
            var value = file.get_integer (GROUP, key);
            if (value >= minimum && value <= maximum) {
                return value;
            }
        } catch (GLib.Error e) {
            // Missing or malformed keys use the fallback.
        }
        return fallback;
    }

    private static string read_string (GLib.KeyFile file, string key, string fallback) {
        try {
            return file.get_string (GROUP, key);
        } catch (GLib.Error e) {
            return fallback;
        }
    }

    private static bool read_bool (GLib.KeyFile file, string key, bool fallback) {
        try {
            return file.get_boolean (GROUP, key);
        } catch (GLib.Error e) {
            return fallback;
        }
    }
}

} // namespace ScratchLink
