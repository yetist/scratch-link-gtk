/*
 * scratch-link-gtk — main window.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace UI {

/** One row in the device list, kept so property updates do not rebuild widgets. */
private class DeviceRow : GLib.Object {
    public Gtk.ListBoxRow row;
    public Gtk.Label name_label;
    public Gtk.Label rssi_label;
    public Gtk.Label state_label;

    public DeviceRow (Gtk.ListBoxRow row, Gtk.Label name_label,
                      Gtk.Label rssi_label, Gtk.Label state_label) {
        this.row = row;
        this.name_label = name_label;
        this.rssi_label = rssi_label;
        this.state_label = state_label;
    }
}

/**
 * GTK 3 main window.
 *
 * The window only observes LinkService/Log signals; all protocol and BlueZ
 * work happens outside the UI layer.
 */
public class MainWindow : Gtk.ApplicationWindow {
    private const int MAX_LOG_LINES = 500;

    private LinkService service;

    /** When true, closing the window hides it instead of quitting. */
    public bool hide_on_close { get; set; default = false; }

    private Gtk.Label status_label;
    private Gtk.Label detail_label;
    private Gtk.Label adapter_label;
    private Gtk.ListBox device_list;
    private Gtk.TextView log_view;
    private Gtk.TextBuffer log_buffer;

    private GLib.HashTable<string, DeviceRow> device_rows =
        new GLib.HashTable<string, DeviceRow> (str_hash, str_equal);

    private Bluez.AdapterState adapter_state = Bluez.AdapterState.UNKNOWN;
    private int session_count = 0;

    public MainWindow (Gtk.Application app, LinkService service) {
        Object (application: app, title: "Scratch Link");
        this.service = service;

        build_ui ();
        connect_signals ();

        delete_event.connect ((event) => {
            if (!hide_on_close) {
                return false;
            }
            hide ();
            Log.get_default ().info (
                "window hidden; use the tray icon to reopen or quit");
            return true;
        });
    }

    private void build_ui () {
        set_default_size (560, 460);
        set_position (Gtk.WindowPosition.CENTER);

        var header = new Gtk.HeaderBar ();
        header.set_show_close_button (true);
        header.title = "Scratch Link";
        header.subtitle = "Scratch Link for Linux";
        set_titlebar (header);

        var menu = new GLib.Menu ();
        var service_menu = new GLib.Menu ();
        service_menu.append ("复制服务地址", "app.copy-address");
        service_menu.append ("打开状态页", "app.open-status");
        menu.append_section (null, service_menu);
        menu.append ("首选项", "app.preferences");
        menu.append ("关于", "app.about");
        menu.append ("退出", "app.quit");

        var menu_button = new Gtk.MenuButton ();
        menu_button.set_menu_model (menu);
        menu_button.set_image (new Gtk.Image.from_icon_name ("open-menu-symbolic", Gtk.IconSize.BUTTON));
        menu_button.set_tooltip_text ("菜单");
        header.pack_end (menu_button);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_border_width (12);

        var status_grid = new Gtk.Grid ();
        status_grid.set_column_spacing (8);
        status_grid.set_row_spacing (4);

        status_label = new Gtk.Label (null);
        status_label.set_xalign (0.0f);
        status_grid.attach (status_label, 0, 0, 1, 1);

        detail_label = new Gtk.Label (service.listening_uri ?? "未监听");
        detail_label.set_xalign (0.0f);
        detail_label.set_selectable (true);
        detail_label.get_style_context ().add_class ("dim-label");
        status_grid.attach (detail_label, 0, 1, 1, 1);

        adapter_label = new Gtk.Label (null);
        adapter_label.set_xalign (0.0f);
        adapter_label.get_style_context ().add_class ("dim-label");
        status_grid.attach (adapter_label, 0, 2, 1, 1);
        update_adapter_state (service.bluez.state);

        content.pack_start (status_grid, false, false, 0);
        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        var devices_label = new Gtk.Label ("设备");
        devices_label.set_xalign (0.0f);
        devices_label.get_style_context ().add_class ("dim-label");
        content.pack_start (devices_label, false, false, 0);

        device_list = new Gtk.ListBox ();
        device_list.set_selection_mode (Gtk.SelectionMode.NONE);
        device_list.set_placeholder (new Gtk.Label ("尚未发现设备"));

        var device_scroll = new Gtk.ScrolledWindow (null, null);
        device_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        device_scroll.set_min_content_height (120);
        device_scroll.add (device_list);
        content.pack_start (device_scroll, true, true, 0);

        var log_expander = new Gtk.Expander (null);
        log_expander.set_expanded (Log.get_default ().min_level == LogLevel.DEBUG);

        var log_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        var log_title = new Gtk.Label ("日志");
        log_title.set_xalign (0.0f);
        log_header.pack_start (log_title, false, false, 0);

        var clear_button = new Gtk.Button.with_label ("清空");
        clear_button.set_relief (Gtk.ReliefStyle.NONE);
        clear_button.set_tooltip_text ("清空日志");
        log_header.pack_end (clear_button, false, false, 0);
        log_header.show_all ();
        log_expander.set_label_widget (log_header);

        log_view = new Gtk.TextView ();
        log_view.set_editable (false);
        log_view.set_cursor_visible (false);
        log_view.set_monospace (true);
        log_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        log_buffer = log_view.get_buffer ();

        var log_scroll = new Gtk.ScrolledWindow (null, null);
        log_scroll.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        log_scroll.set_min_content_height (160);
        log_scroll.add (log_view);
        log_expander.add (log_scroll);
        content.pack_start (log_expander, false, false, 0);

        clear_button.clicked.connect (() => log_buffer.set_text ("", 0));

        add (content);
    }

