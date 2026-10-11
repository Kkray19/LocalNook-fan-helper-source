//
//  SMCFanWriter.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  ─────────────────────────────────────────────────────────────────────────
//  UNDOCUMENTED INTERFACE — THE ONLY SMC WRITES IN LOCALNOOK
//  ─────────────────────────────────────────────────────────────────────────
//
//  WHY THIS EXISTS
//  The user asked on 2026-09-25 to set the fan speed from the notch. On
//  Apple silicon the fans answer only to the System Management Controller,
//  and the only way to ask it is the same undocumented AppleSMC user client
//  LocalNookSMC reads through, with one more command: 6, write. The
//  firmware accepts that command for the fan keys from root alone, which is
//  why this file lives in a root daemon and nowhere else. The block's
//  layout, the selector (2) and the command numbers, write (6) included, are
//  those SMCKit declares (MIT, Copyright (c) 2014-2017 beltex
//  <https://github.com/beltex>; `SMCKit/SMC.swift`, `SMCParamStruct`); its
//  MIT notice is in LICENSES/MIT-SMCKit.txt, which goes with this file
//  wherever it is published.
//
//  SCOPE
//  Four kinds of key, and nothing else, ever:
//    F<n>Md / F<n>md   the fan's mode — 1 (manual) or 0 (automatic), never
//                      any other value;
//    F<n>Tg            its target, clamped to that fan's own firmware
//                      minimum and maximum. Zero is written only while
//                      handing the fan back, where the firmware ignores it;
//    Ftst              the unlock some Macs need before manual mode sticks,
//                      1 or 0, and only if the Mac has the key.
//  The names are an allowlist built from the fan count (`FNum`, at most 8)
//  and checked on every write; the write port checks the fixed superset
//  again. A write to anything else is a `precondition` failure, not an
//  error to handle. Reads for verification go through LocalNookSMC's
//  read-only SMCReader; this file's own connection sends command 6 only.
//
//  RISK
//  An undocumented ABI can change under an OS update. The parameter block
//  must have exactly the layout LocalNookSMC verified, or the port refuses
//  to open. Every write checks both the kernel's return and the
//  controller's own result byte, every change is read back, and anything
//  that does not stick hands the fans back to macOS rather than trying
//  harder: the sequence below never fights the firmware.
//

import Foundation
import IOKit
import LocalNookSMC

// MARK: - The allowlist

enum FanKeyAllowlist {
    /// Every name this file could ever write, for any Mac: the per-fan keys
    /// of fans 0…7 and `Ftst`. The write port refuses anything outside it.
    static let everyFanKey: Set<String> = keys(fanCount: FanLimits.maximumFans)

    /// The names a Mac with `fanCount` fans may have written: `F<n>Md`,
    /// `F<n>md` and `F<n>Tg` for each fan, and `Ftst`. Empty for a fan count
    /// outside 1…8, so a Mac that reported nonsense cannot be written at all.
    static func keys(fanCount: Int) -> Set<String> {
        guard (1...FanLimits.maximumFans).contains(fanCount) else { return [] }
        var names: Set<String> = ["Ftst"]
        for index in 0..<fanCount {
            names.formUnion(["F\(index)Md", "F\(index)md", "F\(index)Tg"])
        }
        return names
    }

    /// The pure check the writer runs before every write.
    static func permits(_ name: String, fanCount: Int) -> Bool {
        keys(fanCount: fanCount).contains(name)
    }

    /// The check both write paths make on the key itself: its name is in
    /// `allowed`, *and* the code the port will actually send spells that
    /// name. SMCKey has a memberwise initializer, so a name alone could
    /// vouch for any code.
    static func permits(_ key: SMCKey, among allowed: Set<String>) -> Bool {
        SMCCodec.fourCCString(key.code) == key.name && allowed.contains(key.name)
    }
}

// MARK: - The write port

/// What one write came to.
enum SMCWriteOutcome: Equatable, Sendable {
    case written
    /// The kernel refused the call.
    case transport(Int32)
    /// The controller answered with a nonzero result byte.
    case controller(UInt8)
    /// Not attempted: a size that does not match the key.
    case refused
}

