//
//  SMCCodec.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  What the bytes of an SMC key mean, as a pure function of the bytes and the
//  four-character type the controller reports for the key.
//
//  ── Byte order is not one rule ─────────────────────────────────────────────
//
//  Every temperature and fan speed on Apple silicon is `flt `, a little-endian
//  32-bit float, and the battery fallback `ioft` is little-endian 48.16 fixed
//  point. The integer types are the trap. `#KEY`, `FOFC` and `F0Fc` are
//  big-endian on an M3, but the battery's `B0AV` and `B0AC` are little-endian
//  — the same controller, the same type name, the opposite order. The
//  integers here are decoded big-endian, which is right for the only ones
//  this app reads (`#KEY`, and the one-byte `FNum` and fan mode, which have
//  no order). Anything electrical about the battery comes from the public
//  AppleSmartBattery registry entry instead, never from here.
//
//  `sp78` and `fpe2` are Intel-era encodings; an M3 carries neither. They are
//  decoded so an older Mac reads correctly rather than silently, and cost
//  nothing where they are absent.
//

import Foundation

public enum SMCCodec {
    /// The value `bytes` encode as `type`, or nil for a type this does not
    /// know, a size that does not match the type, or a float that is not a
    /// number. Absent beats invented: a reading the codec cannot vouch for is
    /// never turned into a zero.
    public static func decode(bytes: [UInt8], type: String) -> Double? {
        switch (type, bytes.count) {
        case ("flt ", 4):
            let value = Double(Float32(bitPattern: littleEndian32(bytes)))
            return value.isFinite ? value : nil
        case ("ioft", 8):
            var raw: UInt64 = 0
            for (offset, byte) in bytes.enumerated() { raw |= UInt64(byte) << UInt64(offset * 8) }
            return Double(raw) / 65_536
        case ("ui8 ", 1), ("flag", 1):
            return Double(bytes[0])
        case ("si8 ", 1):
            return Double(Int8(bitPattern: bytes[0]))
        case ("ui16", 2):
            return Double(bigEndian16(bytes))
        case ("si16", 2):
            return Double(Int16(bitPattern: bigEndian16(bytes)))
        case ("ui32", 4):
            return Double(bigEndian32(bytes))
        case ("si32", 4):
            return Double(Int32(bitPattern: bigEndian32(bytes)))
        case ("sp78", 2):
            return Double(Int16(bitPattern: bigEndian16(bytes))) / 256
        case ("fpe2", 2):
            return Double(bigEndian16(bytes)) / 4
        default:
            return nil
        }
    }

    /// Four little-endian bytes for a `flt ` key, or nil for a value that is
    /// not a finite, non-negative number representable as a 32-bit float. For
    /// the helper's writer: a fan target is never negative and never NaN.
    public static func encodeFloatLE(_ value: Double) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        let float = Float32(value)
        guard float.isFinite else { return nil }
        let bits = float.bitPattern
        return [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff),
                UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
    }

    /// The four-character code the controller uses for `name`, packed
    /// big-endian, or nil unless `name` is exactly four ASCII characters. A
    /// silently truncated or padded name would address a different key.
    public static func fourCC(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The name of a four-character code. Bytes outside printable ASCII read
    /// as "?", so a code that is not a name can never match one by accident.
    public static func fourCCString(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff),
                     UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(decoding: bytes.map { (0x20..<0x7f).contains($0) ? $0 : 0x3f }, as: UTF8.self)
    }

    private static func littleEndian32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    private static func bigEndian16(_ b: [UInt8]) -> UInt16 {
        UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private static func bigEndian32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}
