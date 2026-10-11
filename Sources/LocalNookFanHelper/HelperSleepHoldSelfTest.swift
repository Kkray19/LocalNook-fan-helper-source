//
//  HelperSleepHoldSelfTest.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  The sleep hold's part of `LocalNookFanHelper --self-test`.
//
//  Nothing here runs pmset or asks the Mac to sleep. The controller runs
//  against doubles — a pmset that only records what it was asked and moves
//  a pretend SleepDisabled, a registry, a power source, a temperature and a
//  sleep request that only count — with its timings shortened so a 7 s
//  lease lapses in half a second, and its record a real file in the
//  temporary directory, checked against this user's uid instead of root's.
//  The real spawn and the real sleep are only checked to refuse here: the
//  self-test is never allowed to change the Mac's sleep, and the check that
//  says so is the one asserted. The spawn's mechanics — exit codes, the
//  time limit, the fixed environment, closed descriptors, signals back to
//  their defaults — run against true, false, sleep and sh.
//

import Foundation
import LocalNookSMC

extension HelperSelfTest {
    // MARK: The command and the spawn

    func testSleepHoldCommand() {
        print("\nThe sleep hold: its one command, and the spawn")
        check("exactly two argument lists: pmset disablesleep 1 and 0",
              PmsetCommand.allowed == [["/usr/bin/pmset", "disablesleep", "1"], ["/usr/bin/pmset", "disablesleep", "0"]])
        check("…built from a Bool, so no caller can form another",
              PmsetCommand.arguments(disableSleep: true) == ["/usr/bin/pmset", "disablesleep", "1"]
                  && PmsetCommand.arguments(disableSleep: false) == ["/usr/bin/pmset", "disablesleep", "0"])
        let refused: [[String]] = [
            ["/usr/bin/pmset", "disablesleep", "2"], ["/usr/bin/pmset", "sleepnow"],
            ["/usr/bin/pmset", "-a", "disablesleep", "1"], ["pmset", "disablesleep", "1"],
            ["/usr/bin/pmset", "disablesleep", "1", "0"], ["/usr/bin/pmset", "disablesleep"],
            ["/bin/sh", "-c", "/usr/bin/pmset disablesleep 0"], ["/usr/bin/pmset", "DisableSleep", "1"],
            ["/usr/bin/../bin/pmset", "disablesleep", "1"], ["/usr/bin/pmset ", "disablesleep", "1"],
            ["/usr/bin/pmset", "-g"], ["/usr/bin/pmset", "disablesleep", "true"], [],
        ]
        for argv in refused {
            check("the spawn's allowlist refuses \(argv.isEmpty ? "an empty list" : argv.joined(separator: " "))",
                  !PmsetCommand.permits(argv)
                      && !HelperSpawn.permits(argv, environment: PmsetCommand.environment, selfTest: false))
        }
        check("pmset gets PATH and nothing else of the helper's environment",
              PmsetCommand.environment == ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
        check("the spawn itself — not only its one caller — starts nothing but the two lists outside the self-test",
              HelperSpawn.permits(PmsetCommand.arguments(disableSleep: true), environment: PmsetCommand.environment,
                                  selfTest: false)
                  && HelperSpawn.permits(PmsetCommand.arguments(disableSleep: false),
                                         environment: PmsetCommand.environment, selfTest: false)
                  && !HelperSpawn.permits(["/usr/bin/true"], environment: PmsetCommand.environment, selfTest: false))
        check("…and with PATH alone: pmset with any other environment is refused there",
              !HelperSpawn.permits(PmsetCommand.arguments(disableSleep: false),
                                   environment: PmsetCommand.environment + ["HOME=/var/root"], selfTest: false)
                  && !HelperSpawn.permits(PmsetCommand.arguments(disableSleep: true), environment: [], selfTest: false))
        check("…the self-test alone may drive its mechanics with harmless programs, as below",
              HelperSpawn.permits(["/usr/bin/true"], environment: PmsetCommand.environment, selfTest: true))
        check("…and five seconds", PmsetCommand.timeout == 5)
        check("this self-test may not change the Mac's sleep: the real pmset and sleep refuse here",
              HelperProcess.isSelfTest && !HelperProcess.mayChangeSystem)

        check("waitpid's word: a clean exit, a failing one, a signal",
              SpawnOutcome.from(waitStatus: 0) == .exited(0) && SpawnOutcome.from(waitStatus: 0x100) == .exited(1)
                  && SpawnOutcome.from(waitStatus: 9) == .signaled(9)
                  && SpawnOutcome.from(waitStatus: 15) == .signaled(15))
        check("only a clean exit counts as done",
              SpawnOutcome.exited(0).succeeded && !SpawnOutcome.exited(1).succeeded
                  && !SpawnOutcome.timedOut.succeeded && !SpawnOutcome.refused.succeeded)

        // The mechanics, against programs that do nothing.
        let environment = PmsetCommand.environment
        check("a program that succeeds reads as exited 0",
              HelperSpawn.run(["/usr/bin/true"], environment: environment, timeout: 5) == .exited(0))
        check("one that fails reads as its code",
              HelperSpawn.run(["/usr/bin/false"], environment: environment, timeout: 5) == .exited(1))
        check("a program that is not there is a failed spawn",
              HelperSpawn.run(["/nonexistent/pmset"], environment: environment, timeout: 5) == .failed(ENOENT))
        let started = Date()
        let slow = HelperSpawn.run(["/bin/sleep", "30"], environment: environment, timeout: 0.3)
        check("one still running at the limit is killed, and said to be",
              slow == .timedOut && Date().timeIntervalSince(started) < 3,
              "\(slow) after \(Date().timeIntervalSince(started)) s")
        check("the child sees PATH alone: no HOME, no USER",
              HelperSpawn.run(["/bin/sh", "-c",
                               "[ \"$PATH\" = /usr/bin:/bin:/usr/sbin:/sbin ] && [ -z \"$HOME\" ] && [ -z \"$USER\" ]"],
                              environment: environment, timeout: 5) == .exited(0))
        let file = directory.appendingPathComponent("open-descriptor").path
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        let opened = open(file, O_RDONLY)
        let inherited: Int32 = 37
        if opened >= 0, dup2(opened, inherited) == inherited {
            check("a descriptor the helper has open does not reach the child",
                  HelperSpawn.run(["/bin/sh", "-c", "[ ! -e /dev/fd/\(inherited) ]"], environment: environment,
                                  timeout: 5) == .exited(0))
            close(inherited)
        } else {
            check("a descriptor to test with", false)
        }
        if opened >= 0 { close(opened) }
        // The daemon ignores SIGTERM; a child must not.
        signal(SIGTERM, SIG_IGN)
        let terminated = HelperSpawn.run(["/bin/sh", "-c", "kill -TERM $$; sleep 2"], environment: environment,
                                         timeout: 5)
        signal(SIGTERM, SIG_DFL)
        check("a signal the helper ignores is back to its default in the child", terminated == .signaled(SIGTERM),
              "\(terminated)")
    }

    // MARK: Policy

    func testSleepHoldPolicy() {
        print("\nThe sleep hold: when it ends, and when the Mac then sleeps")
        let ac = PowerSourceReading(onAC: true, batteryPercent: 80, lowPowerMode: false)
        func battery(_ percent: Int?, lowPower: Bool = false) -> PowerSourceReading {
            PowerSourceReading(onAC: false, batteryPercent: percent, lowPowerMode: lowPower)
        }
        func reason(age: TimeInterval = 1, disabled: Bool? = true, unreadable: Int = 0,
                    thermal: ProcessInfo.ThermalState = .nominal, hot: TimeInterval? = nil, sensors: Int = 0,
                    power: PowerSourceReading = ac, battery allowsBattery: Bool = false,
                    held: TimeInterval = 60) -> SleepHoldEndReason? {
            SleepHoldPolicy.endReason(.init(
                heartbeatAge: age, lease: SleepHoldLimits.lease, sleepDisabled: disabled,
                unreadableReads: unreadable, thermalState: thermal, hotFor: hot,
                tooHotAfter: FanLimits.tooHotSeconds, sensorFailures: sensors, power: power,
                allowsBattery: allowsBattery, heldFor: held, ceiling: SleepHoldLimits.ceiling))
        }
        check("the limits: a 2 s heartbeat, a 7 s lease, 12 hours, 20%",
              SleepHoldLimits.heartbeat == 2 && SleepHoldLimits.lease == 7
                  && SleepHoldLimits.ceiling == 12 * 3600 && SleepHoldLimits.batteryFloor == 20)
        check("…and the controller's own timings are those, and the fans' heat line",
              SleepHoldController.Timing.standard.lease == SleepHoldLimits.lease
                  && SleepHoldController.Timing.standard.ceiling == SleepHoldLimits.ceiling
                  && SleepHoldController.Timing.standard.tooHotAfter == FanLimits.tooHotSeconds
                  && SleepHoldController.Timing.standard.watchdog == 1)
        check("a healthy hold goes on", reason() == nil)
        check("7 s is still within the lease; past it the app is gone",
              reason(age: 7) == nil && reason(age: 7.01) == .appGone)
        check("SleepDisabled reading 0 is someone else clearing it: taken over, before anything else",
              reason(age: 60, disabled: false) == .takenOver)
        check("unreadable three times running ends it; twice does not",
              reason(disabled: nil, unreadable: 2) == nil && reason(disabled: nil, unreadable: 3) == .unverifiable)
        check("serious or critical thermal pressure ends it; fair does not",
              reason(thermal: .serious) == .thermalPressure && reason(thermal: .critical) == .thermalPressure
                  && reason(thermal: .fair) == nil)
        check("95 °C for 5 s ends it — at any fan speed: nothing else will",
              reason(hot: 4.9) == nil && reason(hot: 5) == .tooHot)
        check("three readings with no temperature end it", reason(sensors: 2) == nil && reason(sensors: 3) == .sensorsLost)
        check("twelve hours end it, whatever the session says",
              reason(held: 12 * 3600 - 1) == nil && reason(held: 12 * 3600) == .ceiling)
        check("on battery without the opt-in: it ends",
              reason(power: battery(90)) == .onBattery)
        check("with the opt-in: on above 20%, ended at 20% or below, or with the charge unknown",
              reason(power: battery(21), battery: true) == nil && reason(power: battery(20), battery: true) == .batteryLow
                  && reason(power: battery(4), battery: true) == .batteryLow
                  && reason(power: battery(nil), battery: true) == .batteryLow)
        check("…and in Low Power Mode", reason(power: battery(80, lowPower: true), battery: true) == .lowPowerMode)
        func adapter(_ percent: Int?, charging: Bool) -> PowerSourceReading {
            PowerSourceReading(onAC: true, batteryPercent: percent, lowPowerMode: true, charging: charging)
        }
        check("on the adapter Low Power Mode does not matter, nor the charge while the battery charges",
              SleepHoldPolicy.powerReason(adapter(5, charging: true), allowsBattery: false) == nil
                  && SleepHoldPolicy.powerReason(adapter(80, charging: false), allowsBattery: false) == nil
                  && SleepHoldPolicy.powerReason(adapter(21, charging: false), allowsBattery: false) == nil)
        check("…but an adapter too weak for the load — the battery at 20% and not charging — ends it, battery or not",
              SleepHoldPolicy.powerReason(adapter(20, charging: false), allowsBattery: false) == .batteryLow
                  && SleepHoldPolicy.powerReason(adapter(15, charging: false), allowsBattery: true) == .batteryLow
                  && reason(power: adapter(15, charging: false)) == .batteryLow)
        check("…and on the adapter with no battery reading, nothing to go by: it goes on",
              SleepHoldPolicy.powerReason(adapter(nil, charging: false), allowsBattery: false) == nil)
        check("a power source that cannot be read counts as a battery whose charge is not known",
              SleepHoldPolicy.powerReason(PowerSourceReading(onAC: false, batteryPercent: nil, lowPowerMode: false),
                                          allowsBattery: false) == .onBattery
                  && SleepHoldPolicy.powerReason(PowerSourceReading(onAC: false, batteryPercent: nil,
                                                                    lowPowerMode: false),
                                                 allowsBattery: true) == .batteryLow)

        let closed = LidReading(closed: true, causesSleep: true)
        let clamshell = LidReading(closed: true, causesSleep: false)
        let open = LidReading(closed: false, causesSleep: true)
        check("ended with the lid closed, the Mac is put to sleep: the kernel will not look again",
              SleepHoldPolicy.sleepsAfterEnd(.sessionEnded, lid: closed)
                  && SleepHoldPolicy.sleepsAfterEnd(.appGone, lid: closed)
                  && SleepHoldPolicy.sleepsAfterEnd(.batteryLow, lid: closed)
                  && SleepHoldPolicy.sleepsAfterEnd(.helperRestarted, lid: closed))
        check("…but not in clamshell mode, running a display, where the kernel itself would not",
              !SleepHoldPolicy.sleepsAfterEnd(.sessionEnded, lid: clamshell))
        check("…nor with the lid open — the person switching it off at an open lid above all",
              !SleepHoldPolicy.sleepsAfterEnd(.switchedOff, lid: open)
                  && !SleepHoldPolicy.sleepsAfterEnd(.sessionEnded, lid: open))
        check("…nor on a Mac whose lid cannot be read", !SleepHoldPolicy.sleepsAfterEnd(.sessionEnded, lid: nil))
        check("Sleep now sleeps with the lid open; a sleep already on its way asks for none",
              SleepHoldPolicy.sleepsAfterEnd(.sleepNow, lid: open) && !SleepHoldPolicy.sleepsAfterEnd(.sleep, lid: closed))
        check("a refused start says why in the start's own terms",
              SleepHoldPolicy.refusal(for: .onBattery) == .onBattery
                  && SleepHoldPolicy.refusal(for: .batteryLow) == .batteryLow
                  && SleepHoldPolicy.refusal(for: .lowPowerMode) == .lowPowerMode
                  && SleepHoldPolicy.refusal(for: .sensorsLost) == .noTemperatures)
        check("a request is refused before decoding when over the cap",
              SleepHoldRequest.decode(Data(repeating: 0x20, count: FanHelperIdentity.maxPayloadBytes + 1)) == nil)
    }

    // MARK: The record

    func testSleepHoldRecord() {
        print("\nThe sleep hold's record (this user's uid standing in for root)")
        let base = directory.appendingPathComponent("record", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func record(_ name: String) -> (SleepHoldRecordFile, String) {
            let path = base.appendingPathComponent(name).path
            return (SleepHoldRecordFile(path: path, ownerUID: getuid()), path)
        }
        let (plain, path) = record("plain")
        check("none at first", !plain.exists())
        check("created where none is", plain.create() && plain.exists())
        check("private to its owner, and saying what it is",
              (((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1) == 0o600
                  && (try? String(contentsOfFile: path, encoding: .utf8)) == SleepHoldRecordFile.contents)
        check("a second cannot be created over it", !plain.create())
        check("removed, and gone", plain.remove() && !plain.exists() && !FileManager.default.fileExists(atPath: path))
        check("removing none is not a failure", plain.remove())

        let (loose, loosePath) = record("loose")
        FileManager.default.createFile(atPath: loosePath, contents: Data("v1\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        check("a record others can read is not trusted as LocalNook's", !loose.exists())
        check("…nor removed as LocalNook's", !loose.remove() && FileManager.default.fileExists(atPath: loosePath))

        let (linked, linkedPath) = record("linked")
        let elsewhere = base.appendingPathComponent("elsewhere").path
        FileManager.default.createFile(atPath: elsewhere, contents: nil, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.createSymbolicLink(atPath: linkedPath, withDestinationPath: elsewhere)
        check("a link at the path is not a record, and none is created through it",
              !linked.exists() && !linked.create()
                  && (try? Data(contentsOf: URL(fileURLWithPath: elsewhere)))?.isEmpty == true)
        let (doubled, doubledPath) = record("doubled")
        _ = doubled.create()
        _ = link(doubledPath, base.appendingPathComponent("second-name").path)
        check("a record with a second name is not trusted", !doubled.exists())

        // Owned by anyone but the one it must be (root, in the helper): a
        // file this user made, judged as root's record would be.
        let othersPath = base.appendingPathComponent("others").path
        FileManager.default.createFile(atPath: othersPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let notTheOwners = SleepHoldRecordFile(path: othersPath, ownerUID: getuid() &+ 1)
        check("a private, plain record owned by someone else is not trusted, nor removed",
              !notTheOwners.exists() && !notTheOwners.remove() && FileManager.default.fileExists(atPath: othersPath))
        let (flushed, _) = record("flushed")
        check("a record is flushed to the disk, its folder too, and still made", flushed.create() && flushed.exists()
                  && flushed.remove())
    }

    // MARK: The controller

    struct SleepHoldRig {
        let controller: SleepHoldController
        let pmset: FakePmset
        let registry: FakeRegistry
        let power: FakePower
        let temperature: FakeTemperature
        let sleeper: FakeSleeper
        let recordPath: String
        let idle: Flag
        let thermal: ThermalBox
    }

    static let quickHold = SleepHoldController.Timing(
        lease: 0.5, watchdog: 0.05, tooHotAfter: 0.2, ceiling: 3600, readBack: 0.3, readBackGap: 0.01,
        retryGap: 0.1, shutdownRetry: 0.5, sleepAttempts: 3, sleepGap: 0.01, idleExit: 0.2)

    func sleepHoldRig(_ name: String, timing: SleepHoldController.Timing = HelperSelfTest.quickHold)
        -> SleepHoldRig {
        let base = directory.appendingPathComponent("hold-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let recordPath = base.appendingPathComponent("sleep-hold").path
        let registry = FakeRegistry()
        let pmset = FakePmset(registry: registry, recordPath: recordPath)
        let power = FakePower()
        let temperature = FakeTemperature()
        let sleeper = FakeSleeper()
        let idle = Flag()
        let thermal = ThermalBox()
        let controller = SleepHoldController(
            pmset: pmset, registry: registry, power: power, temperature: temperature, sleeper: sleeper,
            record: SleepHoldRecordFile(path: recordPath, ownerUID: getuid()), timing: timing,
            thermalState: { thermal.state }, onIdle: { idle.set() })
        return SleepHoldRig(controller: controller, pmset: pmset, registry: registry, power: power,
                            temperature: temperature, sleeper: sleeper, recordPath: recordPath, idle: idle,
                            thermal: thermal)
    }

    private func ask(_ rig: SleepHoldRig, _ action: SleepHoldAction, as id: UUID) -> SleepHoldStatus? {
        let data = FanWire.encode(SleepHoldRequest(action: action)) ?? Data()
        return wait { rig.controller.handle(data, for: id, reply: $0) }
    }

    /// Lets an asynchronous sleep request arrive, if one is coming.
    private func settle() { Thread.sleep(forTimeInterval: 0.08) }

    func testSleepHoldController() {
        print("\nThe sleep hold's controller, against doubles")
        let a = UUID(), b = UUID()
        func recordExists(_ rig: SleepHoldRig) -> Bool { FileManager.default.fileExists(atPath: rig.recordPath) }

        // Status, and holding on the adapter.
        let main = sleepHoldRig("main")
        main.controller.connectionOpened(a)
        main.controller.connectionOpened(b)
        let idle = ask(main, .status, as: a)
        check("idle: nobody holds it, at this revision", idle?.owner == .nobody && idle?.revision == 3
                  && idle?.sleepDisabled == false && idle?.recovering == false)
        let held = ask(main, .start(allowBattery: false), as: a)
        check("a start on the adapter holds it for this connection",
              held?.isHolding == true && held?.error == nil && held?.sleepDisabled == true,
              "\(String(describing: held))")
        check("…saying it is not allowed on battery, and held for no time yet",
              held?.allowsBattery == false && (held?.heldSeconds ?? -1) >= 0 && (held?.heldSeconds ?? 9) < 1)
        check("…by pmset disablesleep 1, once", main.pmset.calls == [true])
        check("…with the record written before pmset ran", main.pmset.recordExistedAtCalls == [true])
        check("…and SleepDisabled read back from the kernel, through the time powerd takes",
              main.registry.readsWhileLagging > 0)
        let other = ask(main, .start(allowBattery: false), as: b)
        check("another LocalNook connection is told it is held elsewhere, and nothing more runs",
              other?.error == .localNookOtherConnection && other?.owner == .localNookOtherConnection
                  && main.pmset.calls == [true])
        let notMine = ask(main, .release(.sessionEnded), as: b)
        check("…and cannot release it", notMine?.owner == .localNookOtherConnection
                  && main.controller.snapshot().isHolding)
        var lastBeat: SleepHoldStatus?
        for _ in 0..<8 {
            lastBeat = ask(main, .heartbeat, as: a)
            Thread.sleep(forTimeInterval: 0.1)
        }
        check("heartbeats keep it past the lease", main.controller.snapshot().isHolding)
        check("…and each answer says how long it has been held", (lastBeat?.heldSeconds ?? 0) >= 0.5,
              "\(String(describing: lastBeat?.heldSeconds))")
        check("the lease lapses without heartbeats: sleep restored, the app gone",
              waitUntil { main.controller.snapshot().lastEnd?.reason == .appGone }
                  && main.controller.snapshot().isIdle && main.pmset.calls == [true, false])
        check("…the record removed once SleepDisabled read 0", !recordExists(main) && main.registry.value == false)
        settle()
        check("…and with the lid open the Mac is not asked to sleep",
              main.sleeper.requests == 0 && main.controller.snapshot().lastEnd?.sleptMac == false)

        // A new hold, and the connection closing.
        let again = ask(main, .start(allowBattery: false), as: a)
        check("a new hold forgets how the last one ended, which would read as its own end",
              again?.isHolding == true && again?.lastEnd == nil && main.controller.snapshot().lastEnd == nil)
        main.controller.connectionClosed(a)
        check("the owner's connection closing restores sleep",
              waitUntil { main.controller.snapshot().isIdle } && main.controller.snapshot().lastEnd?.reason == .appGone)
        main.controller.connectionOpened(a)

        // With a lease that would take half a minute to lapse, so nothing
        // but the connection closing can be what lets go.
        var patient = HelperSelfTest.quickHold
        patient.lease = 30
        let closing = sleepHoldRig("closing", timing: patient)
        closing.controller.connectionOpened(a)
        closing.controller.connectionOpened(b)
        _ = ask(closing, .start(allowBattery: false), as: a)
        closing.controller.connectionClosed(b)
        Thread.sleep(forTimeInterval: 0.2)
        check("another connection closing leaves the hold alone", closing.controller.snapshot().isHolding)
        let closedAt = Date()
        closing.controller.connectionClosed(a)
        check("the owner's connection closing lets go at once, long before its 30 s lease could lapse",
              waitUntil(timeout: 2) { closing.controller.snapshot().isIdle }
                  && Date().timeIntervalSince(closedAt) < 2
                  && closing.controller.snapshot().lastEnd?.reason == .appGone && closing.pmset.calls == [true, false])

        // Heartbeats only from their owner.
        let foreignBeat = sleepHoldRig("foreign-beat")
        foreignBeat.controller.connectionOpened(a)
        foreignBeat.controller.connectionOpened(b)
        _ = ask(foreignBeat, .start(allowBattery: false), as: a)
        let lapsedAnyway = waitUntil(timeout: 3) {
            _ = self.ask(foreignBeat, .heartbeat, as: b)
            return foreignBeat.controller.snapshot().lastEnd != nil
        }
        check("another connection's heartbeats do not keep the owner's lease",
              lapsedAnyway && foreignBeat.controller.snapshot().lastEnd?.reason == .appGone)
        let renewing = sleepHoldRig("renewing")
        renewing.controller.connectionOpened(a)
        _ = ask(renewing, .start(allowBattery: false), as: a)
        Thread.sleep(forTimeInterval: 0.35)
        _ = ask(renewing, .start(allowBattery: false), as: a)
        Thread.sleep(forTimeInterval: 0.35)
        check("the owner starting again — its battery choice changed — renews the lease as a heartbeat does",
              renewing.controller.snapshot().isHolding)

        // Failed reads that are not three in a row: only the ticks read,
        // with a lease that needs no heartbeat.
        let scattered = sleepHoldRig("scattered", timing: patient)
        scattered.controller.connectionOpened(a)
        _ = ask(scattered, .start(allowBattery: false), as: a)
        scattered.temperature.everyOtherReadFails = true
        scattered.registry.everyOtherReadFails = true
        Thread.sleep(forTimeInterval: 0.6)
        check("a temperature or SleepDisabled read failing now and then, never three looks running, never ends it",
              scattered.controller.snapshot().isHolding && scattered.controller.snapshot().lastEnd == nil,
              "\(String(describing: scattered.controller.snapshot().lastEnd))")
        _ = ask(scattered, .release(.sessionEnded), as: a)

        // Releases, and sleeping afterwards.
        func released(_ name: String, lid: LidReading?, action: SleepHoldAction) -> (SleepHoldStatus?, SleepHoldRig) {
            let rig = sleepHoldRig(name)
            rig.registry.lidState = lid
            rig.controller.connectionOpened(a)
            _ = ask(rig, .start(allowBattery: false), as: a)
            let answer = ask(rig, action, as: a)
            settle()
            return (answer, rig)
        }
        let (endedShut, shut) = released("shut", lid: LidReading(closed: true, causesSleep: true),
                                         action: .release(.sessionEnded))
        check("the session ending with the lid closed: sleep restored, then the Mac asked to sleep",
              endedShut?.lastEnd == SleepHoldEnd(reason: .sessionEnded, sleptMac: true) && shut.sleeper.requests == 1
                  && shut.pmset.calls == [true, false], "\(String(describing: endedShut))")
        let (endedClamshell, clamshell) = released("clamshell", lid: LidReading(closed: true, causesSleep: false),
                                                   action: .release(.sessionEnded))
        check("…but not in clamshell mode with a display: the kernel itself would not",
              endedClamshell?.lastEnd?.sleptMac == false && clamshell.sleeper.requests == 0)
        let (endedOff, off) = released("off", lid: LidReading(closed: false, causesSleep: true),
                                       action: .release(.switchedOff))
        check("switched off at an open lid: sleep restored, the Mac left awake",
              endedOff?.lastEnd == SleepHoldEnd(reason: .switchedOff, sleptMac: false) && off.sleeper.requests == 0)
        let (endedNow, now) = released("now", lid: LidReading(closed: false, causesSleep: true), action: .sleepNow)
        check("Sleep now: sleep restored, then the Mac asked to sleep with its lid open",
              endedNow?.lastEnd == SleepHoldEnd(reason: .sleepNow, sleptMac: true) && now.sleeper.requests == 1
                  && now.pmset.calls == [true, false])
        let reluctant = sleepHoldRig("reluctant")
        reluctant.sleeper.refuseFirst = 2
        reluctant.controller.connectionOpened(a)
        _ = ask(reluctant, .start(allowBattery: false), as: a)
        _ = ask(reluctant, .sleepNow, as: a)
        check("a sleep the kernel refuses at first — the setting just cleared — is asked again, three times at most",
              waitUntil { reluctant.sleeper.attempts == 3 } && reluctant.sleeper.requests == 1)
        let unheld = sleepHoldRig("unheld")
        unheld.controller.connectionOpened(a)
        _ = ask(unheld, .sleepNow, as: a)
        check("Sleep now with nothing held still sleeps, and writes nothing",
              waitUntil { unheld.sleeper.requests == 1 } && unheld.pmset.calls.isEmpty)
        let blocked = sleepHoldRig("blocked")
        blocked.registry.value = true
        blocked.controller.connectionOpened(a)
        let refusedSleep = ask(blocked, .sleepNow, as: a)
        settle()
        check("…unless another app has sleep disabled: then nothing is asked",
              refusedSleep?.error == .otherAppHolds && blocked.sleeper.requests == 0 && blocked.pmset.calls.isEmpty)

        // Never someone else's.
        let vorssaint = sleepHoldRig("vorssaint")
        vorssaint.registry.value = true
        vorssaint.controller.connectionOpened(a)
        let theirs = ask(vorssaint, .start(allowBattery: false), as: a)
        check("SleepDisabled already 1: refused as another app's, nothing run, no record",
              theirs?.error == .otherAppHolds && vorssaint.pmset.calls.isEmpty && !recordExists(vorssaint)
                  && vorssaint.controller.snapshot().isIdle)
        _ = ask(vorssaint, .release(.sessionEnded), as: a)
        check("…and a release with nothing held writes no 0 over it",
              vorssaint.pmset.calls.isEmpty && vorssaint.registry.value == true)
        let pendingBoot = sleepHoldRig("stored-only")
        pendingBoot.registry.kernelSetting = .off
        pendingBoot.registry.storedSetting = .on
        pendingBoot.controller.connectionOpened(a)
        let storedOnly = ask(pendingBoot, .start(allowBattery: false), as: a)
        check("a 1 stored but not yet in force — another app's, before powerd re-applies it — is refused just the same",
              storedOnly?.error == .otherAppHolds && pendingBoot.pmset.calls.isEmpty && !recordExists(pendingBoot))
        let fresh = sleepHoldRig("never-set")
        fresh.registry.kernelSetting = .absent
        fresh.registry.storedSetting = .absent
        fresh.controller.connectionOpened(a)
        let firstEver = ask(fresh, .start(allowBattery: false), as: a)
        check("a Mac where no system power setting was ever made — neither place has one — can hold",
              firstEver?.isHolding == true && fresh.pmset.calls == [true])
        _ = ask(fresh, .release(.sessionEnded), as: a)
        check("…and lets go once both read 0", fresh.controller.snapshot().isIdle && !recordExists(fresh)
                  && fresh.registry.storedSetting == .off)
        let unreadable = sleepHoldRig("unreadable")
        unreadable.registry.readable = false
        unreadable.controller.connectionOpened(a)
        let blind = ask(unreadable, .start(allowBattery: false), as: a)
        check("SleepDisabled unreadable: refused, nothing run", blind?.error == .controlFailed
                  && unreadable.pmset.calls.isEmpty && !recordExists(unreadable))

        let taken = sleepHoldRig("taken")
        taken.registry.lidState = LidReading(closed: true, causesSleep: true)
        taken.controller.connectionOpened(a)
        _ = ask(taken, .start(allowBattery: false), as: a)
        taken.registry.value = false   // someone ran pmset disablesleep 0
        let lost = waitUntil(timeout: 3) {
            _ = self.ask(taken, .heartbeat, as: a)
            return taken.controller.snapshot().lastEnd != nil
        }
        check("SleepDisabled read 0 while held: ended as taken over",
              lost && taken.controller.snapshot().lastEnd?.reason == .takenOver && taken.controller.snapshot().isIdle)
        Thread.sleep(forTimeInterval: 0.3)
        check("…writing nothing — no 0 over a 0, never a 1 again — and the record gone",
              taken.pmset.calls == [true] && taken.registry.value == false && !recordExists(taken))
        check("…and, its lid closed, the Mac asked to sleep, which the kernel would not do by itself",
              taken.sleeper.requests == 1)

        // Guards before anything is written.
        func refusal(_ name: String, allowBattery: Bool = false, _ setUp: (SleepHoldRig) -> Void) -> SleepHoldError? {
            let rig = sleepHoldRig(name)
            setUp(rig)
            rig.controller.connectionOpened(a)
            let answer = ask(rig, .start(allowBattery: allowBattery), as: a)
            let wroteNothing = rig.pmset.calls.isEmpty && !recordExists(rig) && rig.controller.snapshot().isIdle
            return wroteNothing ? answer?.error : .invalidRequest
        }
        let onBattery = PowerSourceReading(onAC: false, batteryPercent: 80, lowPowerMode: false)
        check("on battery without the opt-in: refused before anything is written",
              refusal("battery") { $0.power.reading = onBattery } == .onBattery)
        check("on battery with it at 20%: refused",
              refusal("low", allowBattery: true) {
                  $0.power.reading = PowerSourceReading(onAC: false, batteryPercent: 20, lowPowerMode: false)
              } == .batteryLow)
        check("in Low Power Mode with the opt-in: refused",
              refusal("lowpower", allowBattery: true) {
                  $0.power.reading = PowerSourceReading(onAC: false, batteryPercent: 80, lowPowerMode: true)
              } == .lowPowerMode)
        check("under serious thermal pressure: refused", refusal("pressure") { $0.thermal.state = .serious } == .thermalPressure)
        check("with no temperature to watch: refused", refusal("blind") { $0.temperature.value = nil } == .noTemperatures)
        check("at 95 °C: refused", refusal("hot") { $0.temperature.value = 95 } == .tooHot)
        let batteryOK = sleepHoldRig("battery-ok")
        batteryOK.power.reading = onBattery
        batteryOK.controller.connectionOpened(a)
        let onBatteryHeld = ask(batteryOK, .start(allowBattery: true), as: a)
        check("on battery with the opt-in, above 20%: held, and said to allow it",
              onBatteryHeld?.isHolding == true && onBatteryHeld?.allowsBattery == true)
        let withdrawn = ask(batteryOK, .start(allowBattery: false), as: a)
        check("the opt-in withdrawn while on battery ends it at once",
              withdrawn?.error == .onBattery && withdrawn?.lastEnd?.reason == .onBattery
                  && batteryOK.controller.snapshot().isIdle && batteryOK.pmset.calls == [true, false])

        // Guards while holding.
        func scenario(_ name: String, allowBattery: Bool = false, timing: SleepHoldController.Timing = HelperSelfTest.quickHold,
                      _ change: (SleepHoldRig) -> Void, expect: SleepHoldEndReason) {
            let rig = sleepHoldRig(name, timing: timing)
            rig.registry.lidState = LidReading(closed: true, causesSleep: true)
            if allowBattery { rig.power.reading = onBattery }
            rig.controller.connectionOpened(a)
            _ = ask(rig, .start(allowBattery: allowBattery), as: a)
            change(rig)
            let ended = waitUntil(timeout: 3) {
                _ = self.ask(rig, .heartbeat, as: a)
                return rig.controller.snapshot().lastEnd != nil
            }
            let last = rig.controller.snapshot().lastEnd
            settle()
            check("\(name): sleep restored as \(expect.rawValue), and the closed Mac put to sleep",
                  ended && last?.reason == expect && last?.sleptMac == true && rig.sleeper.requests == 1
                      && rig.pmset.calls == [true, false] && !recordExists(rig),
                  "got \(String(describing: last)), calls \(rig.pmset.calls)")
        }
        scenario("unplugged without the opt-in", { $0.power.reading = onBattery }, expect: .onBattery)
        scenario("a weak adapter running the battery down to 20%", {
            $0.power.reading = PowerSourceReading(onAC: true, batteryPercent: 20, lowPowerMode: false, charging: false)
        }, expect: .batteryLow)
        scenario("the battery falling to 20%", allowBattery: true, {
            $0.power.reading = PowerSourceReading(onAC: false, batteryPercent: 20, lowPowerMode: false)
        }, expect: .batteryLow)
        scenario("Low Power Mode switched on", allowBattery: true, {
            $0.power.reading = PowerSourceReading(onAC: false, batteryPercent: 70, lowPowerMode: true)
        }, expect: .lowPowerMode)
        scenario("serious thermal pressure", { $0.thermal.state = .serious }, expect: .thermalPressure)
        scenario("95 °C held", { $0.temperature.value = 96 }, expect: .tooHot)
        scenario("the temperature lost", { $0.temperature.value = nil }, expect: .sensorsLost)
        var short = HelperSelfTest.quickHold
        short.ceiling = 0.4
        scenario("the 12-hour ceiling (shortened)", timing: short, { _ in }, expect: .ceiling)
        let briefly = sleepHoldRig("briefly")
        briefly.controller.connectionOpened(a)
        _ = ask(briefly, .start(allowBattery: false), as: a)
        briefly.temperature.value = 96
        Thread.sleep(forTimeInterval: 0.1)
        briefly.temperature.value = 70
        for _ in 0..<6 {
            _ = ask(briefly, .heartbeat, as: a)
            Thread.sleep(forTimeInterval: 0.05)
        }
        check("heat under the 5 s (here 0.2 s) does not end it", briefly.controller.snapshot().isHolding)
        let blindfold = sleepHoldRig("blindfold")
        blindfold.registry.lidState = LidReading(closed: true, causesSleep: true)
        blindfold.controller.connectionOpened(a)
        _ = ask(blindfold, .start(allowBattery: false), as: a)
        blindfold.registry.readable = false
        let gaveIn = waitUntil(timeout: 3) {
            _ = self.ask(blindfold, .heartbeat, as: a)
            return blindfold.controller.snapshot().isRecovering
        }
        check("SleepDisabled unreadable three times: it lets go — and, unable to read the 0 back, keeps retrying",
              gaveIn && recordExists(blindfold) && blindfold.sleeper.requests == 0)
        blindfold.registry.readable = true
        check("…until it reads 0: then the record goes, the end said as unverifiable, the closed Mac put to sleep",
              waitUntil { blindfold.controller.snapshot().isIdle } && !recordExists(blindfold)
                  && blindfold.controller.snapshot().lastEnd?.reason == .unverifiable
                  && waitUntil { blindfold.sleeper.requests == 1 }
                  && !blindfold.pmset.calls.dropFirst().contains(true))

        // Starts that do not take.
        let failing = sleepHoldRig("failing")
        failing.pmset.failSet = true
        failing.controller.connectionOpened(a)
        let failed = ask(failing, .start(allowBattery: false), as: a)
        check("pmset failing to set it: refused, then undone with pmset 0 and the record removed",
              failed?.error == .controlFailed && failing.pmset.calls == [true, false] && !recordExists(failing)
                  && failing.controller.snapshot().isIdle && failing.controller.snapshot().lastEnd == nil)
        let stuckOn = sleepHoldRig("stuck-read")
        stuckOn.registry.frozen = true
        stuckOn.controller.connectionOpened(a)
        let unconfirmed = ask(stuckOn, .start(allowBattery: false), as: a)
        check("pmset succeeding but the kernel never reading 1: refused, and undone",
              unconfirmed?.error == .controlFailed && stuckOn.pmset.calls == [true, false] && !recordExists(stuckOn))
        settle()
        check("…with no sleep asked for: nothing ended", stuckOn.sleeper.requests == 0)

        // A release that does not confirm.
        let wedged = sleepHoldRig("wedged")
        wedged.controller.connectionOpened(a)
        _ = ask(wedged, .start(allowBattery: false), as: a)
        wedged.pmset.failClear = true
        let wedgedRelease = ask(wedged, .release(.sessionEnded), as: a)
        check("a release pmset cannot make: the helper keeps the record and says it is retrying",
              wedgedRelease?.recovering == true && recordExists(wedged) && wedged.controller.snapshot().isRecovering
                  && wedged.registry.value == true)
        let duringRecovery = ask(wedged, .start(allowBattery: false), as: a)
        check("…no new hold while it is", duringRecovery?.error == .controlFailed && wedged.pmset.calls.filter { $0 }.count == 1)
        wedged.pmset.failClear = false
        check("…and once pmset works, the retry restores sleep and removes the record, with the first reason",
              waitUntil { wedged.controller.snapshot().isIdle } && !recordExists(wedged)
                  && wedged.controller.snapshot().lastEnd?.reason == .sessionEnded && wedged.registry.value == false)
        let late = sleepHoldRig("late")
        late.registry.lidState = LidReading(closed: false, causesSleep: true)
        late.controller.connectionOpened(a)
        _ = ask(late, .start(allowBattery: false), as: a)
        late.pmset.failClear = true
        _ = ask(late, .sleepNow, as: a)
        late.pmset.failClear = false
        _ = waitUntil { late.controller.snapshot().isIdle }
        settle()
        check("a Sleep now that only confirms on a retry sleeps by the lid's rule, not at once",
              late.controller.snapshot().lastEnd?.reason == .sleepNow && late.sleeper.requests == 0)
        let undoing = sleepHoldRig("undoing")
        undoing.registry.lidState = LidReading(closed: true, causesSleep: true)
        undoing.pmset.failSet = true
        undoing.pmset.failClear = true
        undoing.controller.connectionOpened(a)
        let notTaken = ask(undoing, .start(allowBattery: false), as: a)
        check("a start that failed, and whose undo did not confirm either: refused, and retried with the record kept",
              notTaken?.error == .controlFailed && undoing.controller.snapshot().isRecovering && recordExists(undoing))
        undoing.pmset.failClear = false
        _ = waitUntil { undoing.controller.snapshot().isIdle }
        settle()
        check("…once the undo confirms on a retry, no end is reported and the closed Mac is not put to sleep: "
                  + "no hold ever took", undoing.controller.snapshot().isIdle && !recordExists(undoing)
                  && undoing.controller.snapshot().lastEnd == nil && undoing.sleeper.requests == 0)

        // Another app's 1 landing just behind this helper's 0. No watchdog
        // look in between, so the only reads are the release's own.
        var unwatched = HelperSelfTest.quickHold
        unwatched.lease = 30
        unwatched.watchdog = 30
        let overtaken = sleepHoldRig("overtaken", timing: unwatched)
        overtaken.controller.connectionOpened(a)
        _ = ask(overtaken, .start(allowBattery: false), as: a)
        overtaken.registry.storedBecomes(.on, afterKernelReads: 1)
        _ = ask(overtaken, .release(.sessionEnded), as: a)
        Thread.sleep(forTimeInterval: 0.4)
        check("a release whose 0 was seen in both places counts, though another app's 1 lands just after: "
                  + "that 1 is never cleared by a retry",
              overtaken.controller.snapshot().isIdle && !recordExists(overtaken)
                  && overtaken.pmset.calls == [true, false] && overtaken.registry.storedSetting == .on,
              "calls \(overtaken.pmset.calls), stored \(overtaken.registry.storedSetting)")

        // A helper that died holding, or a Mac that went down holding.
        let reboot = sleepHoldRig("reboot")
        reboot.registry.lidState = LidReading(closed: true, causesSleep: true)
        FileManager.default.createFile(atPath: reboot.recordPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        // Early in a boot: powerd has not started, so the kernel has no
        // SleepDisabled at all, while the stored 1 waits to be re-applied.
        reboot.registry.powerdRunning = false
        reboot.registry.kernelSetting = .absent
        reboot.registry.storedSetting = .on
        check("at launch, a record means pmset 0 first — with the kernel reading nothing yet",
              !reboot.controller.recoverAtLaunch() && reboot.pmset.calls.first == false
                  && !reboot.pmset.calls.contains(true))
        check("…and nothing read back from the kernel is not a 0: the record kept, the helper retrying",
              recordExists(reboot) && reboot.controller.snapshot().isRecovering
                  && reboot.registry.storedSetting == .off && reboot.sleeper.requests == 0)
        check("…the helper staying up meanwhile", !reboot.idle.isSet && !reboot.controller.isIdle)
        reboot.registry.powerdRunning = true
        check("once powerd publishes the 0, the record is removed, reported as a restart",
              waitUntil { reboot.controller.snapshot().isIdle } && !recordExists(reboot)
                  && reboot.controller.snapshot().lastEnd?.reason == .helperRestarted)
        settle()
        check("…the closed Mac asked to sleep", reboot.sleeper.requests == 1)
        check("…and with nobody connected the helper then exits", waitUntil { reboot.idle.isSet })
        let silent = sleepHoldRig("silent")
        FileManager.default.createFile(atPath: silent.recordPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        silent.registry.value = true
        // pmset exiting 0 with its write failed ("failed to set the value").
        silent.registry.frozen = true
        check("a pmset 0 that exits 0 but changes nothing is not a release: the record kept, retried",
              !silent.controller.recoverAtLaunch() && recordExists(silent) && silent.controller.snapshot().isRecovering)
        silent.registry.frozen = false
        check("…until a write takes, and both places read 0",
              waitUntil { silent.controller.snapshot().isIdle } && !recordExists(silent)
                  && silent.registry.storedSetting == .off && silent.registry.kernelSetting == .off)
        let settled = sleepHoldRig("settled")
        FileManager.default.createFile(atPath: settled.recordPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        check("a record with both places already reading 0 still gets its pmset 0, then goes",
              settled.controller.recoverAtLaunch() && settled.pmset.calls == [false] && !recordExists(settled))
        let crashed = sleepHoldRig("crashed")
        FileManager.default.createFile(atPath: crashed.recordPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        crashed.registry.value = true
        check("a record and SleepDisabled 1: pmset 0, read back 0, record removed",
              crashed.controller.recoverAtLaunch() && crashed.registry.value == false && !recordExists(crashed))
        let clean = sleepHoldRig("clean")
        check("no record at launch: nothing run", clean.controller.recoverAtLaunch() && clean.pmset.calls.isEmpty)
        let staleRecord = sleepHoldRig("stale")
        FileManager.default.createFile(atPath: staleRecord.recordPath, contents: Data(SleepHoldRecordFile.contents.utf8),
                                       attributes: [.posixPermissions: 0o600])
        staleRecord.registry.value = true
        staleRecord.controller.connectionOpened(a)
        let afterStale = ask(staleRecord, .start(allowBattery: false), as: a)
        check("a start that finds its record from before restores sleep first, then holds",
              afterStale?.isHolding == true && staleRecord.pmset.calls == [false, true])
        let foreignRecord = sleepHoldRig("foreign")
        FileManager.default.createFile(atPath: foreignRecord.recordPath, contents: Data("v1\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        foreignRecord.registry.value = true
        check("a record that is not trusted as LocalNook's is never acted on: no 0 written",
              foreignRecord.controller.recoverAtLaunch() && foreignRecord.pmset.calls.isEmpty
                  && foreignRecord.registry.value == true)

        // SIGTERM.
        let stopping = sleepHoldRig("stopping")
        stopping.controller.connectionOpened(a)
        _ = ask(stopping, .start(allowBattery: false), as: a)
        let stopped = wait { stopping.controller.shutdown(completion: $0) }
        check("stopping restores sleep before saying it may exit",
              stopped == true && stopping.controller.snapshot().lastEnd?.reason == .helperStopping
                  && stopping.pmset.calls == [true, false] && !recordExists(stopping))
        let jammed = sleepHoldRig("jammed")
        jammed.controller.connectionOpened(a)
        _ = ask(jammed, .start(allowBattery: false), as: a)
        jammed.pmset.failClear = true
        let gaveUp = wait(timeout: 5) { jammed.controller.shutdown(completion: $0) }
        check("…and gives up after its retry window, saying so, with the record kept for the next start",
              gaveUp == false && jammed.pmset.calls.filter { !$0 }.count >= 2 && recordExists(jammed))
        jammed.pmset.failClear = false
        _ = waitUntil { jammed.controller.snapshot().isIdle }
        let quietStop = sleepHoldRig("quiet-stop")
        let nothing = wait { quietStop.controller.shutdown(completion: $0) }
        check("stopping with nothing held runs nothing", nothing == true && quietStop.pmset.calls.isEmpty)

        // Sleep notifications.
        let sleepy = sleepHoldRig("sleepy")
        sleepy.registry.lidState = LidReading(closed: true, causesSleep: true)
        sleepy.controller.connectionOpened(a)
        _ = ask(sleepy, .start(allowBattery: false), as: a)
        sleepy.controller.willSleep()
        settle()
        check("will-sleep under a hold — its setting cleared under it — ends it, and asks for no second sleep",
              sleepy.controller.snapshot().lastEnd?.reason == .sleep && sleepy.sleeper.requests == 0
                  && sleepy.controller.snapshot().isIdle)
        let asleep = ask(sleepy, .start(allowBattery: false), as: a)
        check("…until power-on a start is refused, nothing run", asleep?.error == .asleep
                  && sleepy.pmset.calls == [true, false])
        sleepy.controller.poweredOn()
        check("…and after it, a start holds again", ask(sleepy, .start(allowBattery: false), as: a)?.isHolding == true)

        // Requests that are not requests.
        let picky = sleepHoldRig("picky")
        let junk = wait { picky.controller.handle(Data("not json".utf8), for: a, reply: $0) }
        let huge = wait { picky.controller.handle(Data(repeating: 0x7b, count: 5000), for: a, reply: $0) }
        check("something that is not a request, or over the 4 KB cap, is refused, and runs nothing",
              junk?.error == .invalidRequest && huge?.error == .invalidRequest && picky.pmset.calls.isEmpty)

        // Idle exit.
        let busy = sleepHoldRig("busy")
        busy.controller.connectionOpened(a)
        _ = ask(busy, .start(allowBattery: false), as: a)
        busy.controller.connectionOpened(b)
        busy.controller.connectionClosed(b)
        for _ in 0..<5 {
            _ = ask(busy, .heartbeat, as: a)
            Thread.sleep(forTimeInterval: 0.08)
        }
        check("no idle exit while a hold is held", !busy.idle.isSet && !busy.controller.isIdle)
        _ = ask(busy, .release(.sessionEnded), as: a)
        busy.controller.connectionClosed(a)
        check("once let go and alone, it goes idle", waitUntil { busy.idle.isSet } && busy.controller.isIdle)
    }
}

// MARK: - Doubles

/// SleepDisabled — the kernel's and the stored one — and the lid, as the
/// registry and the preferences would say them. A pmset that ran writes the
/// stored one at once and moves the kernel's after `lagReads` reads of the
/// old one, as powerd's notice takes a moment — not at all before powerd is
/// up (`powerdRunning`, a boot), and nothing anywhere while `frozen` (pmset
/// exiting 0 with its write failed).
final class FakeRegistry: PowerManagementReading, @unchecked Sendable {
    private let lock = NSLock()
    private var kernel = SleepSetting.off
    private var stored = SleepSetting.off
    private var pending: Bool?
    private var lagLeft = 0
    private var laggedReads = 0
    private var isReadable = true
    private var isFrozen = false
    private var powerdUp = true
    private var kernelReads = 0
    private var flakyKernel = false
    private var storedLater: (afterReads: Int, value: SleepSetting)?
    private var storedLid: LidReading?
    var lagReads = 2

    /// The kernel's, as it will read once powerd has caught up. Set: what
    /// another app's pmset does — both places, at once.
    var value: Bool {
        get { lock.withLock { pending ?? (kernel == .on) } }
        set {
            lock.withLock {
                kernel = newValue ? .on : .off
                stored = kernel
                pending = nil
            }
        }
    }
    var kernelSetting: SleepSetting {
        get { lock.withLock { kernel } }
        set { lock.withLock { kernel = newValue; pending = nil } }
    }
    var storedSetting: SleepSetting {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var readable: Bool {
        get { lock.withLock { isReadable } }
        set { lock.withLock { isReadable = newValue } }
    }
    var frozen: Bool {
        get { lock.withLock { isFrozen } }
        set { lock.withLock { isFrozen = newValue } }
    }
    /// False: a boot before powerd has started. Set true, it publishes the
    /// stored setting, as it does when it starts.
    var powerdRunning: Bool {
        get { lock.withLock { powerdUp } }
        set {
            lock.withLock {
                powerdUp = newValue
                if newValue, stored != .absent, stored != .unreadable { kernel = stored }
            }
        }
    }
    /// Every other kernel read unreadable: failures that never run three in
    /// a row.
    var everyOtherReadFails: Bool {
        get { lock.withLock { flakyKernel } }
        set { lock.withLock { flakyKernel = newValue } }
    }
    var lidState: LidReading? {
        get { lock.withLock { storedLid } }
        set { lock.withLock { storedLid = newValue } }
    }
    var readsWhileLagging: Int { lock.withLock { laggedReads } }

    /// Another app's pmset writing the stored setting once `afterKernelReads`
    /// more kernel reads have been made — landing behind LocalNook's 0, whose
    /// own notice still reaches the kernel after it.
    func storedBecomes(_ value: SleepSetting, afterKernelReads: Int) {
        lock.withLock { storedLater = (kernelReads + afterKernelReads, value) }
    }

    func applied(_ disableSleep: Bool) {
        lock.withLock {
            guard !isFrozen else { return }
            stored = disableSleep ? .on : .off
            guard powerdUp else { return }
            pending = disableSleep
            lagLeft = lagReads
        }
    }

    func sleepDisabled() -> SleepSetting {
        lock.withLock {
            guard isReadable else { return .unreadable }
            kernelReads += 1
            if let later = storedLater, kernelReads > later.afterReads {
                stored = later.value
                storedLater = nil
            }
            if flakyKernel, kernelReads.isMultiple(of: 2) { return .unreadable }
            if let next = pending {
                if lagLeft > 0 {
                    lagLeft -= 1
                    laggedReads += 1
                    return kernel
                }
                kernel = next ? .on : .off
                pending = nil
            }
            return kernel
        }
    }

    func storedSleepDisabled() -> SleepSetting {
        lock.withLock { stored }
    }

    func lid() -> LidReading? { lock.withLock { storedLid } }
}

/// Records each run (true for disablesleep 1) and whether the record was
/// there at that moment; can fail either direction.
final class FakePmset: PmsetRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let registry: FakeRegistry
    private let recordPath: String
    private var log: [Bool] = []
    private var records: [Bool] = []
    private var failingSet = false
    private var failingClear = false

    init(registry: FakeRegistry, recordPath: String) {
        self.registry = registry
        self.recordPath = recordPath
    }

    var calls: [Bool] { lock.withLock { log } }
    var recordExistedAtCalls: [Bool] { lock.withLock { records } }
    var failSet: Bool {
        get { lock.withLock { failingSet } }
        set { lock.withLock { failingSet = newValue } }
    }
    var failClear: Bool {
        get { lock.withLock { failingClear } }
        set { lock.withLock { failingClear = newValue } }
    }

    func run(disableSleep: Bool) -> SpawnOutcome {
        let recordThere = FileManager.default.fileExists(atPath: recordPath)
        let fails = lock.withLock {
            log.append(disableSleep)
            records.append(recordThere)
            return disableSleep ? failingSet : failingClear
        }
        if fails { return .exited(1) }
        registry.applied(disableSleep)
        return .exited(0)
    }
}

final class FakePower: PowerSourceReader, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = PowerSourceReading(onAC: true, batteryPercent: 80, lowPowerMode: false)
    var reading: PowerSourceReading {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func read() -> PowerSourceReading { reading }
}

final class FakeTemperature: ChipTemperatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double? = 55
    private var reads = 0
    private var flaky = false
    var value: Double? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    /// Every other read nil: failures that never run three in a row.
    var everyOtherReadFails: Bool {
        get { lock.withLock { flaky } }
        set { lock.withLock { flaky = newValue } }
    }
    func hottest() -> Double? {
        lock.withLock {
            reads += 1
            return flaky && reads.isMultiple(of: 2) ? nil : stored
        }
    }
}

/// Counts what the real one would ask the kernel; can refuse the first few.
final class FakeSleeper: SystemSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var tries = 0
    private var accepted = 0
    private var refusing = 0
    var refuseFirst: Int {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    var attempts: Int { lock.withLock { tries } }
    /// Requests the kernel accepted.
    var requests: Int { lock.withLock { accepted } }

    func sleepNow() -> Bool {
        lock.withLock {
            tries += 1
            if refusing > 0 {
                refusing -= 1
                return false
            }
            accepted += 1
            return true
        }
    }
}