/// The raw write. AppleSMC command 6 in the helper; a register file in the
/// self-test. Only SMCFanWriter calls it.
protocol SMCWritePort: AnyObject {
    func write(_ bytes: [UInt8], to key: SMCKey) -> SMCWriteOutcome
}

// MARK: - Fan keys

/// One fan's keys, and its firmware bounds as read when it was discovered.
struct FanControlKeys: Sendable, Equatable {
    var index: Int
    var actual: SMCKey
    var minimumKey: SMCKey
    var maximumKey: SMCKey
    var target: SMCKey
    var mode: SMCKey
    var minimum: Double
    var maximum: Double
}

/// How long the sequences wait. Shortened in the self-test.
struct FanWriteTiming: Sendable {
    /// After the direct write, before the first verification.
    var settle: TimeInterval = 0.25
    var verifyAttempts = 10
    var verifyGap: TimeInterval = 0.05
    var modeAttempts = 20
    var targetAttempts = 10
    var retryGap: TimeInterval = 0.05
    /// With `Ftst` on and the target at maximum, before retrying manual mode.
    var unlockWait: TimeInterval = 3
    /// How long manual mode is retried after the unlock, and how often.
    var manualWindow: TimeInterval = 6
    var manualGap: TimeInterval = 0.1

    static let standard = FanWriteTiming()
}

// MARK: - The writer

/// Every write the helper makes, and the sequences built from them. One
/// instance belongs to one queue at a time (the controller's, or its work
/// queue while a start runs); `@unchecked Sendable` is that promise.
final class SMCFanWriter: @unchecked Sendable {
    let fans: [FanControlKeys]
    /// `Ftst`, when this Mac has it.
    let unlock: SMCKey?
    private let reader: any SMCKeyReading
    private let port: any SMCWritePort
    private let allowed: Set<String>
    private let timing: FanWriteTiming
    private let sleep: @Sendable (TimeInterval) -> Void
    private let clock: @Sendable () -> TimeInterval
    /// The targets the last successful start or update set, for `verify`.
    private(set) var activeTargets: [Double] = []
    /// Every target written to each fan (by position) since the fans were
    /// last handed back — so a fan at any of them, in manual mode, is still
    /// this process's, whatever a half-finished update left. Levels are on
    /// a 5% grid, so this stays small.
    private var written: [Int: [Double]] = [:]
    /// This process set `Ftst` (the start fallback).
    private var setUnlockItself = false

    init(fans: [FanControlKeys], unlock: SMCKey?, reader: any SMCKeyReading, port: any SMCWritePort,
         timing: FanWriteTiming = .standard,
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fans = fans
        self.unlock = unlock
        self.reader = reader
        self.port = port
        self.allowed = FanKeyAllowlist.keys(fanCount: fans.count)
        self.timing = timing
        self.sleep = sleep
        self.clock = clock
    }

    /// The real controller: LocalNookSMC's reader for reads, this file's
    /// port for writes. Fails when AppleSMC will not open, the Mac has no
    /// fan, or its fan keys are not the ones this file knows how to write.
    static func connect(reader: any SMCKeyReading) -> Result<SMCFanWriter, FanHelperError> {
        switch discover(using: reader) {
        case .failure(let error):
            return .failure(error)
        case .success(let found):
            guard let port = AppleSMCWritePort() else { return .failure(.unsupportedHardware) }
            return .success(SMCFanWriter(fans: found.fans, unlock: found.unlock, reader: reader, port: port))
        }
    }

    // MARK: Discovery

    struct Discovery: Equatable {
        var fans: [FanControlKeys]
        var unlock: SMCKey?
    }

