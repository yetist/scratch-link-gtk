/*
 * scratch-link-gtk — command line entry point.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {

static bool opt_headless = false;
static bool opt_version = false;
static bool opt_verbose = false;
static int opt_port = -1;
static string? opt_address = null;
static string? opt_adapter = null;
static int opt_min_rssi = 1000;

const GLib.OptionEntry[] option_entries = {
    { "headless", 0, 0, GLib.OptionArg.NONE, ref opt_headless,
      "Run without a graphical interface", null },
    { "port", 0, 0, GLib.OptionArg.INT, ref opt_port,
      "WebSocket listen port", "PORT" },
    { "listen-address", 0, 0, GLib.OptionArg.STRING, ref opt_address,
      "Address to bind (default: 127.0.0.1)", "ADDRESS" },
    { "adapter", 0, 0, GLib.OptionArg.STRING, ref opt_adapter,
      "BlueZ adapter name, e.g. hci0", "NAME" },
    { "min-rssi", 0, 0, GLib.OptionArg.INT, ref opt_min_rssi,
      "Hide peripherals weaker than this RSSI (default: -90)", "DBM" },
    { "verbose", 'v', 0, GLib.OptionArg.NONE, ref opt_verbose,
      "Enable verbose logging", null },
    { "version", 'V', 0, GLib.OptionArg.NONE, ref opt_version,
      "Print version and exit", null },
    { null }
};

} // namespace ScratchLink

int main (string[] args) {
    // Use the application ID as the program name so X11 WM_CLASS and the
    // Wayland app_id match the desktop file and the Flatpak app ID.
    GLib.Environment.set_prgname (ScratchLink.APP_ID);
    GLib.Environment.set_application_name ("Scratch Link");

    var context = new GLib.OptionContext ("— Scratch Link for Linux");
    context.set_summary ("Local WebSocket bridge between Scratch and Bluetooth peripherals.");
    context.add_main_entries (ScratchLink.option_entries, null);

    try {
        context.parse (ref args);
    } catch (GLib.OptionError e) {
        stderr.printf ("scratch-link: %s\n", e.message);
        return 1;
    }

    if (ScratchLink.opt_version) {
        print ("scratch-link %s (protocol %s)\n", ScratchLink.VERSION, ScratchLink.PROTOCOL_VERSION);
        return 0;
    }

    var settings = ScratchLink.AppSettings.load ();

    var port = ScratchLink.opt_port;
    if (port < 0) {
        port = (int) settings.port;
    }

    var address = ScratchLink.opt_address ?? settings.listen_address;
    var adapter = ScratchLink.opt_adapter != null
                ? ScratchLink.opt_adapter : settings.adapter;
    var verbose = ScratchLink.opt_verbose || settings.verbose;

    var min_rssi = ScratchLink.opt_min_rssi;
    if (min_rssi == 1000) {
        min_rssi = settings.min_rssi;
    } else if (min_rssi < -100 || min_rssi > 0) {
        stderr.printf ("scratch-link: invalid RSSI threshold: %d\n", min_rssi);
        return 1;
    }

    if (port <= 0 || port > 65535) {
        stderr.printf ("scratch-link: invalid port: %d\n", port);
        return 1;
    }

    if (verbose) {
        ScratchLink.Log.get_default ().min_level = ScratchLink.LogLevel.DEBUG;
        ScratchLink.Log.get_default ().debug ("verbose logging enabled");
    }

    // Command line arguments become the effective settings for this run.
    // They are persisted only if the user applies the preferences dialog.
    settings.port = (uint) port;
    settings.listen_address = address;
    settings.adapter = adapter;
    settings.min_rssi = min_rssi;
    settings.verbose = verbose;

    var has_display = GLib.Environment.get_variable ("DISPLAY") != null ||
                      GLib.Environment.get_variable ("WAYLAND_DISPLAY") != null;

    if (ScratchLink.opt_headless || !has_display) {
        if (!ScratchLink.opt_headless) {
            ScratchLink.Log.get_default ().info ("no display detected; starting in headless mode");
        }
        var app = new ScratchLink.HeadlessApp (settings);
        var status = app.run (args);
        return app.start_failed ? 2 : status;
    }

    var app = new ScratchLink.ScratchLinkApp (settings);
    return app.run (args);
}
