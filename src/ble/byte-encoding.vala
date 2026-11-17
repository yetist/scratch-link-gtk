/*
 * scratch-link-gtk — message buffer encoding.
 *
 * Copyright (C) 2026 The scratch-link-gtk authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Scratch Link messages carry a "message" string and an optional
 * "encoding" property. Only "base64" and UTF-8 text are supported.
 */

namespace ScratchLink {
namespace BLE {

/** Encode bytes as a padded Base64 string. */
public static string encode_base64 (uint8[] data) {
    return GLib.Base64.encode (data);
}

/** True if @text is well-formed, padded standard Base64. */
public static bool is_valid_base64 (string text) {
    if (text.length % 4 != 0) {
        return false;
    }

    bool padding = false;
    int pad_count = 0;
    for (int i = 0; i < text.length; i++) {
        char c = text[i];
        if (c == '=') {
            padding = true;
            pad_count++;
            if (pad_count > 2) {
                return false;
            }
            continue;
        }
        if (padding) {
            return false;
        }
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '+' || c == '/';
        if (!ok) {
            return false;
        }
    }
    return true;
}

/**
 * Decode a Base64 message.
 *
 * Matches the official implementation: malformed input is a parse error,
 * not an invalid-params error.
 */
public static uint8[] decode_base64 (string text) throws Protocol.RpcError {
    if (!is_valid_base64 (text)) {
        throw new Protocol.RpcError.PARSE_ERROR ("failed to parse base64 message");
    }
    return GLib.Base64.decode (text);
}

/** Copy the UTF-8 bytes of @text, without the trailing NUL. */
public static uint8[] utf8_bytes (string text) {
    var data = new uint8[text.length];
    for (int i = 0; i < text.length; i++) {
        data[i] = (uint8) text[i];
    }
    return data;
}

} // namespace BLE
} // namespace ScratchLink
