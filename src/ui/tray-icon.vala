/*
 * scratch-link-gtk — optional AppIndicator tray icon.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This file is compiled only when Meson finds libayatana-appindicator3 (or
 * the older libappindicator3). The runtime also checks for a StatusNotifier
 * host before creating the icon, because GNOME needs an extension for one.
 */

namespace ScratchLink {
namespace UI {

public class TrayIcon : GLib.Object {
    private static bool log_filter_installed = false;

    private AppIndicator.Indicator indicator;

    [CCode (cname = "g_log_default_handler")]
    private extern static void log_default_handler (string? log_domain,
                                                    GLib.LogLevelFlags log_levels,
                                                    string message,
                                                    void* unused_data);

    /**
     * The library itself still prints a deprecation notice pointing at
     * libayatana-appindicator-glib. That replacement is not packaged
     * everywhere yet, so keep the working ABI and hide only that exact
     * notice; other messages from the library still reach stderr.
     */
    private static void install_log_filter () {
        if (log_filter_installed) {
            return;
        }
        log_filter_installed = true;
        GLib.Log.set_handler ("libayatana-appindicator",
                              GLib.LogLevelFlags.LEVEL_WARNING |
                              GLib.LogLevelFlags.LEVEL_ERROR,
                              filter_library_log);
        GLib.Log.set_handler ("libappindicator",
                              GLib.LogLevelFlags.LEVEL_WARNING |
                              GLib.LogLevelFlags.LEVEL_ERROR,
                              filter_library_log);
    }

    private static void filter_library_log (string? domain, GLib.LogLevelFlags level,
                                            string message) {
        if (message.contains ("is deprecated")) {
            Log.get_default ().debug ("%s: %s",
                                      domain ?? "libayatana-appindicator", message);
            return;
        }
        log_default_handler (domain, level, message, null);
    }

    /**
     * True when a StatusNotifier host is registered on the session bus.
     *
     * Without one the icon would be invisible, so the window must keep the
     * normal "close quits" behaviour.
     */
    public static bool is_available () {
        install_log_filter ();
        try {
            var bus = GLib.Bus.get_sync (GLib.BusType.SESSION, null);
            if (bus == null) {
                return false;
            }
            var reply = bus.call_sync ("org.kde.StatusNotifierWatcher",
                                       "/StatusNotifierWatcher",
                                       "org.freedesktop.DBus.Properties", "Get",
                                       new GLib.Variant ("(ss)", "org.kde.StatusNotifierWatcher",
                                                         "IsStatusNotifierHostRegistered"),
                                       new GLib.VariantType ("(v)"),
                                       GLib.DBusCallFlags.NONE, 1000, null);
            return reply.get_child_value (0).get_variant ().get_boolean ();
        } catch (GLib.Error e) {
            Log.get_default ().debug ("no AppIndicator host: %s", e.message);
            return false;
        }
    }

    public TrayIcon (ScratchLinkApp app) {
        install_log_filter ();

        var icon_name = "org.scratchlink.Gtk";
        if (!Gtk.IconTheme.get_default ().has_icon (icon_name)) {
            icon_name = "applications-utilities";
        }

        indicator = new AppIndicator.Indicator (
            "scratch-link", icon_name,
            AppIndicator.IndicatorCategory.APPLICATION_STATUS);
        indicator.set_title ("Scratch Link");

        var menu = new Gtk.Menu ();

        var show_item = new Gtk.MenuItem.with_label ("显示 Scratch Link");
        show_item.activate.connect (() => app.present_window ());

        var copy_item = new Gtk.MenuItem.with_label ("复制服务地址");
        copy_item.activate.connect (() => app.copy_address ());

        var status_item = new Gtk.MenuItem.with_label ("打开状态页");
        status_item.activate.connect (() => app.open_status_page ());

        var separator = new Gtk.SeparatorMenuItem ();

        var quit_item = new Gtk.MenuItem.with_label ("退出");
        quit_item.activate.connect (() => app.quit ());

        var shell = (Gtk.Container) menu;
        shell.add (show_item);
        shell.add (copy_item);
        shell.add (status_item);
        shell.add (separator);
        shell.add (quit_item);

        menu.show_all ();
        indicator.set_menu (menu);
        indicator.set_status (AppIndicator.IndicatorStatus.ACTIVE);

        Log.get_default ().debug ("tray icon registered");
    }

    /** Remove the icon before the application exits. */
    public void hide () {
        indicator.set_status (AppIndicator.IndicatorStatus.PASSIVE);
    }
}

} // namespace UI
} // namespace ScratchLink
