//
//  SleepHoldProtocol.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the MIT License. See LICENSES/MIT-LocalNookShared.txt.
//
//  Moved from LocalNookSMC to LocalNookShared (GPL boundary, 2026-10-08):
//  the owner's own code, linked by the app and by the root helper. Edited
//  only to name HelperWire instead of the fans' wire.
//
//  The contract for "Keep running with the lid closed": what the app may ask
//  the root helper about the Mac's sleep, and what it is told back.
//
//  ── Why the helper ─────────────────────────────────────────────────────────
//
//  No power assertion an app can create stops the sleep that closing the lid
//  starts (IOPMLib.h; the kernel's shouldSleepOnClamshellClosed reads none).
//  The one setting that does is SleepDisabled, which `pmset disablesleep 1`
//  sets: one global boolean with no owner, written to
//  /Library/Preferences/com.apple.PowerManagement.plist and re-applied by
//  powerd at every boot, and while it is set the kernel refuses every sleep
//  — the lid's, the Apple menu's, a low battery's and its own emergency
//  sleep when the Mac is too hot. Setting it takes root, and pmset carries
//  a private entitlement for the kernel call, so the helper runs pmset
//  itself (SleepHold.swift has why and how), on the same pinned connection
//  as the fans, with its own lease, guards and a record that outlives a
//  crash or a reboot (SleepHoldController.swift).
//
//  ── The calls ──────────────────────────────────────────────────────────────
//
//  One XPC method, `sleepHold`, carrying a JSON SleepHoldRequest; the reply
//  is a JSON SleepHoldStatus. Like the fans' requests, it names an action,
//  never a value: there is no way to ask for anything but "hold", "keep
//  holding", "let go" and "let go and sleep", and the helper decides whether
//  each is safe, whatever the app already checked.
//

import Foundation

// MARK: - Limits

public enum SleepHoldLimits {
    /// The app renews the hold this often, from its main run loop.
    public static let heartbeat: TimeInterval = 2
    /// After this long without a renewal the helper lets go: the app has
    /// quit, crashed or stopped answering.
    public static let lease: TimeInterval = 7
    /// The longest one hold lasts, whatever the app asks. The app's own
    /// limit is the Caffeinate session's.
    public static let ceiling: TimeInterval = 12 * 3600
    /// On battery — only ever by the person's choice — the hold ends at or
    /// below this charge.
    public static let batteryFloor = 20
}

// MARK: - Requests

/// Why the app let go.
public enum SleepHoldReleaseCause: String, Codable, Sendable, Equatable {
    /// The Caffeinate session the hold rode on ended.
    case sessionEnded
    /// The person switched "Keep running with the lid closed" off.
    case switchedOff
    /// LocalNook is quitting.
    case appQuitting
}

public enum SleepHoldAction: Codable, Sendable, Equatable {
    case status
    /// Take the hold — or, holding it already for this connection, change
    /// whether it may go on on battery.
    case start(allowBattery: Bool)
    /// The lease: every `SleepHoldLimits.heartbeat` while holding.
    case heartbeat
    case release(SleepHoldReleaseCause)
    /// Let go, then put the Mac to sleep: what the Apple menu's Sleep cannot
    /// do while the hold is on.
    case sleepNow
}

public struct SleepHoldRequest: Codable, Sendable, Equatable {
    public var action: SleepHoldAction

    public init(action: SleepHoldAction) {
        self.action = action
    }

    /// A request from the wire, or nil when it is over the payload cap or
    /// not a request.
    public static func decode(_ data: Data) -> SleepHoldRequest? {
        HelperWire.decode(SleepHoldRequest.self, from: data)
    }
}

// MARK: - Replies

/// Who holds the Mac awake, as the helper sees it from the asking connection.
public enum SleepHoldOwner: String, Codable, Sendable, Equatable {
    case nobody
    case thisConnection
    /// Another LocalNook connection: a second copy, or one from before a
    /// relaunch.
    case localNookOtherConnection
}

/// Why a hold ended.
public enum SleepHoldEndReason: String, Codable, Sendable, Equatable {
    /// The app let go: its session ended, the switch went off, it quit.
    case sessionEnded, switchedOff, appQuitting
    /// The person chose "Sleep now".
    case sleepNow
    /// No renewal within the lease, or the connection closed: LocalNook quit,
    /// crashed or hung.
    case appGone
    /// The helper is being stopped (SIGTERM: an update, a removal, a
    /// shutdown).
    case helperStopping
    /// A helper found its record at start: one before it died holding.
    case helperRestarted
    /// SleepDisabled read 0 while held: someone else cleared it. Not
    /// written again.
    case takenOver
    case onBattery, batteryLow, lowPowerMode
    /// macOS reported serious or critical thermal pressure.
    case thermalPressure
    /// The chip at 95 °C or above for 5 s (the same heat rule as the fans').
    case tooHot
    /// No temperature for a few seconds: the heat cut-off cannot be kept.
    case sensorsLost
    /// `SleepHoldLimits.ceiling` reached.
    case ceiling
    /// SleepDisabled could not be read for a few seconds.
    case unverifiable
    /// The Mac is going to sleep: something cleared the setting.
    case sleep
}

public struct SleepHoldEnd: Codable, Sendable, Equatable {
    public var reason: SleepHoldEndReason
    /// The helper asked the Mac to sleep afterwards: the lid was closed and
    /// the Mac was not running a display with it, or "Sleep now".
    public var sleptMac: Bool

    public init(reason: SleepHoldEndReason, sleptMac: Bool) {
        self.reason = reason
        self.sleptMac = sleptMac
    }
}

/// Why a request was refused.
public enum SleepHoldError: String, Codable, Sendable, Equatable, Error {
    case invalidRequest
    /// SleepDisabled already reads 1, and LocalNook did not set it.
    case otherAppHolds
    /// Another LocalNook connection holds it.
    case localNookOtherConnection
    case onBattery, batteryLow, lowPowerMode
    case thermalPressure, tooHot
    /// No temperature reading: the heat cut-off could not be kept.
    case noTemperatures
    /// The Mac has announced sleep and has not fully woken since.
    case asleep
    /// pmset did not run, or SleepDisabled did not read back as asked.
    case controlFailed
}

public struct SleepHoldStatus: Codable, Sendable, Equatable {
    public var revision: Int
    public var owner: SleepHoldOwner
    /// A release has not confirmed and the helper is retrying it: the Mac
    /// still cannot sleep.
    public var recovering: Bool
    /// SleepDisabled as the helper last read it; nil when it could not.
    public var sleepDisabled: Bool?
    /// Whether the hold may go on on battery.
    public var allowsBattery: Bool
    /// How long the current hold has lasted.
    public var heldSeconds: Double?
    public var lastEnd: SleepHoldEnd?
    public var error: SleepHoldError?

    public init(revision: Int = HelperWire.revision, owner: SleepHoldOwner = .nobody,
                recovering: Bool = false, sleepDisabled: Bool? = nil, allowsBattery: Bool = false,
                heldSeconds: Double? = nil, lastEnd: SleepHoldEnd? = nil, error: SleepHoldError? = nil) {
        self.revision = revision
        self.owner = owner
        self.recovering = recovering
        self.sleepDisabled = sleepDisabled
        self.allowsBattery = allowsBattery
        self.heldSeconds = heldSeconds
        self.lastEnd = lastEnd
        self.error = error
    }

    public var isHolding: Bool { owner == .thisConnection }

    public static func decode(_ data: Data) -> SleepHoldStatus? {
        HelperWire.decode(SleepHoldStatus.self, from: data)
    }
}
