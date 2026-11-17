/*
 * scratch-link-gtk — GTK and headless application entry points.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {

public class ScratchLinkApp : Gtk.Application {
    private LinkService? service = null;
    private UI.MainWindow? window = null;

    private AppSettings settings;

    private GLib.SimpleAction copy_action;
    private GLib.SimpleAction status_action;
    private GLib.SimpleAction preferences_action;
#if HAVE_APPINDICATOR
    private UI.TrayIcon? tray = null;
#endif

    public ScratchLinkApp (AppSettings settings) {
        Object (application_id: APP_ID);

        this.settings = settings;

        var quit_action = new GLib.SimpleAction ("quit", null);
        quit_action.activate.connect (() => this.quit ());
        add_action (quit_action);

        var about_action = new GLib.SimpleAction ("about", null);
        about_action.activate.connect (show_about);
        add_action (about_action);

        preferences_action = new GLib.SimpleAction ("preferences", null);
        preferences_action.set_enabled (false);
        preferences_action.activate.connect (show_preferences);
        add_action (preferences_action);

        copy_action = new GLib.SimpleAction ("copy-address", null);
        copy_action.set_enabled (false);
        copy_action.activate.connect (copy_address);
        add_action (copy_action);

        status_action = new GLib.SimpleAction ("open-status", null);
        status_action.set_enabled (false);
        status_action.activate.connect (open_status_page);
        add_action (status_action);

        shutdown.connect (() => {
#if HAVE_APPINDICATOR
            if (tray != null) {
                tray.hide ();
            }
#endif
            if (service != null) {
                service.stop ();
            }
        });
    }

    protected override void activate () {
        if (window != null) {
            window.present ();
            return;
        }

        service = new LinkService (settings);

        string error_message;
        var started = false;
        try {
            started = service.start (settings.port, settings.listen_address, out error_message);
        } catch (GLib.Error e) {
            error_message = e.message;
        }

        if (!started) {
            var dialog = new Gtk.MessageDialog (null, Gtk.DialogFlags.MODAL,
                                                Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE,
                                                "无法启动 Scratch Link：%s".printf (error_message));
            dialog.run ();
            dialog.destroy ();
            this.quit ();
            return;
        }

        window = new UI.MainWindow (this, service);
        window.show_all ();
        window.present ();

        copy_action.set_enabled (true);
        status_action.set_enabled (true);
        preferences_action.set_enabled (true);

#if HAVE_APPINDICATOR
        if (tray == null && UI.TrayIcon.is_available ()) {
            tray = new UI.TrayIcon (this);
            window.hide_on_close = true;
        }
#endif
    }

    /** Bring the window back after it was hidden to the tray. */
    public void present_window () {
        if (window != null) {
            window.present ();
        } else {
            activate ();
        }
    }

    private void show_preferences () {
        if (window == null || service == null) {
            return;
        }
        var dialog = new UI.PreferencesDialog (window, settings, service);
        var response = dialog.run ();
        Log.get_default ().debug ("preferences dialog response: %d", response);
        if (response == Gtk.ResponseType.OK) {
            dialog.apply ();
        }
        dialog.destroy ();
    }

    public void copy_address () {
        if (service == null || service.listening_uri == null) {
            return;
        }
        var clipboard = Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD);
        clipboard.set_text ((!) service.listening_uri, -1);
        clipboard.store ();
        Log.get_default ().debug ("copied %s to the clipboard", service.listening_uri);
    }

    public void open_status_page () {
        if (window == null || service == null || service.status_uri == null) {
            return;
        }
        try {
            Gtk.show_uri_on_window (window, (!) service.status_uri, Gdk.CURRENT_TIME);
        } catch (GLib.Error e) {
            Log.get_default ().warning ("unable to open %s: %s",
                                        service.status_uri, e.message);
        }
    }

    private void show_about () {
        var dialog = new Gtk.AboutDialog ();
        dialog.set_transient_for (window);
        dialog.set_modal (true);
        dialog.program_name = "Scratch Link";
        dialog.version = VERSION;
        dialog.comments = "在 Linux 上连接 Scratch 与蓝牙 LE 外设";
        dialog.license_type = Gtk.License.GPL_3_0;
        dialog.logo_icon_name = "applications-utilities";
        dialog.run ();
        dialog.destroy ();
    }
}

public class HeadlessApp : GLib.Application {
    private LinkService? service = null;

    private AppSettings settings;

    /** True when the listener could not be started; main() maps this to exit code 2. */
    public bool start_failed { get; private set; default = false; }

    public HeadlessApp (AppSettings settings) {
        Object (application_id: APP_ID + ".Headless",
                flags: GLib.ApplicationFlags.NON_UNIQUE);

        this.settings = settings;

        // There is no window to keep the application alive, so hold it
        // explicitly until quit() is called (signal or shutdown).
        hold ();

        shutdown.connect (() => {
            if (service != null) {
                service.stop ();
            }
        });
    }

    protected override void activate () {
        service = new LinkService (settings);

        string error_message;
        var started = false;
        try {
            started = service.start (settings.port, settings.listen_address, out error_message);
        } catch (GLib.Error e) {
            error_message = e.message;
        }

        if (!started) {
            stderr.printf ("scratch-link: %s\n", error_message);
            start_failed = true;
            this.quit ();
            return;
        }

        Log.get_default ().info ("Scratch Link %s is ready; press Ctrl+C to stop", VERSION);
        Log.get_default ().info ("BLE endpoint: %s", service.listening_uri);

        GLib.Unix.signal_add (GLib.ProcessSignal.INT, () => {
            this.quit ();
            return false;
        });
        GLib.Unix.signal_add (GLib.ProcessSignal.TERM, () => {
            this.quit ();
            return false;
        });
    }
}

} // namespace ScratchLink
