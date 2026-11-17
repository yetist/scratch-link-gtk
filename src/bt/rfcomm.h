/*
 * scratch-link-gtk — RFCOMM helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Bluetooth Classic sockets are not covered by GSocket, so this small C
 * helper owns the sockaddr_rc/socket() details. It is called from a worker
 * thread because connect() may block for many seconds.
 */

#ifndef SCRATCH_LINK_RFCOMM_H
#define SCRATCH_LINK_RFCOMM_H

#include <glib.h>

G_BEGIN_DECLS

/*
 * Connect an RFCOMM channel to a remote Bluetooth address in
 * "AA:BB:CC:DD:EE:FF" form. Returns a non-blocking file descriptor or -1
 * with @error set.
 */
int scratch_link_rfcomm_connect (const char *address, guint8 channel,
                                 GError **error);

void scratch_link_rfcomm_close (int fd);

G_END_DECLS

#endif /* SCRATCH_LINK_RFCOMM_H */