    private void connect_signals () {
        service.session_count_changed.connect (update_session_count);
        service.adapter_state_changed.connect (update_adapter_state);
        service.device_seen.connect (update_device);
        service.device_lost.connect (remove_device);

        var log = Log.get_default ();
        log.message.connect ((level, text) => append_log (text));

        var history = log.get_history ();
        for (int i = 0; i < (int) history.length; i++) {
            append_log (history[i]);
        }
    }

    private void update_adapter_state (Bluez.AdapterState state) {
        adapter_state = state;
        var name = service.bluez.adapter_name;
        switch (state) {
        case Bluez.AdapterState.READY:
            adapter_label.set_text ("蓝牙：已开启" + (name != null ? "（%s）".printf ((!) name) : ""));
            break;
        case Bluez.AdapterState.POWERED_OFF:
            adapter_label.set_text ("蓝牙：已关闭" + (name != null ? "（%s）".printf ((!) name) : ""));
            break;
        case Bluez.AdapterState.NO_ADAPTER:
            adapter_label.set_text ("蓝牙：未找到适配器");
            break;
        case Bluez.AdapterState.UNAUTHORIZED:
            adapter_label.set_text ("蓝牙：权限不足，请检查 polkit 或 bluetooth 组");
            break;
        case Bluez.AdapterState.ERROR:
            adapter_label.set_text ("蓝牙：不可用，请确认 bluetooth.service 正在运行");
            break;
        default:
            adapter_label.set_text ("蓝牙：正在检测…");
            break;
        }
        refresh_status ();
    }

    /** Keep the headline in sync with both the adapter and the session count. */
    private void refresh_status () {
        string color;
        string text;
        switch (adapter_state) {
        case Bluez.AdapterState.ERROR:
            color = "#c62828";
            text = "蓝牙服务不可用";
            break;
        case Bluez.AdapterState.UNAUTHORIZED:
            color = "#b26a00";
            text = "蓝牙权限不足";
            break;
        case Bluez.AdapterState.NO_ADAPTER:
            color = "#b26a00";
            text = "未找到蓝牙适配器";
            break;
        case Bluez.AdapterState.POWERED_OFF:
            color = "#b26a00";
            text = "蓝牙适配器已关闭";
            break;
        default:
            color = "#2e7d32";
            text = session_count > 0
                 ? "活动会话：%d".printf (session_count)
                 : "正在等待 Scratch 连接…";
            break;
        }
        status_label.set_markup ("<span foreground='%s'>●</span>  %s".printf (color, text));
    }

    private void update_device (string object_path, string? name, int rssi,
                                bool has_rssi, bool connected) {
        var entry = device_rows.lookup (object_path);
        if (entry == null) {
            var row = new Gtk.ListBoxRow ();

            var grid = new Gtk.Grid ();
            grid.set_column_spacing (8);
            grid.set_margin_top (4);
            grid.set_margin_bottom (4);
            grid.set_margin_start (6);
            grid.set_margin_end (6);

            var name_label = new Gtk.Label (null);
            name_label.set_xalign (0.0f);
            name_label.set_hexpand (true);
            name_label.set_ellipsize (Pango.EllipsizeMode.END);
            grid.attach (name_label, 0, 0, 1, 1);

            var rssi_label = new Gtk.Label (null);
            rssi_label.set_xalign (1.0f);
            rssi_label.get_style_context ().add_class ("dim-label");
            grid.attach (rssi_label, 1, 0, 1, 1);

            var state_label = new Gtk.Label (null);
            state_label.set_xalign (1.0f);
            state_label.get_style_context ().add_class ("dim-label");
            grid.attach (state_label, 2, 0, 1, 1);

            row.add (grid);
            device_list.add (row);
            entry = new DeviceRow (row, name_label, rssi_label, state_label);
            device_rows.insert (object_path, (!) entry);
            row.show_all ();
        }

        var info = (!) entry;
        info.name_label.set_text (name != null && name != "" ? (!) name : "未命名设备");
        info.rssi_label.set_text (has_rssi ? "%d dBm".printf (rssi) : "—");
        info.state_label.set_text (connected ? "已连接" : "可连接");
    }

    private void remove_device (string object_path) {
        var entry = device_rows.lookup (object_path);
        if (entry != null) {
            device_list.remove (((!) entry).row);
            device_rows.remove (object_path);
        }
    }

    private void update_session_count (int count) {
        session_count = count;
        refresh_status ();
    }

    private void append_log (string line) {
        Gtk.TextIter iter;
        log_buffer.get_end_iter (out iter);
        log_buffer.insert (ref iter, line + "\n", -1);

        while (log_buffer.get_line_count () > MAX_LOG_LINES) {
            Gtk.TextIter start;
            Gtk.TextIter end;
            log_buffer.get_start_iter (out start);
            log_buffer.get_iter_at_line (out end, 1);
            log_buffer.delete (ref start, ref end);
        }

        log_buffer.get_end_iter (out iter);
        log_view.scroll_to_iter (iter, 0.0, false, 0.0, 1.0);
    }
}

} // namespace UI
} // namespace ScratchLink
