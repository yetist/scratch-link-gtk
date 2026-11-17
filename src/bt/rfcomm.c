/*
 * scratch-link-gtk — RFCOMM helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "rfcomm.h"

#include <gio/gio.h>

#include <bluetooth/bluetooth.h>
#include <bluetooth/rfcomm.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define CONNECT_TIMEOUT_MS 30000

static void set_errno_error (GError **error, int saved_errno, const char *what)
{
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved_errno),
                 "%s: %s", what, g_strerror (saved_errno));
}

int scratch_link_rfcomm_connect (const char *address, guint8 channel,
                                 GError **error)
{
    bdaddr_t target;
    struct sockaddr_rc remote;
    int fd;
    int flags;
    int result;
    int socket_error;
    socklen_t error_length = sizeof (socket_error);
    struct pollfd poll_fd;

    if (address == NULL || str2ba (address, &target) < 0) {
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
    remote.rc_bdaddr = target;
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