    /// The fans this Mac lets the helper drive, or why not. Every fan must
    /// have an actual speed, trustworthy bounds, a `flt ` target and a
    /// one-byte mode key; one that does not makes the whole Mac unsupported,
    /// rather than driving some fans and not others.
    static func discover(using reader: any SMCKeyReading) -> Result<Discovery, FanHelperError> {
        guard let countKey = reader.key(named: "FNum"), let rawCount = reader.value(countKey)
        else { return .failure(.noFans) }
        if rawCount == 0 { return .failure(.noFans) }
        guard let count = FanLimits.fanCount(from: rawCount) else { return .failure(.unsupportedHardware) }
        var fans: [FanControlKeys] = []
        for index in 0..<count {
            guard let actual = reader.key(named: "F\(index)Ac"),
                  let minimumKey = reader.key(named: "F\(index)Mn"),
                  let maximumKey = reader.key(named: "F\(index)Mx"),
                  let target = reader.key(named: "F\(index)Tg"), isTargetKey(target),
                  let mode = ThermalCatalog.modeKey(lowercase: reader.key(named: "F\(index)md"),
                                                    uppercase: reader.key(named: "F\(index)Md")),
                  isByteKey(mode),
                  let minimum = reader.value(minimumKey), let maximum = reader.value(maximumKey),
                  FanLimits.validBounds(minimum: minimum, maximum: maximum)
            else { return .failure(.unsupportedHardware) }
            fans.append(FanControlKeys(index: index, actual: actual, minimumKey: minimumKey,
                                       maximumKey: maximumKey, target: target, mode: mode,
                                       minimum: minimum, maximum: maximum))
        }
        let unlock = reader.key(named: "Ftst").flatMap { isByteKey($0) ? $0 : nil }
        return .success(Discovery(fans: fans, unlock: unlock))
    }

    /// A target this file can encode: a little-endian float of four bytes,
    /// as on every Apple silicon Mac checked.
    static func isTargetKey(_ key: SMCKey) -> Bool { key.type == "flt " && key.size == 4 }

    /// A one-byte integer or flag, for the mode and the unlock.
    static func isByteKey(_ key: SMCKey) -> Bool { key.size == 1 && (key.type == "ui8 " || key.type == "flag") }

    // MARK: Reads

    /// Every fan as the controller reports it now, or none when any of them
    /// cannot be read.
    func readFans() -> [FanReading] {
        ThermalCatalog.validatedFans(fans.map { fan in
            ThermalCatalog.fanReading(index: fan.index, actual: reader.value(fan.actual),
                                      minimum: reader.value(fan.minimumKey),
                                      maximum: reader.value(fan.maximumKey),
                                      target: reader.value(fan.target),
                                      mode: reader.value(fan.mode))
        })
    }

