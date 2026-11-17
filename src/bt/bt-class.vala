/*
 * scratch-link-gtk — Bluetooth Classic device class helpers.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace ScratchLink {
namespace BT {

/** Major device class bits from a Bluetooth Class of Device value. */
public uint8 class_major (uint32 device_class) {
    return (uint8) ((device_class >> 8) & 0x1f);
}

/** Minor device class bits from a Bluetooth Class of Device value. */
public uint8 class_minor (uint32 device_class) {
    return (uint8) ((device_class >> 2) & 0x3f);
}

/**
 * Match a Class of Device against the discovery request.
 *
 * A peripheral which reports minor class 0 is accepted regardless of the
 * requested minor class, mirroring the macOS implementation's workaround for
 * devices which do not fill in the minor field.
 */
public bool class_matches (uint32 device_class, uint8 requested_major,
                           uint8 requested_minor) {
    var major = class_major (device_class);
    var minor = class_minor (device_class);
    if (major != requested_major) {
        return false;
    }
    return minor == requested_minor || minor == 0;
}

} // namespace BT
} // namespace ScratchLink
