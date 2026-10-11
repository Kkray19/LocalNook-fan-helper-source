//
//  SMCReader.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  ─────────────────────────────────────────────────────────────────────────
//  UNDOCUMENTED INTERFACE — OPT-IN ONLY, READ-ONLY
//  ─────────────────────────────────────────────────────────────────────────
//
//  WHY THIS EXISTS
//  Temperatures and fan speeds on Apple silicon live in the System Management
//  Controller, and the only route to it from user space is the AppleSMC
//  IOKit user client: `IOServiceOpen` on "AppleSMC", then struct calls on
//  selector 2 carrying an 80-byte parameter block. Nothing about that block
//  is documented. Every monitoring utility on the Mac speaks it anyway, and
//  the layout below was checked on an M3 MacBook Pro (Mac15,3, macOS 27)
//  against the one Vorssaint uses. The user asked for temperatures and fan
//  speeds on 2026-09-25, knowing that.
//
//  The block's fields, their order and sizes, the selector (2) and the
//  command numbers are those SMCKit declares (MIT, Copyright (c) 2014-2017
//  beltex <https://github.com/beltex>; `SMCKit/SMC.swift`, `SMCParamStruct`
//  and its `Selector` enum, which credit Apple's PowerManagement source),
//  and Stats (MIT, Copyright (c) 2019 Serhiy Mytrovtsiy; `SMC/smc.swift`)
//  lays the same block out with the 32-bit data size used here. Their MIT
//  notices are in LICENSES/MIT-SMCKit.txt and LICENSES/MIT-Stats.txt, which
//  go with this file wherever it is published.
//
//  SCOPE
//  Three commands, all of them reads: 8 names the key at an index, 9 says a
//  key's size and type, 5 reads its bytes. They are an allowlist enforced on
//  every call, and there is no write command in this file — the one writer
//  is SMCFanWriter, in the helper's own target, behind its own allowlist of
//  fan keys. Since 2026-10-09 this reader is the fan helper's alone (this
//  library is linked by the helper only): it reads the fans for a status
//  reply, and temperatures and fans while the helper holds the fans (the
//  watchdog, the Cool preset, a write read back) or a closed-lid sleep hold
//  (the chip-temperature guard). The app reads the
//  controller through its own client (LocalNookSensors' SMCConnection), only while
//  Settings ▸ Widgets ▸ "Temperatures and fan speeds" is on and a view is
//  showing the readings.
//
//  RISK
//  An undocumented ABI can change under an OS update. If the struct's layout
//  is not the one checked here, `init` refuses to open the connection at
//  all, rather than hand the kernel a block of the wrong shape; if the
//  service is missing or refuses, `init` returns nil. Either way the helper
//  takes no fan (it answers `unsupportedHardware`) and no sleep hold (a Mac
//  whose sensor controller will not open reads no temperature).
//
//  THREADING
//  One connection, not safe for concurrent use. An instance belongs to one
//  serial queue at a time: the helper's controller's, or the sleep hold's.
//  `@unchecked Sendable` is that promise, not a lock.
//

import Foundation
import IOKit

/// One SMC key, as the controller described it.
public struct SMCKey: Sendable, Equatable, Hashable {
    /// The name packed big-endian, as the controller addresses it.
    public let code: UInt32
    public let name: String
    /// Bytes, 1…32 for anything readable.
    public let size: UInt32
    /// The controller's four-character type: "flt ", "ui8 ", "ioft"….
    public let type: String
    /// Undocumented flag byte. 0x40 appears only on keys that look writable.
    public let attributes: UInt8

    public init(code: UInt32, name: String, size: UInt32, type: String, attributes: UInt8) {
        self.code = code
        self.name = name
        self.size = size
        self.type = type
        self.attributes = attributes
    }
}

/// The reads discovery and sampling need, so they can run against a double
/// in the self-test. SMCReader is the only real conformer.
public protocol SMCKeyReading: AnyObject {
    /// The number of keys the controller enumerates (`#KEY`), or 0.
    func keyCount() -> Int
    /// The four-character code at `index`, or nil when the index answers
    /// nothing.
    func key(at index: Int) -> UInt32?
    /// Size and type of the key `code`, or nil when there is no such key.
    func info(_ code: UInt32) -> SMCKey?
    /// The key's raw bytes, exactly `key.size` of them, or nil.
    func read(_ key: SMCKey) -> [UInt8]?
}

extension SMCKeyReading {
    /// A key looked up by name, or nil when it is absent.
    public func key(named name: String) -> SMCKey? {
        guard let code = SMCCodec.fourCC(name) else { return nil }
        return info(code)
    }

    /// The key's value through the codec, or nil when it cannot be read or
    /// decoded.
    public func value(_ key: SMCKey) -> Double? {
        guard let bytes = read(key) else { return nil }
        return SMCCodec.decode(bytes: bytes, type: key.type)
    }
}

