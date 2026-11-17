/*
 * scratch-link-gtk — session registry.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Protocol {

public class SessionManager : GLib.Object {
    private GLib.GenericArray<Session> sessions = new GLib.GenericArray<Session> ();

    public signal void count_changed (int count);

    public int count {
        get {
            return (int) sessions.length;
        }
    }

    /** Copy of the current sessions, safe to iterate while callbacks close them. */
    public GLib.GenericArray<Session> snapshot () {
        var copy = new GLib.GenericArray<Session> ();
        for (uint i = 0; i < sessions.length; i++) {
            copy.add (sessions[i]);
        }
        return copy;
    }

    public void add (Session session) {
        sessions.add (session);

        session.closed.connect (() => {
            sessions.remove (session);
            count_changed (count);
        });

        count_changed (count);
    }

    /** Ask every client to disconnect, then drop our references. */
    public void close_all () {
        var snapshot = new GLib.GenericArray<Session> ();
        for (uint i = 0; i < sessions.length; i++) {
            snapshot.add (sessions[i]);
        }

        foreach (var session in snapshot) {
            if (session.connection.state == Soup.WebsocketState.OPEN) {
                session.connection.close ((ushort) Soup.WebsocketCloseCode.GOING_AWAY, "server shutting down");
            }
        }

        while (sessions.length > 0) {
            sessions.remove_index (0);
        }
        count_changed (0);
    }
}

} // namespace Protocol
} // namespace ScratchLink
