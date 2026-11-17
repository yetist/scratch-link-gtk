/*
 * scratch-link-gtk — bridge between D-Bus callbacks and async methods.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {

/**
 * One-shot waiter used to turn a signal callback into an ``await``.
 *
 * The caller captures the enclosing async method's ``callback``, connects
 * whatever signal will complete the wait, then calls ``yield``. The optional
 * timeout guarantees that a lost signal cannot leave a request hanging.
 */
public class AsyncWaiter : GLib.Object {
    private SourceFunc? resume;
    private bool done = false;
    private uint timeout_id = 0;

    public bool succeeded { get; private set; }
    public bool timed_out { get; private set; }

    public AsyncWaiter (owned SourceFunc resume, uint timeout_ms = 0) {
        this.resume = (owned) resume;
        if (timeout_ms > 0) {
            timeout_id = GLib.Timeout.add (timeout_ms, on_timeout);
        }
    }

    /** Resume the async method once. Later calls are ignored. */
    public void finish (bool success = true) {
        if (done) {
            return;
        }
        done = true;
        succeeded = success;

        if (timeout_id != 0) {
            GLib.Source.remove (timeout_id);
            timeout_id = 0;
        }

        if (resume != null) {
            SourceFunc callback = (owned) resume;
            GLib.Idle.add ((owned) callback);
        }
    }

    private bool on_timeout () {
        timeout_id = 0;
        timed_out = true;
        finish (false);
        return false;
    }
}

} // namespace ScratchLink
