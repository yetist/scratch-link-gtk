/*
 * scratch-link-gtk — bindings for the small RFCOMM C helper.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace BT {

[CCode (cname = "scratch_link_rfcomm_connect",
        cheader_filename = "bt/rfcomm.h")]
private extern static int scratch_link_rfcomm_connect (string address,
                                                       uint8 channel) throws GLib.Error;

[CCode (cname = "scratch_link_rfcomm_close",
        cheader_filename = "bt/rfcomm.h")]
private extern static void scratch_link_rfcomm_close (int fd);

} // namespace BT
} // namespace ScratchLink
