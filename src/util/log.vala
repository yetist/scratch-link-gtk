/*
 * scratch-link-gtk — logging.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {

public enum LogLevel {
    DEBUG,
    INFO,
    WARNING,
    ERROR
}

public string log_level_name (LogLevel level) {
    switch (level) {
    case LogLevel.DEBUG:
        return "DEBUG";
    case LogLevel.INFO:
        return "INFO";
    case LogLevel.WARNING:
        return "WARNING";
    case LogLevel.ERROR:
        return "ERROR";
    default:
        return "INFO";
    }
}

private GLib.Regex? mac_regex = null;

/**
 * Hide the middle bytes of a Bluetooth address.
 *
 * BlueZ exposes addresses both as ``AA:BB:CC:DD:EE:FF`` and inside device
 * object paths as ``dev_AA_BB_CC_DD_EE_FF``. Both spellings keep the vendor
 * prefix and the last two bytes, which is enough to tell devices apart while
 * avoiding a full hardware address in logs or error details.
 */
public string redact_mac (string text) {
    if (mac_regex == null) {
        try {
            mac_regex = new GLib.Regex (
                "([0-9A-Fa-f]{2})[:._-]([0-9A-Fa-f]{2})[:._-]" +
                "[0-9A-Fa-f]{2}[:._-][0-9A-Fa-f]{2}[:._-]" +
                "([0-9A-Fa-f]{2})[:._-]([0-9A-Fa-f]{2})");
        } catch (GLib.RegexError e) {
            return text;
        }
    }

    try {
        return ((!) mac_regex).replace (text, -1, 0, "\\1:\\2:**:**:\\3:\\4");
    } catch (GLib.RegexError e) {
        return text;
    }
}

/**
 * Process-wide logger.
 *
 * All output goes to stderr and to an in-memory ring buffer which the GTK
 * window replays on startup. The class is intentionally UI-agnostic.
 */
public class Log : GLib.Object {
    private const int MAX_HISTORY = 500;

    private static Log? instance = null;
    private GLib.GenericArray<string> history = new GLib.GenericArray<string> ();

    public signal void message (LogLevel level, string text);

    public LogLevel min_level { get; set; default = LogLevel.INFO; }

    public static Log get_default () {
        if (instance == null) {
            instance = new Log ();
        }
        return instance;
    }

    public unowned GLib.GenericArray<string> get_history () {
        return history;
    }

    public void write (LogLevel level, string text) {
        if (level < min_level) {
            return;
        }

        var stamp = new GLib.DateTime.now_local ().format ("%H:%M:%S");
        var line = "%s  %-7s  %s".printf (stamp, log_level_name (level),
                                           redact_mac (text));

        stderr.printf ("%s\n", line);

        history.add (line);
        while (history.length > MAX_HISTORY) {
            history.remove_index (0);
        }

        message (level, line);
    }

    public void debug (string format, ...) {
        var l = va_list ();
        write (LogLevel.DEBUG, format.vprintf (l));
    }

    public void info (string format, ...) {
        var l = va_list ();
        write (LogLevel.INFO, format.vprintf (l));
    }

    public void warning (string format, ...) {
        var l = va_list ();
        write (LogLevel.WARNING, format.vprintf (l));
    }

    public void error (string format, ...) {
        var l = va_list ();
        write (LogLevel.ERROR, format.vprintf (l));
    }
}

} // namespace ScratchLink