    func modeByte(_ fan: FanControlKeys) -> UInt8? {
        guard let bytes = reader.read(fan.mode), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    /// Whether `Ftst` is set — someone else's unlock. An unreadable one
    /// counts as set: the helper never starts on a guess.
    func unlockEngaged() -> Bool {
        guard let unlock else { return false }
        guard let bytes = reader.read(unlock), bytes.count == 1 else { return true }
        return bytes[0] != 0
    }

    /// Every fan's mode reads automatic (0 or 3).
    func allAutomatic() -> Bool {
        fans.allSatisfy { modeByte($0).map(FanLimits.isAutomatic(mode:)) == true }
    }

    // MARK: The only writes

    /// Mode 1.
    func setManual(_ fan: FanControlKeys) -> Bool { writeMode(true, fan) }

    /// Mode 0.
    func setAutomatic(_ fan: FanControlKeys) -> Bool { writeMode(false, fan) }

    /// The target, clamped to this fan's firmware [minimum, maximum]. There
    /// is no way through here to stop a fan or push it past its rating.
    func setTarget(_ fan: FanControlKeys, rpm: Double) -> Bool {
        guard rpm.isFinite else { return false }
        let clamped = min(fan.maximum, max(fan.minimum, rpm))
        guard let bytes = Self.encodeTarget(clamped, for: fan.target) else { return false }
        // Recorded before the write: one reported as failed may still land.
        if let position = fans.firstIndex(where: { $0.index == fan.index }),
           written[position]?.contains(clamped) != true {
            written[position, default: []].append(clamped)
        }
        return write(bytes, to: fan.target)
    }

    /// `Ftst` 1 or 0, only on a Mac that has it.
    func setUnlock(_ on: Bool) -> Bool {
        guard let unlock else { return false }
        if on { setUnlockItself = true }
        return write([on ? 1 : 0], to: unlock)
    }

    /// Target 0, the firmware's own resting value. Private: only the
    /// hand-back sequence writes it, after the mode is already automatic.
    private func zeroTarget(_ fan: FanControlKeys) -> Bool {
        guard let bytes = Self.encodeTarget(0, for: fan.target) else { return false }
        return write(bytes, to: fan.target)
    }

    private func writeMode(_ manual: Bool, _ fan: FanControlKeys) -> Bool {
        write([manual ? 1 : 0], to: fan.mode)
    }

    /// The one place bytes leave this type. The allowlist is not a
    /// convention here: a name outside it stops the helper.
    private func write(_ bytes: [UInt8], to key: SMCKey) -> Bool {
        precondition(FanKeyAllowlist.permits(key, among: allowed),
                     "SMCFanWriter refuses to write \(key.name): not a fan-control key on this Mac")
        precondition(bytes.count == Int(key.size), "SMCFanWriter: \(bytes.count) bytes for \(key.name)")
        return port.write(bytes, to: key) == .written
    }

    /// Four little-endian bytes for a `flt ` target, or nil for any other
    /// type or a value that is negative or not a number.
    static func encodeTarget(_ rpm: Double, for key: SMCKey) -> [UInt8]? {
        guard isTargetKey(key) else { return nil }
        return SMCCodec.encodeFloatLE(rpm)
    }

    /// Within max(2 rpm, 0.1%) of what was asked: the controller stores a
    /// float and rounds.
    static func targetMatches(_ value: Double?, expected: Double) -> Bool {
        guard let value, value.isFinite, expected.isFinite else { return false }
        return abs(value - expected) <= max(2, expected * 0.001)
    }

    // MARK: Sequences

    /// The target for `level` on every fan, from its own bounds.
    func targets(level: Int) -> [Double]? {
        guard FanLimits.isValidLevel(level) else { return nil }
        let targets = fans.compactMap { FanLimits.targetRPM(level: level, min: $0.minimum, max: $0.maximum) }
        return targets.count == fans.count ? targets : nil
    }

    /// Takes every fan to `level`, as Vorssaint does (report §4):
    ///
    /// 1. mode 1 and the target, back to back, for each fan — the firmware
    ///    can take automatic mode back between two separate writes;
    /// 2. a quarter-second settle, then verification;
    /// 3. only if that failed *and* the Mac has `Ftst`: the unlock, the
    ///    target at maximum, three seconds, manual mode retried for up to
    ///    six, then the real target and verification again.
    ///
    /// Nil on success. On failure after anything was written, the fans are
    /// handed back before returning `controlFailed`. `otherAppControls` and
    /// `unsupportedHardware` mean nothing was written.
    func start(level: Int) -> FanHelperError? {
        guard let targets = targets(level: level) else { return .invalidRequest }
        guard allAutomatic(), !unlockEngaged() else { return .otherAppControls }

        for (fan, target) in zip(fans, targets) {
            _ = setManual(fan)
            _ = setTarget(fan, rpm: target)
        }
        sleep(timing.settle)
        if confirm(targets, attempts: timing.verifyAttempts) {
            activeTargets = targets
            return nil
        }

        // A stopped fan on some Macs rejects manual mode until the
        // automatic controller has accepted a protective maximum.
        guard unlock != nil, retry(timing.modeAttempts, { setUnlock(true) && unlockEngaged() })
        else { return failStart() }
        for fan in fans {
            guard retry(timing.targetAttempts, { setTarget(fan, rpm: fan.maximum) }) else { return failStart() }
        }
        sleep(timing.unlockWait)
        for fan in fans {
            let deadline = clock() + timing.manualWindow
            var manual = false
            repeat {
                if setManual(fan), modeByte(fan) == 1 { manual = true; break }
                sleep(timing.manualGap)
            } while clock() < deadline
            guard manual else { return failStart() }
        }
        for (fan, target) in zip(fans, targets) {
            let set = retry(timing.targetAttempts) {
                _ = setManual(fan)
                return setTarget(fan, rpm: target)
                    && Self.targetMatches(reader.value(fan.target), expected: target)
                    && modeByte(fan) == 1
            }
            guard set else { return failStart() }
        }
        guard confirm(targets, attempts: timing.verifyAttempts) else { return failStart() }
        activeTargets = targets
        return nil
    }

    private func failStart() -> FanHelperError {
        _ = restore()
        return .controlFailed
    }

    /// A new level while the helper holds the fans. It writes targets only,
    /// and only while every fan still reads manual *at a target this process
    /// wrote*: if the firmware has taken a fan back, or another controller
    /// has set one (manual reads 1 for it too), this reports failure rather
    /// than writing — the caller's hand-back then yields to that controller.
    func update(level: Int) -> Bool {
        guard let targets = targets(level: level),
              fans.allSatisfy({ modeByte($0) == 1 }),
              !heldByAnother()
        else { return false }
        for (fan, target) in zip(fans, targets) {
            guard retry(timing.targetAttempts, {
                setTarget(fan, rpm: target) && Self.targetMatches(reader.value(fan.target), expected: target)
            }) else { return false }
        }
        guard confirm(targets, attempts: timing.verifyAttempts) else { return false }
        activeTargets = targets
        return true
    }

    /// One look: every fan manual, every target where it was put.
    func verify() -> Bool {
        !activeTargets.isEmpty && confirm(activeTargets, attempts: 1)
    }

    /// Back to the firmware: for each fan mode 0, retried with read-back,
    /// then target 0 (the firmware ignores a target in automatic mode, so
    /// a refusal here is not a failure); then `Ftst` 0 where it exists.
    /// True only if every fan reads automatic and `Ftst`, if any, reads 0.
    func restore() -> Bool {
        for fan in fans {
            _ = retry(timing.modeAttempts) {
                _ = setAutomatic(fan)
                return modeByte(fan).map(FanLimits.isAutomatic(mode:)) == true
            }
            _ = retry(timing.targetAttempts) { zeroTarget(fan) }
        }
        if unlock != nil {
            _ = retry(timing.modeAttempts) { setUnlock(false) && !unlockEngaged() }
        }
        let released = allAutomatic() && !unlockEngaged()
        if released { forgetHold() }
        return released
    }

    // MARK: Another controller

    /// Whether another controller has set a fan this process took: a fan
    /// out of automatic mode but not at mode 1 and a target written here,
    /// or `Ftst` set when this process never set it. The firmware only
    /// ever takes a fan back *to automatic* (report §3.3.2, W11), so this
    /// is never the firmware. False when nothing was written since the last
    /// hand-back: a relaunched helper cannot tell its own leftovers from
    /// anyone's, and the marker says they are its own.
    func heldByAnother() -> Bool {
        guard !written.isEmpty else { return false }
        if unlock != nil, !setUnlockItself, unlockEngaged() { return true }
        return fans.indices.contains { position in
            guard let mode = modeByte(fans[position]), !FanLimits.isAutomatic(mode: mode) else { return false }
            return !holdsOwn(position, mode: mode)
        }
    }

    /// Hands back only what is still this process's: each fan at mode 1 and
    /// a target written here goes to mode 0, then target 0, as in
    /// `restore`. A fan another controller holds is not written to, and
    /// neither is `Ftst`, which that controller may need. True once no fan
    /// reads as this process's.
    func yield() -> Bool {
        for position in fans.indices where holdsOwn(position) {
            let fan = fans[position]
            _ = retry(timing.modeAttempts) {
                _ = setAutomatic(fan)
                return modeByte(fan).map(FanLimits.isAutomatic(mode:)) == true
            }
            _ = retry(timing.targetAttempts) { zeroTarget(fan) }
        }
        let released = !fans.indices.contains { holdsOwn($0) }
        if released { forgetHold() }
        return released
    }

    /// Mode 1 at a target this process wrote. A mode that cannot be read,
    /// or a target that cannot, counts as this process's: handing a fan
    /// back is the side to err on.
    private func holdsOwn(_ position: Int, mode known: UInt8? = nil) -> Bool {
        let fan = fans[position]
        guard let mode = known ?? modeByte(fan) else { return true }
        guard mode == 1 else { return false }
        guard let value = reader.value(fan.target) else { return true }
        return (written[position] ?? []).contains { Self.targetMatches(value, expected: $0) }
    }

    private func forgetHold() {
        activeTargets = []
        written = [:]
        setUnlockItself = false
    }

    private func confirm(_ targets: [Double], attempts: Int) -> Bool {
        guard targets.count == fans.count else { return false }
        return retry(attempts, gap: timing.verifyGap) {
            zip(fans, targets).allSatisfy { fan, target in
                modeByte(fan) == 1 && Self.targetMatches(reader.value(fan.target), expected: target)
            }
        }
    }

    private func retry(_ attempts: Int, gap: TimeInterval? = nil, _ body: () -> Bool) -> Bool {
        for attempt in 0..<max(1, attempts) {
            if body() { return true }
            if attempt + 1 < attempts { sleep(gap ?? timing.retryGap) }
        }
        return false
    }
}

// MARK: - AppleSMC, command 6

/// The helper's own connection to AppleSMC, for writes alone. Private to
/// this file: nothing else in LocalNook can build a write.
private final class AppleSMCWritePort: SMCWritePort {
    private static let selector: UInt32 = 2
    private static let commandWrite: UInt8 = 6
    private var connection: io_connect_t = 0

