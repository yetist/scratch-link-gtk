/*
 * scratch-link-gtk — minimal Vala binding for libappindicator3.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Only the calls used by the tray icon are declared here.
 */

[CCode (cheader_filename = "libappindicator/app-indicator.h")]
namespace AppIndicator {
    [CCode (cprefix = "APP_INDICATOR_CATEGORY_", has_type_id = false)]
    public enum IndicatorCategory {
        APPLICATION_STATUS,
        COMMUNICATIONS,
        SYSTEM_SERVICES,
        HARDWARE,
        OTHER
    }

    [CCode (cprefix = "APP_INDICATOR_STATUS_", has_type_id = false)]
    public enum IndicatorStatus {
        PASSIVE,
        ACTIVE,
        ATTENTION
    }

    [CCode (type_id = "app_indicator_get_type ()")]
    public class Indicator : GLib.Object {
        [CCode (cname = "app_indicator_new", has_construct_function = false)]
        public Indicator (string id, string icon_name, IndicatorCategory category);

        [CCode (cname = "app_indicator_set_status")]
        public void set_status (IndicatorStatus status);

        [CCode (cname = "app_indicator_set_menu")]
        public void set_menu (Gtk.Menu menu);

        [CCode (cname = "app_indicator_set_title")]
        public void set_title (string title);

        [CCode (cname = "app_indicator_set_icon_full")]
        public void set_icon_full (string icon_name, string icon_desc);
    }
}
