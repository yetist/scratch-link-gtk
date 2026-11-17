/*
 * scratch-link-gtk — preferences dialog.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace UI {

/*
 * Gtk.Dialog.get_content_area() is declared as returning Gtk.Box in the vapi
 * while GTK itself declares GtkWidget*. The mismatch makes Vala-generated C
 * emit an incompatible-pointer warning, so bind the C function directly.
 */
[CCode (cname = "gtk_dialog_get_content_area", cheader_filename = "gtk/gtk.h")]
private extern static unowned Gtk.Widget dialog_content_area (Gtk.Dialog dialog);

/**
 * Edit the persisted settings.
 *
 * Port and adapter are read at startup, so they only take effect after a
 * restart. The RSSI floor and the log level are applied immediately.
 */
public class PreferencesDialog : Gtk.Dialog {
    private AppSettings settings;
    private LinkService service;

    private Gtk.SpinButton port_button;
    private Gtk.ComboBoxText adapter_combo;
    private Gtk.SpinButton rssi_button;
    private Gtk.CheckButton verbose_check;

    public PreferencesDialog (Gtk.Window parent, AppSettings settings, LinkService service) {
        Object (transient_for: parent, modal: true, title: "首选项", use_header_bar: 1);

        this.settings = settings;
        this.service = service;

        add_button ("取消", Gtk.ResponseType.CANCEL);
        var apply_button = add_button ("应用", Gtk.ResponseType.OK);
        apply_button.get_style_context ().add_class ("suggested-action");
        set_default_response (Gtk.ResponseType.OK);

        var grid = new Gtk.Grid ();
        grid.set_border_width (16);
        grid.set_row_spacing (10);
        grid.set_column_spacing (12);

        var port_label = new Gtk.Label ("监听端口");
        port_label.set_xalign (0.0f);
        grid.attach (port_label, 0, 0, 1, 1);

        port_button = new Gtk.SpinButton.with_range (1, 65535, 1);
        port_button.set_value (settings.port);
        port_button.set_hexpand (true);
        grid.attach (port_button, 1, 0, 1, 1);

        var adapter_label = new Gtk.Label ("蓝牙适配器");
        adapter_label.set_xalign (0.0f);
        grid.attach (adapter_label, 0, 1, 1, 1);

        adapter_combo = new Gtk.ComboBoxText ();
        adapter_combo.append ("", "自动选择");
        if (settings.adapter != null && settings.adapter != "") {
            adapter_combo.append ((!) settings.adapter, (!) settings.adapter);
        }
        adapter_combo.set_active_id (settings.adapter ?? "");
        adapter_combo.set_hexpand (true);
        grid.attach (adapter_combo, 1, 1, 1, 1);

        var rssi_label = new Gtk.Label ("最低 RSSI");
        rssi_label.set_xalign (0.0f);
        grid.attach (rssi_label, 0, 2, 1, 1);

        rssi_button = new Gtk.SpinButton.with_range (-100, 0, 1);
        rssi_button.set_value (settings.min_rssi);
        rssi_button.set_tooltip_text ("低于该值的设备不会上报给 Scratch");
        grid.attach (rssi_button, 1, 2, 1, 1);

        verbose_check = new Gtk.CheckButton.with_label ("输出详细日志");
        verbose_check.set_active (settings.verbose);
        grid.attach (verbose_check, 0, 3, 2, 1);

        var hint = new Gtk.Label ("端口和适配器在重启 Scratch Link 后生效；RSSI 与日志级别立即生效。");
        hint.set_xalign (0.0f);
        hint.set_line_wrap (true);
        hint.get_style_context ().add_class ("dim-label");
        grid.attach (hint, 0, 4, 2, 1);

        var area = dialog_content_area (this);
        ((Gtk.Container) area).add (grid);
        show_all ();

        populate_adapters.begin ();
    }

    /** Ask BlueZ for adapter names without blocking the dialog. */
    private async void populate_adapters () {
        var names = yield Bluez.BluezAdapter.list_adapters ();
        var current = settings.adapter;

        foreach (var name in names) {
            // The configured adapter is already in the list, even if BlueZ
            // does not currently export it.
            if (current != null && name == current) {
                continue;
            }
            adapter_combo.append (name, name);
        }

        adapter_combo.set_active_id (current ?? "");
    }

    /** Store and apply the edited values; returns false if saving failed. */
    public bool apply () {
        var new_port = (uint) port_button.get_value_as_int ();
        var adapter_id = adapter_combo.get_active_id ();
        string? new_adapter = (adapter_id == null || adapter_id == "") ? null : adapter_id;
        var new_rssi = rssi_button.get_value_as_int ();
        var new_verbose = verbose_check.get_active ();

        var restart_needed = new_port != settings.port || new_adapter != settings.adapter;

        var old_port = settings.port;
        var old_adapter = settings.adapter;
        var old_rssi = settings.min_rssi;
        var old_verbose = settings.verbose;

        settings.port = new_port;
        settings.adapter = new_adapter;
        settings.min_rssi = new_rssi;
        settings.verbose = new_verbose;

        try {
            settings.save ();
        } catch (GLib.Error e) {
            settings.port = old_port;
            settings.adapter = old_adapter;
            settings.min_rssi = old_rssi;
            settings.verbose = old_verbose;

            var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
                                                Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE,
                                                "无法保存设置：%s".printf (e.message));
            dialog.run ();
            dialog.destroy ();
            return false;
        }

        service.set_min_rssi (new_rssi);
        Log.get_default ().min_level = new_verbose ? LogLevel.DEBUG : LogLevel.INFO;

        if (restart_needed) {
            var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
                                                Gtk.MessageType.INFO, Gtk.ButtonsType.CLOSE,
                                                "端口或适配器已保存，重启 Scratch Link 后生效。");
            dialog.run ();
            dialog.destroy ();
        }

        return true;
    }
}

} // namespace UI
} // namespace ScratchLink