    /// The parameter block as laid out here, which must match what
    /// LocalNookSMC verified on real hardware.
    private static var layout: SMCLayout {
        SMCLayout(size: MemoryLayout<WriteParamStruct>.size,
                  stride: MemoryLayout<WriteParamStruct>.stride,
                  keyInfo: MemoryLayout<WriteParamStruct>.offset(of: \.keyInfo) ?? -1,
                  result: MemoryLayout<WriteParamStruct>.offset(of: \.result) ?? -1,
                  data8: MemoryLayout<WriteParamStruct>.offset(of: \.data8) ?? -1,
                  data32: MemoryLayout<WriteParamStruct>.offset(of: \.data32) ?? -1,
                  bytes: MemoryLayout<WriteParamStruct>.offset(of: \.bytes) ?? -1,
                  keyInfoSize: MemoryLayout<WriteKeyInfo>.size)
    }

    init?() {
        guard Self.layout == .expected else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess, connection != 0
        else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func write(_ bytes: [UInt8], to key: SMCKey) -> SMCWriteOutcome {
        // A second, independent check of the writer's allowlist, on the
        // code sent below as well as the name.
        precondition(FanKeyAllowlist.permits(key, among: FanKeyAllowlist.everyFanKey),
                     "AppleSMCWritePort refuses to write \(key.name)")
        guard (1...32).contains(key.size), bytes.count == Int(key.size) else { return .refused }
        var input = WriteParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.size
        input.data8 = Self.commandWrite
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: bytes) }
        var output = WriteParamStruct()
        var outputSize = MemoryLayout<WriteParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, Self.selector,
                                               &input, MemoryLayout<WriteParamStruct>.stride,
                                               &output, &outputSize)
        guard result == kIOReturnSuccess else { return .transport(result) }
        guard output.result == 0 else { return .controller(output.result) }
        return .written
    }
}

// The same 80-byte block as SMCReader's (SMCKit's `SMCParamStruct`, MIT; see
// the header), private to this file.

private struct WriteVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct WritePLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct WriteKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct WriteParamStruct {
    var key: UInt32 = 0
    var vers = WriteVersion()
    var pLimitData = WritePLimitData()
    var keyInfo = WriteKeyInfo()
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
