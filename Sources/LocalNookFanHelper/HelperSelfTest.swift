//
//  HelperSelfTest.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  `LocalNookFanHelper --self-test`: everything about the helper that can be
//  checked without root, without a fan and without touching the Mac's sleep.
//
//  The writer runs against a register file that plays the controller — its
//  firmware can refuse manual mode, insist on `Ftst` first, or take a fan
//  back — so the start, update, verify and hand-back sequences are exercised
//  write by write, and the watchdog's temperature reader read by read. The
//  controller runs against a hardware double with its
//  timings shortened, so a 7 s lease lapses in under half a second. The lock
//  and marker files are the real ones, in a temporary directory, checked
//  against this user's uid instead of root's. And the XPC surface is driven
//  end to end through an anonymous listener in this process.
//
//  The sleep hold (HelperSleepHoldSelfTest.swift) runs the same way: its
//  controller against doubles for pmset, the IORegistry, the power source,
//  the temperature and the sleep request, with its record a real file in the
//  temporary directory; the spawn's mechanics against harmless system
//  programs (true, false, sleep, sh), never pmset.
//
//  Nothing here opens AppleSMC, listens on the Mach service, runs pmset, asks
//  the Mac to sleep, writes outside its temporary directory, or needs any
//  privilege. The release build runs it as the builder.
//

import Foundation
import LocalNookSMC
import ObjectiveC

final class HelperSelfTest {
    private var passed = 0
    private var failed = 0
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("LocalNookFanHelper-selftest-\(UUID().uuidString)", isDirectory: true)

