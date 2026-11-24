/*
 * scratch-link-gtk — RFCOMM helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "rfcomm.h"

#include <gio/gio.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define CONNECT_TIMEOUT_MS 30000

/*
 * Linux exposes Bluetooth sockets through the regular socket API. The
 * constants and sockaddr layout below are ABI-stable UAPI values, repeated
 * here so the build does not need libbluetooth (which is often missing from
 * Flatpak runtimes and minimal build roots).
 */
#ifndef AF_BLUETOOTH
#define AF_BLUETOOTH 31
#endif
#ifndef BTPROTO_RFCOMM
#define BTPROTO_RFCOMM 3
#endif

struct rfcomm_sockaddr {
    sa_family_t rc_family;
    uint8_t rc_bdaddr[6];
    uint8_t rc_channel;
};

/* Matches struct sockaddr_rc from BlueZ: 2 + 6 + 1 bytes plus alignment. */
_Static_assert (sizeof (struct rfcomm_sockaddr) == 10,
                "unexpected RFCOMM sockaddr layout");

static int hex_value (char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

/* Parse "AA:BB:CC:DD:EE:FF" into six bytes. */
static gboolean parse_address (const char *text, uint8_t out[6])
{
    int i;

    if (text == NULL || strlen (text) != 17) {
        return FALSE;
    }

    for (i = 0; i < 6; i++) {
        int high = hex_value (text[i * 3]);
        int low = hex_value (text[i * 3 + 1]);

        if (high < 0 || low < 0) {
            return FALSE;
        }
        if (i < 5 && text[i * 3 + 2] != ':') {
            return FALSE;
        }
        out[i] = (uint8_t) (high * 16 + low);
    }

    return TRUE;
}

static void set_errno_error (GError **error, int saved_errno, const char *what)
{
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved_errno),
                 "%s: %s", what, g_strerror (saved_errno));
}

int scratch_link_rfcomm_connect (const char *address, guint8 channel,
                                 GError **error)
{
    struct rfcomm_sockaddr remote;
    uint8_t target[6];
    int fd;
    int flags;
    int result;
    int socket_error;
    socklen_t error_length = sizeof (socket_error);
    struct pollfd poll_fd;

    if (!parse_address (address, target)) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                     "invalid Bluetooth address: %s",
                     address != NULL ? address : "(null)");
        return -1;
    }

    fd = socket (AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
    if (fd < 0) {
        set_errno_error (error, errno, "cannot create RFCOMM socket");
        return -1;
    }

    flags = fcntl (fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl (fd, F_SETFL, flags | O_NONBLOCK);
    }
    fcntl (fd, F_SETFD, FD_CLOEXEC);

    memset (&remote, 0, sizeof (remote));
    remote.rc_family = AF_BLUETOOTH;
    memcpy (remote.rc_bdaddr, target, sizeof (target));
    remote.rc_channel = channel;

    result = connect (fd, (struct sockaddr *) &remote, sizeof (remote));
    if (result < 0 && errno != EINPROGRESS) {
        set_errno_error (error, errno, "RFCOMM connect failed");
        close (fd);
        return -1;
    }

    if (result < 0) {
        poll_fd.fd = fd;
        poll_fd.events = POLLOUT;
        poll_fd.revents = 0;

        do {
            result = poll (&poll_fd, 1, CONNECT_TIMEOUT_MS);
        } while (result < 0 && errno == EINTR);

        if (result == 0) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                 "RFCOMM connect timed out");
            close (fd);
            return -1;
        }
        if (result < 0) {
            set_errno_error (error, errno, "RFCOMM connect wait failed");
            close (fd);
            return -1;
        }

        socket_error = 0;
        if (getsockopt (fd, SOL_SOCKET, SO_ERROR, &socket_error,
                        &error_length) < 0) {
            set_errno_error (error, errno, "cannot read RFCOMM socket state");
            close (fd);
            return -1;
        }
        if (socket_error != 0) {
            set_errno_error (error, socket_error, "RFCOMM connect failed");
            close (fd);
            return -1;
        }
    }

    return fd;
}

void scratch_link_rfcomm_close (int fd)
{
    if (fd >= 0) {
        close (fd);
    }
}
