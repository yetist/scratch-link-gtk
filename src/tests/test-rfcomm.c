/*
 * scratch-link-gtk — RFCOMM address parsing tests.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <gio/gio.h>

#include "bt/rfcomm.h"

static void
assert_invalid_address (const char *address)
{
    GError *error = NULL;
    int fd = scratch_link_rfcomm_connect (address, 1, &error);

    g_assert_cmpint (fd, ==, -1);
    g_assert_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT);
    g_clear_error (&error);
}

int
main (void)
{
    assert_invalid_address (NULL);
    assert_invalid_address ("");
    assert_invalid_address ("00:11:22:33:44");
    assert_invalid_address ("0:11:22:33:44:55");
    assert_invalid_address ("00:11:22:33:44:5G");
    assert_invalid_address ("00-11-22-33-44-55");
    assert_invalid_address ("00:11:22:33:44:55:66");
    return 0;
}