    static func run() -> Int32 {
        let test = HelperSelfTest()
        print("LocalNookFanHelper self-test (no root, no SMC writes, no Mach service)")
        test.runAll()
        print(test.failed == 0 ? "helper self-test: \(test.passed) passed"
                               : "helper self-test: \(test.passed) passed, \(test.failed) failed")
        return test.failed == 0 ? 0 : 1
    }

    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)" + (detail.isEmpty ? "" : "  — \(detail)"))
        }
    }

    private func runAll() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        testPureLogic()
        testWireContract()
        testAllowlist()
        testWriter()
        testWatchdogReader()
        testOwnershipFiles()
        testPolicy()
        testController()
        testSleepHoldCommand()
        testSleepHoldPolicy()
        testSleepHoldRecord()
        testSleepHoldController()
        testXPC()
        testLaunchdPlist()
    }

    // MARK: Pure logic

    private func testPureLogic() {
        print("\nPure logic")
        check("a little-endian float decodes",
              SMCCodec.decode(bytes: [0x00, 0x80, 0xd4, 0x45], type: "flt ") == 6800)
        check("a fan target encodes back to the same bytes",
              SMCCodec.encodeFloatLE(6800) == [0x00, 0x80, 0xd4, 0x45])
        check("a negative target cannot be encoded", SMCCodec.encodeFloatLE(-1) == nil)
        check("a level is validated in 5% steps",
              FanMode.fixed(level: 55).isValid && !FanMode.fixed(level: 52).isValid
                  && !FanMode.fixed(level: 105).isValid)
        check("0% is the firmware minimum, never a stopped fan",
              FanLimits.targetRPM(level: 0, min: 2317, max: 6800) == 2317)
        check("the target never exceeds the firmware maximum",
              FanLimits.targetRPM(level: 150, min: 2317, max: 6800) == 6800)
        check("the log names Max, a fixed level and Cool apart",
              FanController.modeName(.fixed(level: 100)) == "Max"
                  && FanController.modeName(.fixed(level: 50)) == "50%"
                  && FanController.modeName(.cool) == "Cool"
                  && FanController.modeName(.automatic) == "Auto")
        check("Cool rounds up to the next 5%", FanCurve.cool.level(at: 60.1) == 40)
        check("Cool lowers only past the hysteresis", FanCurve.cool.level(at: 59.5, previous: 40) == 40)
        check("an oversized request is refused before decoding",
              FanRequest.decode(Data(repeating: 0x20, count: FanHelperIdentity.maxPayloadBytes + 1)) == nil)
        check("a malformed pin is refused",
              CodeSigningPin.requirement(identifier: FanHelperIdentity.appIdentifier, leafSHA1: "not-a-hash") == nil)
        let pin = CodeSigningPin.requirement(identifier: FanHelperIdentity.appIdentifier,
                                             leafSHA1: String(repeating: "a1", count: 20))
        check("the pin the listener would use compiles, naming the app and the leaf",
              pin == "identifier \"com.localnook.app\" and certificate leaf = H\"\(String(repeating: "a1", count: 20))\"",
              pin ?? "nil")
        check("the helper's identity is one name for label, service and signature",
              FanHelperIdentity.label == "com.localnook.app.fan-helper"
                  && FanHelperIdentity.installedBinary.hasSuffix("/" + FanHelperIdentity.label))
        check("power: an idle-sleep query is allowed, will-sleep hands back first",
              SystemPowerWatcher.response(to: 0xE000_0270) == .allow
                  && SystemPowerWatcher.response(to: 0xE000_0280) == .handBackThenAllow)
        check("…either power-on message (will-power-on, has-powered-on) ends the sleep gate",
              SystemPowerWatcher.response(to: 0xE000_0320) == .poweredOn
                  && SystemPowerWatcher.response(to: 0xE000_0300) == .poweredOn)
        check("…and will-not-sleep, which never follows will-sleep, changes nothing",
              SystemPowerWatcher.response(to: 0xE000_0290) == .ignore)
    }

    // MARK: The wire, against the shared contract

    /// The helper's own encoder and decoder against LocalNookShared's
    /// `HelperWireContract`, the texts installed revision-3 helpers speak.
    /// The app's suite checks its side against the same strings
    /// (FanWireTests), so a byte moved on either side fails one of them.
    /// Checks only: nothing the helper does changes.
    private func testWireContract() {
        print("\nThe wire, against the shared contract")
        typealias C = HelperWireContract
        func text<Value: Encodable>(_ value: Value) -> String {
            FanWire.encode(value).map { String(decoding: $0, as: UTF8.self) } ?? "nil"
        }
        func read<Value: Decodable>(_ type: Value.Type, _ text: String) -> Value? {
            FanWire.decode(type, from: Data(text.utf8))
        }
        check("the contract is this helper's revision, cap and service name",
              C.revision == FanHelperIdentity.revision && C.maxPayloadBytes == FanHelperIdentity.maxPayloadBytes
                  && C.machServiceName == FanHelperIdentity.label)
        check("each request is written as the contract has it",
              text(FanRequest(mode: .automatic)) == C.requestAutomatic && text(FanRequest(mode: .cool)) == C.requestCool
                  && text(FanRequest(mode: .fixed(level: 50))) == C.requestFixed50
                  && text(FanRequest(mode: .fixed(level: 100))) == C.requestFixed100)
        check("…and the contract's text reads back as that request",
              FanRequest.decode(Data(C.requestAutomatic.utf8)) == FanRequest(mode: .automatic)
                  && FanRequest.decode(Data(C.requestCool.utf8)) == FanRequest(mode: .cool)
                  && FanRequest.decode(Data(C.requestFixed50.utf8)) == FanRequest(mode: .fixed(level: 50))
                  && FanRequest.decode(Data(C.requestFixed100.utf8)) == FanRequest(mode: .fixed(level: 100)))
        check("the requests the contract says are refused are refused",
              C.refusedRequests.count == 3 && C.refusedRequests.allSatisfy { FanRequest.decode(Data($0.utf8)) == nil })

        let fan = FanReading(index: 0, rpm: 3100, minimum: 2317, maximum: 6800, target: 3200, mode: 1)
        let held = FanHelperStatus(mode: .cool, owner: .thisConnection, fans: [fan], hottest: 71.5,
                                   lastHandBack: .tooHot)
        let other = FanHelperStatus(owner: .otherApp, otherController: "Vorssaint", error: .otherAppControls)
        let fixed = FanHelperStatus(mode: .fixed(level: 85), owner: .localNookOtherConnection)
        check("each status is written as the contract has it",
              text(FanHelperStatus()) == C.statusDefault && text(held) == C.statusHeld
                  && text(other) == C.statusOtherApp && text(fixed) == C.statusFixed85,
              text(held))
        check("…a fan with no target or mode too",
              text(FanReading(index: 1, rpm: 2400.5, minimum: 2317, maximum: 6800)) == C.fanWithoutTargetOrMode)
        check("…and the contract's text reads back as that status",
              FanHelperStatus.decode(Data(C.statusDefault.utf8)) == FanHelperStatus()
                  && FanHelperStatus.decode(Data(C.statusHeld.utf8)) == held
                  && FanHelperStatus.decode(Data(C.statusOtherApp.utf8)) == other
                  && FanHelperStatus.decode(Data(C.statusFixed85.utf8)) == fixed)

        // Every case, listed; the switches below stop compiling if a case is
        // added, so the lists cannot fall behind the enumerations.
        let owners: [FanOwner] = [.system, .thisConnection, .localNookOtherConnection, .otherApp]
        for owner in owners { switch owner { case .system, .thisConnection, .localNookOtherConnection, .otherApp: break } }
        let reasons: [FanHandBackReason] = [.userChose, .appGone, .sleep, .tooHot, .thermalPressure, .systemTookOver,
                                            .otherAppTookOver, .sensorsLost, .helperRestarted, .helperStopping]
        for reason in reasons {
            switch reason {
            case .userChose, .appGone, .sleep, .tooHot, .thermalPressure, .systemTookOver,
                 .otherAppTookOver, .sensorsLost, .helperRestarted, .helperStopping: break
            }
        }
        let errors: [FanHelperError] = [.noFans, .unsupportedHardware, .otherAppControls, .invalidRequest,
                                        .controlFailed, .notRoot, .asleep]
        for error in errors {
            switch error {
            case .noFans, .unsupportedHardware, .otherAppControls, .invalidRequest, .controlFailed, .notRoot, .asleep:
                break
            }
        }
        check("the enumerations' words are the contract's, no more and no fewer",
              Set(owners.map(\.rawValue)) == C.owners && Set(reasons.map(\.rawValue)) == C.handBackReasons
                  && Set(errors.map(\.rawValue)) == C.errors
                  && owners.count == C.owners.count && reasons.count == C.handBackReasons.count
                  && errors.count == C.errors.count)

        check("the sleep hold's messages are written as the contract has them",
              text(SleepHoldRequest(action: .status)) == C.sleepHoldStatusRequest
                  && text(SleepHoldRequest(action: .start(allowBattery: true))) == C.sleepHoldStartOnBattery
                  && text(SleepHoldRequest(action: .release(.sessionEnded))) == C.sleepHoldRelease
                  && text(SleepHoldStatus()) == C.sleepHoldStatusDefault
                  && read(SleepHoldRequest.self, C.sleepHoldRelease) == SleepHoldRequest(action: .release(.sessionEnded)))

        var count: UInt32 = 0
        var selectors: Set<String> = []
        if let list = protocol_copyMethodDescriptionList(FanHelperXPC.self, true, true, &count) {
            for index in 0..<Int(count) {
                if let name = list[index].name { selectors.insert(NSStringFromSelector(name)) }
            }
            free(list)
        }
        check("the XPC interface exports exactly the contract's five selectors",
              selectors == C.selectors && count == 5, "\(selectors.sorted())")
    }

    // MARK: The allowlist

    private func testAllowlist() {
        print("\nThe write allowlist")
        let one = FanKeyAllowlist.keys(fanCount: 1)
        check("one fan: its mode (both spellings), its target and Ftst, nothing else",
              one == ["F0Md", "F0md", "F0Tg", "Ftst"], "\(one.sorted())")
        for name in ["F0Ac", "F0Mn", "F0Mx", "FNum", "F1Md", "F1Tg", "TC0P", "Ftsu", "F0MD", "#KEY", ""] {
            check("a Mac with one fan cannot have \(name.isEmpty ? "an empty name" : name) written",
                  !FanKeyAllowlist.permits(name, fanCount: 1))
        }
        check("fan 7 is writable only on a Mac with eight fans",
              FanKeyAllowlist.permits("F7Tg", fanCount: 8) && !FanKeyAllowlist.permits("F7Tg", fanCount: 7))
        check("a fan count outside 1…8 permits nothing",
              FanKeyAllowlist.keys(fanCount: 0).isEmpty && FanKeyAllowlist.keys(fanCount: 9).isEmpty
                  && FanKeyAllowlist.keys(fanCount: -1).isEmpty)
        check("the port's fixed superset is eight fans' keys and Ftst",
              FanKeyAllowlist.everyFanKey.count == 25 && FanKeyAllowlist.everyFanKey.contains("Ftst"))
        let spoofed = SMCKey(code: SMCCodec.fourCC("TC0P") ?? 0, name: "F0Tg", size: 4, type: "flt ", attributes: 0)
        let genuine = SMCKey(code: SMCCodec.fourCC("F0Tg") ?? 0, name: "F0Tg", size: 4, type: "flt ", attributes: 0)
        check("a key whose code is not its name is refused, whatever the name says",
              !FanKeyAllowlist.permits(spoofed, among: one)
                  && !FanKeyAllowlist.permits(spoofed, among: FanKeyAllowlist.everyFanKey))
        check("…and one whose code spells an allowed name is permitted",
              FanKeyAllowlist.permits(genuine, among: one)
                  && FanKeyAllowlist.permits(genuine, among: FanKeyAllowlist.everyFanKey)
                  && !FanKeyAllowlist.permits(genuine, among: FanKeyAllowlist.keys(fanCount: 0)))
        let target = SMCKey(code: 0, name: "F0Tg", size: 4, type: "flt ", attributes: 0)
        check("a target encodes only as a four-byte float",
              SMCFanWriter.encodeTarget(4558.5, for: target) == SMCCodec.encodeFloatLE(4558.5)
                  && SMCFanWriter.encodeTarget(4558.5, for: SMCKey(code: 0, name: "F0Tg", size: 2,
                                                                   type: "fpe2", attributes: 0)) == nil
                  && SMCFanWriter.encodeTarget(-1, for: target) == nil)
        check("a target within max(2 rpm, 0.1%) matches, beyond it does not",
              SMCFanWriter.targetMatches(4560, expected: 4558.5)
                  && !SMCFanWriter.targetMatches(4570, expected: 4558.5)
                  && !SMCFanWriter.targetMatches(nil, expected: 4558.5)
                  && !SMCFanWriter.targetMatches(.nan, expected: 4558.5))
    }

    // MARK: The writer

    private func instantTiming() -> FanWriteTiming {
        FanWriteTiming(settle: 0, verifyAttempts: 2, verifyGap: 0, modeAttempts: 3, targetAttempts: 2,
                       retryGap: 0, unlockWait: 0, manualWindow: 0.05, manualGap: 0.001)
    }

    private func writer(for smc: FakeSMC) -> SMCFanWriter? {
        guard case .success(let found) = SMCFanWriter.discover(using: smc) else { return nil }
        return SMCFanWriter(fans: found.fans, unlock: found.unlock, reader: smc, port: smc,
                            timing: instantTiming(), sleep: { _ in })
    }

    private func testWriter() {
        print("\nThe writer, against a register file")

        // Discovery.
        let m3 = FakeSMC()
        if case .success(let found) = SMCFanWriter.discover(using: m3) {
            check("this M3's layout: one fan, F0Md, bounds 2317…6800, no Ftst",
                  found.fans.count == 1 && found.fans[0].mode.name == "F0Md"
                      && found.fans[0].minimum == 2317 && found.fans[0].maximum == 6800 && found.unlock == nil)
        } else {
            check("this M3's layout is discovered", false)
        }
        let lower = FakeSMC(lowercaseMode: true)
        if case .success(let found) = SMCFanWriter.discover(using: lower) {
            check("F<n>md is preferred where the Mac has it (M5)", found.fans[0].mode.name == "F0md")
        } else {
            check("F<n>md is discovered", false)
        }
        func discoveryError(_ smc: FakeSMC) -> FanHelperError? {
            if case .failure(let error) = SMCFanWriter.discover(using: smc) { return error }
            return nil
        }
        check("no FNum: no fans", discoveryError(FakeSMC(fanCount: nil)) == .noFans)
        check("FNum 0: no fans", discoveryError(FakeSMC(fanCount: 0)) == .noFans)
        check("FNum 9: not a Mac this trusts", discoveryError(FakeSMC(fanCount: 9)) == .unsupportedHardware)
        check("a target that is not a float: unsupported",
              discoveryError(FakeSMC(targetType: "ui16")) == .unsupportedHardware)
        check("bounds that make no sense: unsupported",
              discoveryError(FakeSMC(minimum: 7000, maximum: 6800)) == .unsupportedHardware)

        // The direct path.
        let direct = FakeSMC()
        guard let writer = writer(for: direct) else { return check("a writer for the M3 layout", false) }
        check("a start at 50% succeeds on the direct path", writer.start(level: 50) == nil)
        check("mode 1 and the target were written back to back",
              direct.writes == ["F0Md=1", "F0Tg=4558.5"], "\(direct.writes)")
        check("50% is min + half the range: 4,558.5 rpm", direct.float("F0Tg") == 4558.5)
        check("verification sees manual mode at the target", writer.verify())
        direct.clearWrites()
        check("a target beyond the maximum is written as the maximum",
              writer.setTarget(writer.fans[0], rpm: 99_999) && direct.float("F0Tg") == 6800)
        check("a target of 0 through setTarget is the minimum, never a stopped fan",
              writer.setTarget(writer.fans[0], rpm: 0) && direct.float("F0Tg") == 2317)
        check("a target that is not a number is not written",
              !writer.setTarget(writer.fans[0], rpm: .nan) && direct.writes.count == 2, "\(direct.writes)")
        direct.clearWrites()
        check("an update to Max writes the target only", writer.update(level: 100)
                  && direct.writes == ["F0Tg=6800.0"], "\(direct.writes)")
        direct.firmwareSets("F0Md", [3])
        direct.clearWrites()
        check("when the firmware takes the fan back, verification fails", !writer.verify())
        check("…and an update does not take it again", !writer.update(level: 50) && direct.writes.isEmpty,
              "\(direct.writes)")
        direct.firmwareSets("F0Md", [1])
        direct.clearWrites()
        check("the hand-back succeeds", writer.restore())
        check("it writes mode 0, then target 0 — zero only here",
              direct.writes == ["F0Md=0", "F0Tg=0.0"], "\(direct.writes)")
        check("afterwards the fan reads automatic", direct.bytes("F0Md") == [0])

        // Someone else's fans.
        let held = FakeSMC()
        held.firmwareSets("F0Md", [1])
        if let other = self.writer(for: held) {
            check("a fan already in manual mode is someone else's: nothing written",
                  other.start(level: 50) == .otherAppControls && held.writes.isEmpty, "\(held.writes)")
        }
        let unlocked = FakeSMC(unlock: true)
        unlocked.firmwareSets("Ftst", [1])
        if let other = self.writer(for: unlocked) {
            check("an Ftst already set is someone else's unlock: nothing written",
                  other.start(level: 50) == .otherAppControls && unlocked.writes.isEmpty)
        }

        // The firmware refuses manual mode, and there is no Ftst.
        let stubborn = FakeSMC()
        stubborn.rejectsManual = true
        if let other = self.writer(for: stubborn) {
            check("no Ftst and manual mode will not stick: controlFailed", other.start(level: 50) == .controlFailed)
            check("…and the fan is handed back rather than forced",
                  stubborn.bytes("F0Md") == [0] && stubborn.writes.last == "F0Tg=0.0"
                      && !stubborn.writes.contains { $0.hasPrefix("Ftst") }, "\(stubborn.writes)")
        }

        // Manual mode sticks only after Ftst and a protective maximum.
        let needsUnlock = FakeSMC(unlock: true)
        needsUnlock.manualNeedsUnlock = true
        if let other = self.writer(for: needsUnlock) {
            check("with Ftst, the fallback takes the fan", other.start(level: 50) == nil, "\(needsUnlock.writes)")
            check("…by Ftst 1, the maximum, manual mode, then the real target",
                  needsUnlock.writes.contains("Ftst=1") && needsUnlock.writes.contains("F0Tg=6800.0")
                      && needsUnlock.float("F0Tg") == 4558.5 && needsUnlock.bytes("F0Md") == [1])
            check("…its own Ftst and protective maximum do not read as another app's", !other.heldByAnother())
            check("…and the hand-back clears Ftst too",
                  other.restore() && needsUnlock.bytes("Ftst") == [0] && needsUnlock.bytes("F0Md") == [0])
        }

        // A controller that answers writes with an error byte.
        let refusing = FakeSMC()
        refusing.failing = ["F0Tg"]
        if let other = self.writer(for: refusing) {
            check("a refused target write is a failed start", other.start(level: 50) == .controlFailed)
        }

        // Another controller sets a fan while the helper holds it.
        let shared = FakeSMC()
        if let own = self.writer(for: shared) {
            _ = own.start(level: 50)
            check("the helper's own fan is not another app's", !own.heldByAnother())
            shared.firmwareSets("F0Md", [3])
            check("nor is the firmware taking it back to automatic", !own.heldByAnother())
            shared.firmwareSets("F0Md", [1])
            shared.firmwareSets("F0Tg", FakeSMC.float(6000))
            check("manual mode at a target the helper never wrote is another app's", own.heldByAnother())
            shared.clearWrites()
            check("yielding writes nothing to that fan, and counts as let go",
                  own.yield() && shared.writes.isEmpty && shared.bytes("F0Md") == [1]
                      && shared.float("F0Tg") == 6000, "\(shared.writes)")
            check("…after which nothing is the helper's", !own.heldByAnother())
        }
        let overwritten = FakeSMC()
        if let own = self.writer(for: overwritten) {
            _ = own.start(level: 50)
            // Manual reads 1 for the other app's hold too: only the target
            // says whose it is.
            overwritten.firmwareSets("F0Tg", FakeSMC.float(6000))
            overwritten.clearWrites()
            check("a new level is not written over another app's target: the update fails and writes nothing",
                  !own.update(level: 60) && overwritten.writes.isEmpty && overwritten.float("F0Tg") == 6000,
                  "\(overwritten.writes)")
        }
        let pair = FakeSMC(fanCount: 2)
        if let own = self.writer(for: pair) {
            _ = own.start(level: 50)
            pair.firmwareSets("F1Tg", FakeSMC.float(6000))
            pair.clearWrites()
            check("two fans, one set by another app: only the helper's goes back",
                  own.heldByAnother() && own.yield() && pair.writes == ["F0Md=0", "F0Tg=0.0"]
                      && pair.bytes("F0Md") == [0] && pair.bytes("F1Md") == [1], "\(pair.writes)")
        }
        let stepped = FakeSMC()
        if let own = self.writer(for: stepped) {
            _ = own.start(level: 50)
            _ = own.update(level: 100)
            stepped.firmwareSets("F0Tg", FakeSMC.float(4558.5))
            check("a target the helper wrote earlier in the hold is still its own", !own.heldByAnother())
        }
        let foreignUnlock = FakeSMC(unlock: true)
        if let own = self.writer(for: foreignUnlock) {
            _ = own.start(level: 50)
            foreignUnlock.firmwareSets("Ftst", [1])
            foreignUnlock.clearWrites()
            check("Ftst set by someone else during the hold is another app's, and yielding leaves it",
                  own.heldByAnother() && own.yield() && foreignUnlock.bytes("Ftst") == [1]
                      && !foreignUnlock.writes.contains { $0.hasPrefix("Ftst") }
                      && foreignUnlock.bytes("F0Md") == [0], "\(foreignUnlock.writes)")
        }
        let leftover = FakeSMC()
        leftover.firmwareSets("F0Md", [1])
        leftover.firmwareSets("F0Tg", FakeSMC.float(4558.5))
        if let fresh = self.writer(for: leftover) {
            check("a helper that has written nothing calls no fan another app's (a relaunch hands its own back)",
                  !fresh.heldByAnother())
        }
    }

    // MARK: The watchdog's reader

    private func testWatchdogReader() {
        print("\nThe watchdog's temperature reader")
        let smc = FakeSMC(sensors: true)
        let watchdog = SMCFanHardware.watchdogReader(source: smc, brandString: "Apple M3")
        _ = sample(watchdog)   // the first read walks the key list
        smc.clearReads()
        let steady = sample(watchdog)
        let touched = smc.reads
        check("it follows the hotter of processor and graphics: 72 °C", steady?.hottest == 72,
              "\(String(describing: steady?.hottest))")
        check("…reading no battery or fan key: the writer reads the fans, and nothing here uses the battery",
              !touched.isEmpty && !touched.contains { $0.hasPrefix("TB") || ThermalCatalog.isFanKeyName($0) },
              "\(touched)")
        let full = ThermalReader(source: smc, brandString: "Apple M3", interval: 1)
        _ = sample(full)
        smc.clearReads()
        let everything = sample(full)
        check("the app's reader, by default, still reads both",
              everything?.battery == 31 && everything?.fans.count == 1
                  && smc.reads.contains("TB0T") && smc.reads.contains("F0Ac"), "\(smc.reads)")
    }

    /// One `read()`, off the main thread as ThermalReader requires.
    private func sample(_ reader: ThermalReader) -> ThermalSnapshot? {
        wait { reply in DispatchQueue.global().async { reply(reader.read()) } }
    }

    // MARK: Lock and marker

    private func testOwnershipFiles() {
        print("\nLock and marker files (this user's uid standing in for root)")
        let base = directory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func files(_ name: String) -> (FanOwnershipFiles, lock: String, marker: String) {
            let lock = base.appendingPathComponent("\(name).lock").path
            let marker = base.appendingPathComponent("\(name).active").path
            return (FanOwnershipFiles(lockPath: lock, markerPath: marker,
                                      otherMarkerPath: base.appendingPathComponent("vorssaint").path,
                                      ownerUID: getuid()), lock, marker)
        }

        let (first, lock, marker) = files("plain")
        check("the lock is taken", first.acquire() && first.isHeld)
        check("the lock file is private to its owner", permissions(lock) == 0o600, String(permissions(lock), radix: 8))
        let (second, _, _) = files("plain")
        check("a second holder cannot take it while the first has it", !second.acquire())
        check("the marker is created while holding the lock", first.createMarker() && first.markerExists())
        check("it reads v1", (try? String(contentsOfFile: marker, encoding: .utf8)) == "v1\n")
        check("a second marker cannot be created over it", !first.createMarker())
        check("it is removed", first.removeMarker() && !first.markerExists()
                  && !FileManager.default.fileExists(atPath: marker))
        first.release()
        check("once released, the lock can be taken again", second.acquire())
        second.release()
        check("no marker without the lock", !second.createMarker())

        let (loose, _, looseMarker) = files("loose")
        FileManager.default.createFile(atPath: looseMarker, contents: Data("v1\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        check("a marker others can read is not trusted as ours", !loose.markerExists())
        check("…nor removed as ours", !loose.removeMarker() && FileManager.default.fileExists(atPath: looseMarker))

        let (linked, linkedLock, _) = files("linked")
        let elsewhere = base.appendingPathComponent("elsewhere").path
        FileManager.default.createFile(atPath: elsewhere, contents: nil, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.createSymbolicLink(atPath: linkedLock, withDestinationPath: elsewhere)
        check("a lock path that is a symbolic link is refused", !linked.acquire())

        let (hard, hardLock, _) = files("hard")
        FileManager.default.createFile(atPath: hardLock, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = link(hardLock, base.appendingPathComponent("second-name").path)
        check("a lock file with a second name is refused", !hard.acquire())

        let (wide, wideLock, _) = files("wide")
        FileManager.default.createFile(atPath: wideLock, contents: nil, attributes: [.posixPermissions: 0o666])
        chmod(wideLock, 0o666)
        check("a lock file others can write is refused", !wide.acquire())

        let (named, _, _) = files("named")
        check("Vorssaint's marker is noticed only when it exists", !named.otherControllerMarkerExists())
        FileManager.default.createFile(atPath: base.appendingPathComponent("vorssaint").path, contents: nil)
        check("…and noticed when it does", named.otherControllerMarkerExists())
    }

    private func permissions(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
    }

    // MARK: Policy

    private func testPolicy() {
        print("\nWhen to hand back")
        func reason(age: TimeInterval = 1, failures: Int = 0, sensors: Int = 0, hot: TimeInterval? = nil,
                    level: Int = 50, state: ProcessInfo.ThermalState = .nominal) -> FanHandBackReason? {
            FanControlPolicy.handBackReason(heartbeatAge: age, lease: 7, verificationFailures: failures,
                                            sensorFailures: sensors, hotFor: hot,
                                            tooHotAfter: FanLimits.tooHotSeconds,
                                            level: level, thermalState: state)
        }
        check("a healthy lease keeps the fans", reason() == nil)
        check("7 s is still within the lease; past it the app is gone",
              reason(age: 7) == nil && reason(age: 7.01) == .appGone)
        check("three failed verifications: macOS took over",
              reason(failures: 2) == nil && reason(failures: 3) == .systemTookOver)
        check("95 °C for 5 s below Max: too hot", reason(hot: 4.9) == nil && reason(hot: 5) == .tooHot)
        // Settings quotes FanLimits' figures; the watchdog must use the same.
        check("the watchdog's heat line and wait are the ones Settings quotes",
              FanLimits.tooHotCelsius == 95 && FanLimits.tooHotSeconds == 5
                  && FanController.Timing.standard.tooHotAfter == FanLimits.tooHotSeconds)
        check("at Max there is nothing more to give, so heat alone does not end it",
              reason(hot: 60, level: 100) == nil)
        check("three unreadable samples: sensors lost", reason(sensors: 2) == nil && reason(sensors: 3) == .sensorsLost)
        check("serious or critical thermal pressure ends it; fair does not",
              reason(state: .serious) == .thermalPressure && reason(state: .critical) == .thermalPressure
                  && reason(state: .fair) == nil)
        check("a fixed level starts where asked; Cool from the reading; Cool without one does not start",
              FanControlPolicy.level(for: .fixed(level: 50), hottest: nil, previous: nil) == 50
                  && FanControlPolicy.level(for: .cool, hottest: 60, previous: nil) == 35
                  && FanControlPolicy.level(for: .cool, hottest: nil, previous: nil) == nil
                  && FanControlPolicy.level(for: .fixed(level: 52), hottest: nil, previous: nil) == nil)
    }

    // MARK: The controller

    private struct Rig {
        let controller: FanController
        let hardware: FakeHardware
        let marker: String
        let otherMarker: String
        let lock: String
        let idle: Flag
        let thermal: ThermalBox
    }

    private static let quick = FanController.Timing(lease: 0.5, watchdog: 0.05, tooHotAfter: 0.2,
                                                     idleExit: 0.2, shutdownRetry: 0.5, retryGap: 0.05)

    private func rig(_ name: String, hardware: FakeHardware = FakeHardware()) -> Rig {
        let base = directory.appendingPathComponent("rig-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let lock = base.appendingPathComponent("lock").path
        let marker = base.appendingPathComponent("active").path
        let other = base.appendingPathComponent("vorssaint").path
        let ownership = FanOwnershipFiles(lockPath: lock, markerPath: marker, otherMarkerPath: other,
                                          ownerUID: getuid())
        hardware.markerPath = marker
        let idle = Flag()
        let thermal = ThermalBox()
        let controller = FanController(hardware: { .success(hardware) }, ownership: ownership,
                                       timing: Self.quick, thermalState: { thermal.state },
                                       onIdle: { idle.set() })
        return Rig(controller: controller, hardware: hardware, marker: marker, otherMarker: other,
                   lock: lock, idle: idle, thermal: thermal)
    }

    private func request(_ mode: FanMode) -> Data { FanWire.encode(FanRequest(mode: mode)) ?? Data() }

    private func testController() {
        print("\nThe controller, against a hardware double")
        let a = UUID(), b = UUID()

        // Status, and someone else's fans.
        let other = rig("other")
        other.hardware.set(mode: 1)
        other.controller.connectionOpened(a)
        let seen = wait { other.controller.status(for: a, reply: $0) }
        check("a fan held elsewhere reads as another app's", seen?.owner == .otherApp
                  && seen?.otherController == "another app", "\(String(describing: seen))")
        FileManager.default.createFile(atPath: other.otherMarker, contents: nil)
        let refused = wait { other.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("apply is refused as otherAppControls, naming Vorssaint by its marker",
              refused?.error == .otherAppControls && refused?.otherController == "Vorssaint",
              "\(String(describing: refused))")
        check("…with nothing started, nothing restored, and no marker left",
              other.hardware.starts == 0 && other.hardware.restores == 0
                  && !FileManager.default.fileExists(atPath: other.marker))

        // Taking the fans, and holding them on a lease.
        let main = rig("main")
        main.controller.connectionOpened(a)
        main.controller.connectionOpened(b)
        let idleStatus = wait { main.controller.status(for: a, reply: $0) }
        check("idle, the fans are the system's", idleStatus?.owner == .system && idleStatus?.mode == .automatic
                  && idleStatus?.revision == FanHelperIdentity.revision && idleStatus?.fans.count == 1)
        let taken = wait { main.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("apply at 50% makes this connection the owner", taken?.owner == .thisConnection
                  && taken?.mode == .fixed(level: 50) && taken?.error == nil, "\(String(describing: taken))")
        check("the hardware was asked for 50%", main.hardware.lastStartLevel == 50)
        check("the marker existed before the first write", main.hardware.markerExistedAtStart)
        check("the marker is there while the fans are held", FileManager.default.fileExists(atPath: main.marker))
        let intruder = FanOwnershipFiles(lockPath: main.lock, markerPath: main.marker,
                                         otherMarkerPath: main.otherMarker, ownerUID: getuid())
        check("the lock is held while the fans are", !intruder.acquire())
        let second = wait { main.controller.apply(request(.fixed(level: 100)), for: b, reply: $0) }
        check("another LocalNook connection is told the fans are held elsewhere, and changes nothing",
              second?.owner == .localNookOtherConnection && main.hardware.starts == 1
                  && main.controller.snapshot().level == 50)
        let bogus = wait { main.controller.apply(Data("{\"mode\":{\"fixed\":{\"level\":52}}}".utf8), for: a, reply: $0) }
        check("a level off the 5% grid is an invalid request", bogus?.error == .invalidRequest)
        let junk = wait { main.controller.apply(Data("not json".utf8), for: a, reply: $0) }
        check("so is something that is not a request", junk?.error == .invalidRequest)
        let huge = wait { main.controller.apply(Data(repeating: 0x7b, count: 5000), for: a, reply: $0) }
        check("so is anything over the 4 KB cap", huge?.error == .invalidRequest)
        check("none of them touched the fans", main.hardware.starts == 1 && main.hardware.updates.isEmpty)

        for _ in 0..<8 {
            _ = wait { main.controller.heartbeat(for: a, reply: $0) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        check("heartbeats keep the fans past the lease", main.controller.snapshot().isControlling)
        let higher = wait { main.controller.apply(request(.fixed(level: 100)), for: a, reply: $0) }
        check("the owner can change the level", higher?.mode == .fixed(level: 100)
                  && main.hardware.updates == [100], "\(main.hardware.updates)")
        check("the lease lapses without heartbeats: back to Auto, the app is gone",
              waitUntil { main.controller.snapshot().lastHandBack == .appGone } && main.controller.snapshot().isIdle)
        check("…the marker removed and the lock released",
              !FileManager.default.fileExists(atPath: main.marker) && intruder.acquire())
        intruder.release()

        // The owner goes away.
        _ = wait { main.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        main.controller.connectionClosed(a)
        check("the owner's connection closing hands the fans back",
              waitUntil { main.controller.snapshot().isIdle } && main.controller.snapshot().lastHandBack == .appGone)
        main.controller.connectionOpened(a)

        // The explicit hand-back.
        _ = wait { main.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        let chosen = wait { main.controller.restore(for: b, reply: $0) }
        check("restore from any authenticated connection: Auto, the user chose it",
              chosen?.owner == .system && chosen?.mode == .automatic && chosen?.lastHandBack == .userChose)
        let auto = wait { main.controller.apply(request(.automatic), for: a, reply: $0) }
        check("applying Auto when nothing is held changes nothing", auto?.error == nil
                  && main.controller.snapshot().isIdle)

        // The watchdog's reasons.
        func scenario(_ name: String, mode: FanMode = .fixed(level: 50), setUp: (Rig) -> Void,
                      expect: FanHandBackReason) {
            let r = rig(name)
            r.controller.connectionOpened(a)
            _ = wait { r.controller.apply(request(mode), for: a, reply: $0) }
            setUp(r)
            let handedBack = waitUntil(timeout: 3) {
                _ = self.wait { r.controller.heartbeat(for: a, reply: $0) }
                return r.controller.snapshot().lastHandBack != nil
            }
            let last = r.controller.snapshot().lastHandBack
            check("\(name): back to Auto as \(expect.rawValue)", handedBack && last == expect,
                  "got \(String(describing: last))")
        }
        scenario("the firmware takes the fans back", setUp: { $0.hardware.set(verifies: false) },
                 expect: .systemTookOver)
        scenario("95 °C for longer than allowed below Max", setUp: { $0.hardware.set(hottest: 96) },
                 expect: .tooHot)
        scenario("the sensors stop answering", setUp: { $0.hardware.set(hottest: nil) }, expect: .sensorsLost)
        scenario("macOS reports serious thermal pressure", setUp: { $0.thermal.state = .serious },
                 expect: .thermalPressure)

        let atMax = rig("max")
        atMax.controller.connectionOpened(a)
        _ = wait { atMax.controller.apply(request(.fixed(level: 100)), for: a, reply: $0) }
        atMax.hardware.set(hottest: 99)
        for _ in 0..<8 {
            _ = wait { atMax.controller.heartbeat(for: a, reply: $0) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        check("at Max, heat alone does not end control", atMax.controller.snapshot().isControlling)

        // Cool follows the temperature.
        let cool = rig("cool")
        cool.hardware.set(hottest: 60)
        cool.controller.connectionOpened(a)
        let cooling = wait { cool.controller.apply(request(.cool), for: a, reply: $0) }
        check("Cool starts from the reading: 60 °C is 35%", cooling?.mode == .cool
                  && cool.hardware.lastStartLevel == 35)
        cool.hardware.set(hottest: 80)
        let followed = waitUntil {
            _ = self.wait { cool.controller.heartbeat(for: a, reply: $0) }
            return cool.controller.snapshot().level == 85
        }
        check("…and rises with it: 80 °C is 85%", followed && cool.hardware.updates.contains(85),
              "\(cool.hardware.updates)")
        check("while held, status reports the hottest reading",
              wait { cool.controller.status(for: a, reply: $0) }?.hottest == 80)

        // Sleep.
        cool.controller.willSleep()
        check("before sleep the fans are handed back, synchronously",
              cool.controller.snapshot().isIdle && cool.controller.snapshot().lastHandBack == .sleep)
        let startsBeforeSleep = cool.hardware.starts
        let asleep = wait { cool.controller.apply(request(.cool), for: a, reply: $0) }
        check("until the Mac powers on, an apply is refused as asleep and nothing is started",
              asleep?.error == .asleep && asleep?.owner == .system && asleep?.lastHandBack == .sleep
                  && cool.hardware.starts == startsBeforeSleep && cool.controller.snapshot().isIdle
                  && !FileManager.default.fileExists(atPath: cool.marker), "\(String(describing: asleep))")
        let autoAsleep = wait { cool.controller.apply(request(.automatic), for: a, reply: $0) }
        check("…while Auto is still accepted", autoAsleep?.error == nil)
        cool.controller.poweredOn()
        let woken = wait { cool.controller.apply(request(.cool), for: a, reply: $0) }
        check("after power-on, the app's re-apply takes the fans again",
              woken?.owner == .thisConnection && cool.hardware.starts == startsBeforeSleep + 1
                  && !cool.controller.snapshot().isAsleep)
        check("…and a new hold does not carry the last hold's hand-back reason", woken?.lastHandBack == nil)
        _ = wait { cool.controller.restore(for: a, reply: $0) }

        let idleSleep = rig("idle-sleep")
        idleSleep.controller.connectionOpened(a)
        idleSleep.controller.willSleep()
        let idleAsleep = wait { idleSleep.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("a sleep announced with nothing held also holds off a start, and restores nothing",
              idleAsleep?.error == .asleep && idleSleep.hardware.starts == 0 && idleSleep.hardware.restores == 0)

        // Another app sets the fans while the helper holds them.
        let rival = rig("rival")
        rival.controller.connectionOpened(a)
        _ = wait { rival.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        rival.hardware.set(verifies: false)
        rival.hardware.set(foreign: true)
        let letGo = waitUntil(timeout: 3) {
            _ = self.wait { rival.controller.heartbeat(for: a, reply: $0) }
            return rival.controller.snapshot().lastHandBack != nil
        }
        check("another app taking the fans ends control as otherAppTookOver",
              letGo && rival.controller.snapshot().lastHandBack == .otherAppTookOver
                  && rival.controller.snapshot().isIdle,
              "\(String(describing: rival.controller.snapshot().lastHandBack))")
        check("…letting go of them without restoring the other app's fan, the marker removed",
              rival.hardware.restores == 0 && rival.hardware.yields == 1
                  && !FileManager.default.fileExists(atPath: rival.marker))
        let rivalStatus = wait { rival.controller.status(for: a, reply: $0) }
        check("…after which the fans read as another app's", rivalStatus?.owner == .otherApp)
        let rivalSleep = rig("rival-sleep")
        rivalSleep.controller.connectionOpened(a)
        _ = wait { rivalSleep.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        rivalSleep.hardware.set(foreign: true)
        rivalSleep.controller.willSleep()
        check("any hand-back, sleep included, leaves another app's fan alone",
              rivalSleep.controller.snapshot().lastHandBack == .sleep && rivalSleep.hardware.restores == 0
                  && rivalSleep.hardware.yields == 1)

        // …and while Cool, or the owner, moves to a new level.
        let rivalCurve = rig("rival-curve")
        rivalCurve.hardware.set(hottest: 60)
        rivalCurve.controller.connectionOpened(a)
        _ = wait { rivalCurve.controller.apply(request(.cool), for: a, reply: $0) }
        rivalCurve.hardware.set(foreign: true)
        rivalCurve.hardware.set(hottest: 80)
        let curveLetGo = waitUntil(timeout: 3) {
            _ = self.wait { rivalCurve.controller.heartbeat(for: a, reply: $0) }
            return rivalCurve.controller.snapshot().lastHandBack != nil
        }
        check("Cool reaching a new step over another app's fan writes nothing, and ends as otherAppTookOver",
              curveLetGo && rivalCurve.controller.snapshot().lastHandBack == .otherAppTookOver
                  && rivalCurve.hardware.updates.isEmpty && rivalCurve.hardware.yields == 1
                  && rivalCurve.hardware.restores == 0,
              "\(String(describing: rivalCurve.controller.snapshot().lastHandBack)) \(rivalCurve.hardware.updates)")
        let rivalChoice = rig("rival-choice")
        rivalChoice.hardware.set(hottest: 60)
        rivalChoice.controller.connectionOpened(a)
        _ = wait { rivalChoice.controller.apply(request(.cool), for: a, reply: $0) }
        rivalChoice.hardware.set(foreign: true)
        let changed = wait { rivalChoice.controller.apply(request(.fixed(level: 60)), for: a, reply: $0) }
        check("the owner choosing a new level over another app's fan: refused, nothing written, otherAppTookOver",
              changed?.error == .controlFailed && rivalChoice.controller.snapshot().lastHandBack == .otherAppTookOver
                  && rivalChoice.hardware.updates.isEmpty && rivalChoice.hardware.yields == 1
                  && rivalChoice.hardware.restores == 0 && rivalChoice.controller.snapshot().isIdle,
              "\(String(describing: changed))")

        // Sleep notifications that could not be registered for.
        let unwatched = rig("unwatched")
        unwatched.controller.sleepNotificationsUnavailable()
        unwatched.controller.connectionOpened(a)
        let unwatchedApply = wait { unwatched.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        let unwatchedCool = wait { unwatched.controller.apply(request(.cool), for: a, reply: $0) }
        check("with no sleep notifications, no fan is taken: refused as controlFailed, nothing started, no marker",
              unwatchedApply?.error == .controlFailed && unwatchedCool?.error == .controlFailed
                  && unwatched.hardware.starts == 0 && unwatched.controller.snapshot().isIdle
                  && !FileManager.default.fileExists(atPath: unwatched.marker),
              "\(String(describing: unwatchedApply))")
        let unwatchedStatus = wait { unwatched.controller.status(for: a, reply: $0) }
        let unwatchedAuto = wait { unwatched.controller.apply(request(.automatic), for: a, reply: $0) }
        let unwatchedRestore = wait { unwatched.controller.restore(for: a, reply: $0) }
        check("…while status, Auto and restore still answer",
              unwatchedStatus?.owner == .system && unwatchedStatus?.error == nil
                  && unwatchedAuto?.error == nil && unwatchedRestore?.error == nil)

        // A hand-back that does not confirm.
        let stuck = rig("stuck")
        stuck.controller.connectionOpened(a)
        _ = wait { stuck.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        stuck.hardware.set(restores: false)
        let unconfirmed = wait { stuck.controller.restore(for: a, reply: $0) }
        check("an unconfirmed hand-back is reported, and the helper keeps trying",
              unconfirmed?.error == .controlFailed && stuck.controller.snapshot().isRecovering)
        check("…with the marker kept", FileManager.default.fileExists(atPath: stuck.marker))
        let whileRecovering = wait { stuck.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("…and no new control while it does", whileRecovering?.error == .controlFailed
                  && stuck.hardware.starts == 1)
        stuck.hardware.set(restores: true)
        check("once the fans read automatic, the retry succeeds and the marker goes",
              waitUntil { stuck.controller.snapshot().isIdle }
                  && !FileManager.default.fileExists(atPath: stuck.marker))

        // A helper that died holding the fans.
        let relaunched = rig("relaunched")
        FileManager.default.createFile(atPath: relaunched.marker, contents: Data("v1\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        check("at launch, a marker means handing the fans back first",
              relaunched.controller.recoverAtLaunch() && relaunched.hardware.restores == 1
                  && relaunched.controller.snapshot().lastHandBack == .helperRestarted
                  && !FileManager.default.fileExists(atPath: relaunched.marker))
        check("with nobody connected, the helper then exits when idle", waitUntil { relaunched.idle.isSet })
        let quiet = rig("quiet")
        check("without a marker, launch touches no fan", quiet.controller.recoverAtLaunch()
                  && quiet.hardware.restores == 0)

        // Idle exit waits for connections and for control.
        let busy = rig("busy")
        busy.controller.connectionOpened(a)
        _ = wait { busy.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        busy.controller.connectionOpened(b)
        busy.controller.connectionClosed(b)
        Thread.sleep(forTimeInterval: 0.35)
        check("no idle exit while a connection is open or the fans are held", !busy.idle.isSet)

        // Starts that fail.
        let failing = rig("failing")
        failing.hardware.set(startResult: .controlFailed)
        failing.controller.connectionOpened(a)
        let failedStart = wait { failing.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("a start that wrote and failed is reported and handed back",
              failedStart?.error == .controlFailed && failing.hardware.restores >= 1
                  && failing.controller.snapshot().isIdle && !FileManager.default.fileExists(atPath: failing.marker))
        let raced = rig("raced")
        raced.hardware.set(startResult: .otherAppControls)
        raced.controller.connectionOpened(a)
        let lostRace = wait { raced.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        check("a start refused because another app took the fans first restores nothing of theirs",
              lostRace?.error == .otherAppControls && raced.hardware.restores == 0
                  && !FileManager.default.fileExists(atPath: raced.marker))

        // SIGTERM.
        let stopping = rig("stopping")
        stopping.controller.connectionOpened(a)
        _ = wait { stopping.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        let stopped = wait { stopping.controller.shutdown(completion: $0) }
        check("stopping hands the fans back before saying it may exit",
              stopped == true && stopping.controller.snapshot().lastHandBack == .helperStopping)
        let wedged = rig("wedged")
        wedged.controller.connectionOpened(a)
        _ = wait { wedged.controller.apply(request(.fixed(level: 50)), for: a, reply: $0) }
        wedged.hardware.set(restores: false)
        let gaveUp = wait(timeout: 5) { wedged.controller.shutdown(completion: $0) }
        check("…and gives up after its retry window, saying so", gaveUp == false
                  && wedged.hardware.restores > 2, "restores: \(wedged.hardware.restores)")
    }

    // MARK: XPC, end to end

    private func testXPC() {
        print("\nXPC, end to end through an anonymous listener")
        let r = rig("xpc")
        let hold = sleepHoldRig("xpc")
        let delegate = FanHelperListenerDelegate(controller: r.controller, sleepHold: hold.controller)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        func connect() -> (NSXPCConnection, FanHelperXPC?) {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPC.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FanHelperXPC
            return (connection, proxy)
        }
        func call(_ body: (@escaping @Sendable (Data) -> Void) -> Void) -> FanHelperStatus? {
            wait { reply in body { reply(FanHelperStatus.decode($0) ?? FanHelperStatus(error: .notRoot)) } }
        }

        let (connection, proxy) = connect()
        guard let proxy else { return check("a proxy for the helper's interface", false) }
        check("status crosses the connection", call { proxy.status($0) }?.owner == .system)
        let applied = call { proxy.apply(request(.fixed(level: 50)), reply: $0) }
        check("apply crosses it and makes this connection the owner",
              applied?.owner == .thisConnection && applied?.mode == .fixed(level: 50))
        check("heartbeat crosses it", call { proxy.heartbeat($0) }?.owner == .thisConnection)
        let restored = call { proxy.restore($0) }
        check("restore crosses it", restored?.owner == .system && restored?.lastHandBack == .userChose)

        _ = call { proxy.apply(request(.fixed(level: 50)), reply: $0) }
        check("the lease lapses across XPC too",
              waitUntil { r.controller.snapshot().lastHandBack == .appGone && r.controller.snapshot().isIdle })

        let invalid = call { proxy.apply(Data("{}".utf8), reply: $0) }
        check("an invalid request is refused", invalid?.error == .invalidRequest)
        let oversized = call { proxy.apply(Data(repeating: 0x20, count: 64 * 1024), reply: $0) }
        check("an oversized one too", oversized?.error == .invalidRequest)

        r.hardware.set(mode: 1)
        let refused = call { proxy.apply(request(.fixed(level: 50)), reply: $0) }
        check("another app's fans are refused across XPC", refused?.error == .otherAppControls
                  && refused?.owner == .otherApp)
        r.hardware.set(mode: 0)

        let (dropping, dropProxy) = connect()
        _ = call { dropProxy?.apply(request(.fixed(level: 50)), reply: $0) }
        check("a second connection takes the fans", r.controller.snapshot().isControlling)
        dropping.invalidate()
        check("invalidating that connection hands them back",
              waitUntil { r.controller.snapshot().isIdle } && r.controller.snapshot().lastHandBack == .appGone)

        // The sleep hold, on the same connection.
        func sleepHold(_ action: SleepHoldAction, on proxy: FanHelperXPC?) -> SleepHoldStatus? {
            guard let data = FanWire.encode(SleepHoldRequest(action: action)) else { return nil }
            return sleepHoldRaw(data, on: proxy)
        }
        func sleepHoldRaw(_ data: Data, on proxy: FanHelperXPC?) -> SleepHoldStatus? {
            wait { reply in
                proxy?.sleepHold(data) { reply(SleepHoldStatus.decode($0) ?? SleepHoldStatus(error: .controlFailed)) }
            }
        }
        let first = sleepHold(.status, on: proxy)
        check("the sleep hold's status crosses the connection, at this revision",
              first?.owner == .nobody && first?.revision == 3, "\(String(describing: first))")
        let held = sleepHold(.start(allowBattery: false), on: proxy)
        check("a start crosses it and holds for this connection", held?.isHolding == true
                  && hold.pmset.calls == [true], "\(String(describing: held))")
        check("a heartbeat crosses it", sleepHold(.heartbeat, on: proxy)?.isHolding == true)
        let released = sleepHold(.release(.sessionEnded), on: proxy)
        check("a release crosses it, with its reason", released?.owner == .nobody
                  && released?.lastEnd?.reason == .sessionEnded && hold.pmset.calls == [true, false])
        let junk = sleepHoldRaw(Data("{\"action\":{\"format\":{}}}".utf8), on: proxy)
        check("a request that is not one of the five is refused", junk?.error == .invalidRequest)

        let (holding, holdingProxy) = connect()
        _ = sleepHold(.start(allowBattery: false), on: holdingProxy)
        check("a second connection takes the hold", hold.controller.snapshot().isHolding)
        holding.invalidate()
        check("invalidating that connection restores sleep, as the app gone",
              waitUntil { hold.controller.snapshot().isIdle }
                  && hold.controller.snapshot().lastEnd?.reason == .appGone
                  && hold.pmset.calls.last == false)
        connection.invalidate()
    }

    // MARK: The launchd job

    private func testLaunchdPlist() {
        print("\nThe launchd job")
        func serialized(_ dictionary: NSDictionary) -> Data {
            (try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)) ?? Data()
        }
        let good = serialized(LaunchdPlistCheck.expected)
        check("the expected job matches itself", LaunchdPlistCheck.matches(good))
        func altered(_ change: (NSMutableDictionary) -> Void) -> Bool {
            guard let copy = LaunchdPlistCheck.expected.mutableCopy() as? NSMutableDictionary else { return false }
            change(copy)
            return LaunchdPlistCheck.matches(serialized(copy))
        }
        check("another Program is refused",
              !altered { $0["Program"] = "/tmp/something-else" })
        check("added arguments are refused", !altered { $0["ProgramArguments"] = ["/bin/sh", "-c", "id"] })
        check("an output path is refused", !altered { $0["StandardOutPath"] = "/etc/sudoers" })
        check("the job starts at load — at every boot — for the sleep hold's record",
              LaunchdPlistCheck.expected["RunAtLoad"] as? Bool == true)
        check("…and a job without RunAtLoad, or with it false, is refused",
              !altered { $0.removeObject(forKey: "RunAtLoad") } && !altered { $0["RunAtLoad"] = false })
        let pathState = (LaunchdPlistCheck.expected["KeepAlive"] as? NSDictionary)?["PathState"] as? NSDictionary
        check("launchd keeps the helper alive while the fans' marker or the sleep hold's record exists",
              pathState?.count == 2 && pathState?[FanHelperIdentity.markerPath] as? Bool == true
                  && pathState?[FanHelperIdentity.sleepHoldRecordPath] as? Bool == true)
        check("…the record beside the helper, not in /var/run, which a boot clears",
              FanHelperIdentity.sleepHoldRecordPath.hasPrefix("/Library/PrivilegedHelperTools/")
                  && !FanHelperIdentity.sleepHoldRecordPath.hasPrefix("/var/run"))
        check("a job that keeps only the fans' marker is refused", !altered {
            $0["KeepAlive"] = ["SuccessfulExit": false,
                               "PathState": [FanHelperIdentity.markerPath: true]] as [String: Any]
        })
        check("a missing key is refused", !altered { $0.removeObject(forKey: "KeepAlive") })
        check("true is not 1", !altered {
            $0["KeepAlive"] = ["SuccessfulExit": 0,
                               "PathState": [FanHelperIdentity.markerPath: 1,
                                             FanHelperIdentity.sleepHoldRecordPath: 1]] as [String: Any]
        })
        check("text that is not a property list is refused", !LaunchdPlistCheck.matches(Data("<plist".utf8)))
        let path = directory.appendingPathComponent("job.plist").path
        FileManager.default.createFile(atPath: path, contents: good)
        check("--verify-plist accepts the job on disk", LaunchdPlistCheck.run(path: path) == 0)
        // `verify`, not `run`: the refusal `run` prints on standard error
        // would land in the release build's log looking like a real one.
        check("…and refuses a file that is not there",
              !LaunchdPlistCheck.verify(path: directory.appendingPathComponent("absent").path))
    }

    // MARK: Waiting

    /// Calls `body` with a reply closure and waits for it.
    func wait<Value: Sendable>(timeout: TimeInterval = 5,
                                       _ body: (@escaping @Sendable (Value) -> Void) -> Void) -> Value? {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        body { value in
            box.set(value)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}

// MARK: - Doubles

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

final class ThermalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ProcessInfo.ThermalState.nominal
    var state: ProcessInfo.ThermalState {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The controller's view of a Mac with one fan, 2317…6800 rpm.
private final class FakeHardware: FanHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: UInt8 = 0
    private var hottest: Double? = 55
    private var verifies = true
    private var restoresOK = true
    private var foreign = false
    private var yieldCount = 0
    private var startResult: FanHelperError?
    private var target = 0.0
    private var startCount = 0
    private var restoreCount = 0
    private var updateLevels: [Int] = []
    private var startLevel: Int?
    private var sawMarker = false
    var markerPath = ""

    var starts: Int { lock.withLock { startCount } }
    var restores: Int { lock.withLock { restoreCount } }
    var yields: Int { lock.withLock { yieldCount } }
    var updates: [Int] { lock.withLock { updateLevels } }
    var lastStartLevel: Int? { lock.withLock { startLevel } }
    var markerExistedAtStart: Bool { lock.withLock { sawMarker } }

    func set(mode: UInt8) { lock.withLock { self.mode = mode } }
    func set(hottest: Double?) { lock.withLock { self.hottest = hottest } }
    func set(verifies: Bool) { lock.withLock { self.verifies = verifies } }
    func set(restores: Bool) { lock.withLock { restoresOK = restores } }
    /// Another app has set the fan: manual, at a target of its own.
    func set(foreign: Bool) {
        lock.withLock {
            self.foreign = foreign
            if foreign { mode = 1; target = 6000 }
        }
    }
    func set(startResult: FanHelperError?) { lock.withLock { self.startResult = startResult } }

    func readFans() -> [FanReading] {
        lock.withLock {
            [FanReading(index: 0, rpm: 2400, minimum: 2317, maximum: 6800, target: target, mode: mode)]
        }
    }

    func unlockEngaged() -> Bool { false }
    func readHottest() -> Double? { lock.withLock { hottest } }

    func start(level: Int) -> FanHelperError? {
        let marker = FileManager.default.fileExists(atPath: markerPath)
        return lock.withLock {
            startCount += 1
            startLevel = level
            sawMarker = marker
            if let startResult { return startResult }
            mode = 1
            target = FanLimits.targetRPM(level: level, min: 2317, max: 6800) ?? 0
            return nil
        }
    }

    /// As SMCFanWriter.update: a fan another app has set is not written.
    func update(level: Int) -> Bool {
        lock.withLock {
            if foreign { return false }
            updateLevels.append(level)
            target = FanLimits.targetRPM(level: level, min: 2317, max: 6800) ?? 0
            return verifies
        }
    }

    func verify() -> Bool { lock.withLock { verifies } }

    func restore() -> Bool {
        lock.withLock {
            restoreCount += 1
            guard restoresOK else { return false }
            mode = 0
            target = 0
            return true
        }
    }

    func heldByAnother() -> Bool { lock.withLock { foreign } }

    /// The one fan is the other app's: nothing to write.
    func yield() -> Bool {
        lock.withLock {
            yieldCount += 1
            return true
        }
    }
}

/// A controller's registers: enough of AppleSMC for discovery, reads and
/// writes, with a firmware that can be made difficult.
private final class FakeSMC: SMCKeyReading, SMCWritePort, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SMCKey] = [:]
    private var values: [String: [UInt8]] = [:]
    private var log: [String] = []
    private var readLog: [String] = []
    /// Mode 1 is accepted and does not stick.
    var rejectsManual = false
    /// Mode 1 sticks only once Ftst is 1 and the target is at maximum.
    var manualNeedsUnlock = false
    /// Writes to these names get a controller error.
    var failing: Set<String> = []

    /// `sensors` adds an M3's processor, graphics and battery keys (70, 72
    /// and 31 °C), for the watchdog's temperature reader.
    init(fanCount: Int? = 1, lowercaseMode: Bool = false, unlock: Bool = false,
         targetType: String = "flt ", minimum: Float32 = 2317, maximum: Float32 = 6800, sensors: Bool = false) {
        if let fanCount { add("FNum", "ui8 ", [UInt8(clamping: fanCount)]) }
        for index in 0..<min(fanCount ?? 0, 8) {
            add("F\(index)Ac", "flt ", Self.float(2400))
            add("F\(index)Mn", "flt ", Self.float(minimum))
            add("F\(index)Mx", "flt ", Self.float(maximum))
            add("F\(index)Tg", targetType, targetType == "flt " ? Self.float(0) : [0, 0])
            add(lowercaseMode ? "F\(index)md" : "F\(index)Md", "ui8 ", [0])
        }
        if unlock { add("Ftst", "ui8 ", [0]) }
        if sensors {
            add("Tp0g", "flt ", Self.float(70))
            add("Tg0j", "flt ", Self.float(72))
            add("TB0T", "flt ", Self.float(31))
        }
    }

    static func float(_ value: Float32) -> [UInt8] {
        let bits = value.bitPattern
        return [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
    }

    private func add(_ name: String, _ type: String, _ bytes: [UInt8]) {
        guard let code = SMCCodec.fourCC(name) else { return }
        keys[name] = SMCKey(code: code, name: name, size: UInt32(bytes.count), type: type, attributes: 0)
        values[name] = bytes
    }

    var writes: [String] { lock.withLock { log } }
    func clearWrites() { lock.withLock { log = [] } }
    /// The name of every key read, in order.
    var reads: [String] { lock.withLock { readLog } }
    func clearReads() { lock.withLock { readLog = [] } }
    func bytes(_ name: String) -> [UInt8]? { lock.withLock { values[name] } }
    func float(_ name: String) -> Double? {
        lock.withLock { values[name].flatMap { SMCCodec.decode(bytes: $0, type: "flt ") } }
    }

    /// The firmware changing a register by itself.
    func firmwareSets(_ name: String, _ bytes: [UInt8]) { lock.withLock { values[name] = bytes } }

    // SMCKeyReading
    func keyCount() -> Int { lock.withLock { keys.count } }
    func key(at index: Int) -> UInt32? {
        lock.withLock {
            let names = keys.keys.sorted()
            return names.indices.contains(index) ? keys[names[index]]?.code : nil
        }
    }
    func info(_ code: UInt32) -> SMCKey? { lock.withLock { keys[SMCCodec.fourCCString(code)] } }
    func read(_ key: SMCKey) -> [UInt8]? {
        lock.withLock {
            readLog.append(key.name)
            return values[key.name]
        }
    }

    // SMCWritePort
    func write(_ bytes: [UInt8], to key: SMCKey) -> SMCWriteOutcome {
        lock.withLock {
            let shown = key.type == "flt " ? "\(SMCCodec.decode(bytes: bytes, type: "flt ") ?? .nan)"
                                           : bytes.map(String.init).joined(separator: ",")
            log.append("\(key.name)=\(shown)")
            if failing.contains(key.name) { return .controller(0x84) }
            let isMode = key.name.hasSuffix("Md") || key.name.hasSuffix("md")
            if isMode, bytes == [1] {
                if rejectsManual { return .written }
                if manualNeedsUnlock {
                    let index = key.name.dropFirst().prefix(1)
                    let atMaximum = values["F\(index)Tg"] == values["F\(index)Mx"]
                    if values["Ftst"] != [1] || !atMaximum { return .written }
                }
            }
            values[key.name] = bytes
            return .written
        }
    }
}