/// The parameter block's shape as this build of Swift lays it out. Public so
/// the self-test can pin it; `SMCReader.init` refuses to open a connection
/// unless it is `.expected`.
public struct SMCLayout: Sendable, Equatable {
    public var size: Int
    public var stride: Int
    public var keyInfo: Int
    public var result: Int
    public var data8: Int
    public var data32: Int
    public var bytes: Int
    public var keyInfoSize: Int

    public init(size: Int, stride: Int, keyInfo: Int, result: Int, data8: Int,
                data32: Int, bytes: Int, keyInfoSize: Int) {
        self.size = size
        self.stride = stride
        self.keyInfo = keyInfo
        self.result = result
        self.data8 = data8
        self.data32 = data32
        self.bytes = bytes
        self.keyInfoSize = keyInfoSize
    }

    /// Verified on an M3 with a throwaway probe; see the header.
    public static let expected = SMCLayout(size: 80, stride: 80, keyInfo: 28, result: 40,
                                           data8: 42, data32: 44, bytes: 48, keyInfoSize: 9)
}

public final class SMCReader: SMCKeyReading, @unchecked Sendable {
    /// `kSMCHandleYPCEvent`, the struct-method selector.
    private static let selector: UInt32 = 2
    private static let commandRead: UInt8 = 5
    private static let commandKeyAtIndex: UInt8 = 8
    private static let commandKeyInfo: UInt8 = 9
    /// Every command this type may send. There is no write command here, and
    /// `call` traps on anything outside this set.
    public static let allowedCommands: Set<UInt8> = [commandRead, commandKeyAtIndex, commandKeyInfo]

    public static var layout: SMCLayout {
        SMCLayout(size: MemoryLayout<SMCParamStruct>.size,
                  stride: MemoryLayout<SMCParamStruct>.stride,
                  keyInfo: MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo) ?? -1,
                  result: MemoryLayout<SMCParamStruct>.offset(of: \.result) ?? -1,
                  data8: MemoryLayout<SMCParamStruct>.offset(of: \.data8) ?? -1,
                  data32: MemoryLayout<SMCParamStruct>.offset(of: \.data32) ?? -1,
                  bytes: MemoryLayout<SMCParamStruct>.offset(of: \.bytes) ?? -1,
                  keyInfoSize: MemoryLayout<SMCKeyInfoData>.size)
    }

    private var connection: io_connect_t = 0

    /// Opens the AppleSMC user client, or nil when the service is missing,
    /// refuses, or the parameter block is not the shape checked on real
    /// hardware.
    public init?() {
        guard Self.layout == .expected else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess,
              connection != 0
        else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public func keyCount() -> Int {
        // `#KEY` is a big-endian ui32 on every Mac checked; read it directly
        // so the count does not depend on a key-info round trip.
        guard let code = SMCCodec.fourCC("#KEY") else { return 0 }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = 4
        input.data8 = Self.commandRead
        guard let output = call(&input), output.result == 0 else { return 0 }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(4)) }
        return SMCCodec.decode(bytes: bytes, type: "ui32").map { Int($0) } ?? 0
    }

    public func key(at index: Int) -> UInt32? {
        guard index >= 0, index <= Int(UInt32.max) else { return nil }
        var input = SMCParamStruct()
        input.data8 = Self.commandKeyAtIndex
        input.data32 = UInt32(index)
        guard let output = call(&input), output.result == 0 else { return nil }
        return output.key
    }

    public func info(_ code: UInt32) -> SMCKey? {
        var input = SMCParamStruct()
        input.key = code
        input.data8 = Self.commandKeyInfo
        guard let output = call(&input), output.result == 0 else { return nil }
        return SMCKey(code: code, name: SMCCodec.fourCCString(code),
                      size: output.keyInfo.dataSize,
                      type: SMCCodec.fourCCString(output.keyInfo.dataType),
                      attributes: output.keyInfo.dataAttributes)
    }

    public func read(_ key: SMCKey) -> [UInt8]? {
        // The payload is 32 bytes; a key claiming more cannot be read whole.
        guard (1...32).contains(key.size) else { return nil }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.size
        input.data8 = Self.commandRead
        guard let output = call(&input), output.result == 0 else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(key.size))) }
    }

    /// The one place a call reaches the kernel. Success needs both the
    /// kern_return and the controller's own result byte, which callers check.
    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        precondition(Self.allowedCommands.contains(input.data8),
                     "SMCReader refuses SMC command \(input.data8): reads only")
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, Self.selector,
                                               &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &outputSize)
        return result == kIOReturnSuccess ? output : nil
    }
}

// MARK: - The parameter block

// Private to this file: nothing else in this program may build one. The
// fields are SMCKit's `SMCParamStruct` (MIT; see the header).

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// 80 bytes. `padding` is there because Swift packs SMCKeyInfoData to 9
/// bytes where C pads it to 12; without it every field after `keyInfo` would
/// sit two bytes early and the controller would read garbage.
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
