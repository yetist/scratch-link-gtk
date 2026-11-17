/*
 * scratch-link-gtk — URI helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace Protocol {

/**
 * Format a host for use in a URI authority.
 *
 * IPv6 literals must be wrapped in brackets, otherwise the colons are parsed
 * as the port separator (for example "::1" becomes "[::1]").
 */
public string uri_host (string address) {
    return address.contains (":") ? "[%s]".printf (address) : address;
}

} // namespace Protocol
} // namespace ScratchLink
