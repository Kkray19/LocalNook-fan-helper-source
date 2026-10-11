//
//  SystemPowerWatcher.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Hands the fans back before the Mac sleeps, and only then lets it sleep.
//  The sleep hold hears the same two messages: a Mac holding cannot sleep,
//  so will-sleep means its setting was cleared under it, and from then until
//  power-on it takes no hold (SleepHoldController).
//
//  Vorssaint left sleep to its app, which hears NSWorkspace's will-sleep
//  notification — and that notification does not hold sleep up, so a Mac
//  could go to sleep with its fans pinned (its audit, W5). The helper
//  registers for system power itself instead. The kernel asks before an
//  idle sleep and announces a forced one; either way it waits for
//  IOAllowPowerChange, which is called only after the controller's hand-back
//  has returned.
//
//  Handing back is not enough on its own. Between that announcement and the
//  processor actually stopping, user space keeps running — for up to thirty
//  seconds while other clients answer, and for as long as a dark wake lasts
//  — so the controller also refuses to take the fans again until the Mac
//  says it is powering back on. For a process registered this way, xnu
//  (IOPMrootDomain.cpp, `_systemMessageClientMask`) sends will-sleep on the
//  way out of full wake and the power-on pair only on the way back into it,
//  or when a sleep is cancelled; dark wakes in between send neither. So
//  "asleep" here means "not in full wake since sleep was announced", which
//  is exactly when a start must not happen. Clearing on the first of the
//  pair, will-power-on, means the helper is taking requests again before
//  AppKit's didWake reaches the app.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

final class SystemPowerWatcher: @unchecked Sendable {
    // IOMessage.h's iokit_common_msg values; the macros do not import.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemWillPowerOn: UInt32 = 0xE000_0320
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    /// What a system power message asks of the helper.
    enum Response: Equatable {
        /// Answer an idle-sleep query: yes.
        case allow
        /// Hand the fans back, refuse new starts, then allow the sleep.
        case handBackThenAllow
        /// Full wake again: starts are allowed.
        case poweredOn
        case ignore
    }

    static func response(to message: UInt32) -> Response {
        switch message {
        case canSystemSleep: .allow
        case systemWillSleep: .handBackThenAllow
        case systemWillPowerOn, systemHasPoweredOn: .poweredOn
        default: .ignore
        }
    }

    private let controller: FanController
    private let sleepHold: SleepHoldController
    private let queue = DispatchQueue(label: "com.localnook.app.fan-helper.power")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(controller: FanController, sleepHold: SleepHoldController) {
        self.controller = controller
        self.sleepHold = sleepHold
    }

    /// False when the kernel will not register this process.
    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            Unmanaged<SystemPowerWatcher>.fromOpaque(context).takeUnretainedValue()
                .handle(message, notification: Int(bitPattern: argument))
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return false }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        return true
    }

    private func handle(_ message: UInt32, notification: Int) {
        switch Self.response(to: message) {
        case .allow:
            IOAllowPowerChange(rootPort, notification)
        case .handBackThenAllow:
            controller.willSleep()
            sleepHold.willSleep()
            IOAllowPowerChange(rootPort, notification)
        case .poweredOn:
            // Neither power-on message is acknowledged.
            controller.poweredOn()
            sleepHold.poweredOn()
        case .ignore:
            break
        }
    }
}
