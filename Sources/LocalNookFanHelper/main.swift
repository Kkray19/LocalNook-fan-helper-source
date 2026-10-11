//
//  main.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  The root fan helper: the only code in LocalNook that runs as root, the
//  only code that writes to the Mac's sensor controller, and — since
//  2026-10-06, at the user's request — the one way LocalNook keeps a Mac
//  running with its lid closed (SleepHoldController.swift), by running
//  `pmset disablesleep 1` and `0` and nothing else.
//
//  launchd starts it from /Library/PrivilegedHelperTools, where one
//  administrator prompt put it after checking its signature: when LocalNook
//  sends it a message, while the fans' marker or the sleep hold's record
//  exists, and once when the job is loaded — at install and at every boot
//  (RunAtLoad). That boot-time run restores anything a marker or a record
//  says is held — sleep above all, which a boot does not reset — and exits
//  ten seconds later (see LaunchdPlistCheck). It serves five calls —
//  status, apply, heartbeat, restore for the fans; sleepHold for the lid —
//  to an app signed as com.localnook.app by the very certificate the helper
//  is signed with, and nothing else.
//
//  Startup, in order, and why:
//    `--self-test`      the pure logic, both controllers against doubles and
//                       an in-process XPC round trip. No root, no SMC write,
//                       no pmset, no sleep, no file outside a temporary
//                       directory. Exits 0 or 1.
//    `--verify-plist p` whether p is exactly this helper's launchd job (see
//                       LaunchdPlistCheck). Exits 0 or 1.
//    not root           exits EX_CONFIG (78) before touching anything: an
//                       accidental launch is loud and harmless.
//    recovery           a marker left by a helper that died holding the
//                       fans means handing them back first; a record left
//                       holding the Mac awake means restoring sleep.
//    no certificate     an ad-hoc helper has nothing to pin the app to, so
//                       it never listens; it exits once nothing is held.
//    listen             pinned to `identifier "com.localnook.app" and
//                       certificate leaf = H"<own leaf SHA-1>"`, validated
//                       before NSXPC sees it (NSXPC traps on a bad one).
//  SIGTERM and SIGINT hand the fans back and restore sleep before exiting,
//  retrying for up to 20 s; launchd's ExitTimeOut (30 s) is the backstop.
//  Ten seconds after the last connection closes, with nothing held by
//  either, the helper exits.
//

import Foundation
import LocalNookSMC
import os

if CommandLine.arguments.contains("--self-test") {
    exit(HelperSelfTest.run())
}

if let flag = CommandLine.arguments.firstIndex(of: "--verify-plist") {
    guard flag + 1 < CommandLine.arguments.count else { exit(2) }
    exit(LaunchdPlistCheck.run(path: CommandLine.arguments[flag + 1]))
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("LocalNookFanHelper: runs as root, started by launchd; nothing done.\n".utf8))
    exit(78)
}

HelperDaemon.run()

enum HelperDaemon {
    private static let log = Logger(subsystem: FanHelperIdentity.label, category: "main")
    /// Where "is everything idle?" is asked: never from either controller's
    /// own queue, which each check takes in turn.
    private static let lifetime = DispatchQueue(label: "com.localnook.app.fan-helper.lifetime")

    static func run() -> Never {
        // Either controller going idle asks both, on the lifetime queue:
        // the helper exits only once neither holds anything.
        let parts = HelperParts()
        let exitIfIdle: @Sendable () -> Void = {
            lifetime.async {
                guard parts.allIdle else { return }
                log.notice("idle; exiting")
                exit(0)
            }
        }
        let controller = FanController(
            hardware: { SMCFanHardware.open() },
            ownership: FanOwnershipFiles(),
            onIdle: exitIfIdle)
        let sleepHold = SleepHoldController(
            pmset: SpawnedPmset(), registry: IORegistryPowerManagement(), power: IOKitPowerSource(),
            temperature: SMCChipTemperature(), sleeper: PowerManagerSleep(), record: SleepHoldRecordFile(),
            onIdle: exitIfIdle)
        lifetime.sync { parts.set(fans: controller, hold: sleepHold) }

        // Before anything else, and whether or not this copy can serve.
        if !controller.recoverAtLaunch() {
            log.error("recovery at launch did not confirm; the watchdog retries")
        }
        if !sleepHold.recoverAtLaunch() {
            log.error("restoring sleep at launch did not confirm; retrying")
        }

        /// Both let go, then exit: 0 once nothing is held by either.
        func stop() {
            let group = DispatchGroup()
            let results = ShutdownResults()
            group.enter()
            controller.shutdown { restored in
                results.record(restored)
                group.leave()
            }
            group.enter()
            sleepHold.shutdown { restored in
                results.record(restored)
                group.leave()
            }
            group.notify(queue: lifetime) {
                if !results.allRestored { log.error("stopping with a hand-back or sleep unconfirmed") }
                exit(results.allRestored ? 0 : 1)
            }
        }

        guard let leaf = CodeSigningPin.ownLeafSHA1(),
              let requirement = CodeSigningPin.requirement(identifier: FanHelperIdentity.appIdentifier,
                                                           leafSHA1: leaf)
        else {
            log.error("no signing certificate to pin the app to; not listening")
            stop()
            dispatchMain()
        }

        let delegate = FanHelperListenerDelegate(controller: controller, sleepHold: sleepHold)
        let listener = NSXPCListener(machServiceName: FanHelperIdentity.label)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate

        // Before the listener: without sleep notifications nothing would
        // hand the fans back before a sleep, so none are ever taken.
        let power = SystemPowerWatcher(controller: controller, sleepHold: sleepHold)
        if !power.start() {
            log.error("could not register for sleep notifications; refusing to take the fans")
            controller.sleepNotificationsUnavailable()
        }

        let signalQueue = DispatchQueue(label: "com.localnook.app.fan-helper.signals")
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { stop() }
            source.resume()
            return source
        }

        listener.resume()
        log.notice("listening")
        withExtendedLifetime((delegate, listener, power, signals)) {
            dispatchMain()
        }
    }
}

/// Both controllers, for the idle check. Set once, before either can go
/// idle, and read on the lifetime queue alone.
private final class HelperParts: @unchecked Sendable {
    private var fans: FanController?
    private var hold: SleepHoldController?

    func set(fans: FanController, hold: SleepHoldController) {
        self.fans = fans
        self.hold = hold
    }

    /// Neither holds anything and nobody is connected to either. Each
    /// check waits on its own controller's queue, never on the other's.
    var allIdle: Bool {
        guard let fans, let hold else { return false }
        return fans.isIdle && hold.isIdle
    }
}

/// What each controller's shutdown said, gathered on whatever queue each
/// answers on.
private final class ShutdownResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func record(_ restored: Bool) {
        lock.withLock { if !restored { failed = true } }
    }

    var allRestored: Bool { lock.withLock { !failed } }
}
