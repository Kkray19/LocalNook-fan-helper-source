//
//  SleepHoldController.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  Who holds the Mac awake with its lid closed, for how long, and every way
//  it goes back to sleeping as it should (2026-10-06, at the user's request).
//
//  ── One owner, on a lease ──────────────────────────────────────────────────
//
//  As the fans: one connection holds it, renewing every 2 s from the app's
//  main run loop, and 7 s without a renewal — the app quit, crashed or hung
//  — lets go (`appGone`), as does its connection closing. The lease is on
//  `systemUptime`; the Mac cannot sleep while the hold is on, so that clock
//  and the wall's agree.
//
//  ── Never someone else's ───────────────────────────────────────────────────
//
//  SleepDisabled is one boolean with no owner. A hold is refused while it
//  already reads 1, in the kernel or stored (`otherAppHolds` — Vorssaint's
//  lid option sets it, and so does anyone's `pmset disablesleep 1`). The
//  helper writes 0 only over a 1 it wrote: one it is holding, or one its
//  record says it wrote before it died. If the kernel reads 0 while held,
//  someone else cleared it: the hold ends as `takenOver`, nothing is
//  written, and it is never set again by itself. What it cannot see:
//  another app setting 1 between this read and its own write, whose 1 it
//  would then clear as its own; another app's 1 landing between its pmset 0
//  and its first sight of that 0, which it would clear again on a retry;
//  and another app's 1 made after a helper died holding, which the next
//  start clears, since the record still says the 1 is LocalNook's.
//
//  ── The record ─────────────────────────────────────────────────────────────
//
//  SleepDisabled is persisted, and powerd re-applies it at every boot, so a
//  helper that died holding it — or a Mac that lost power — would leave a
//  Mac that never sleeps. So a record (SleepHoldRecordFile) is written, and
//  flushed to the disk, before pmset 1, and removed only once a release is
//  confirmed; launchd keeps the helper running while it exists, and starts
//  it at every boot (RunAtLoad). A helper that starts and finds it runs
//  pmset 0 first (`helperRestarted`) — always, even when the kernel already
//  reads 0, which early in a boot can mean only that powerd has not yet
//  re-applied the stored 1.
//
//  A release is confirmed only once, after LocalNook's pmset 0, the kernel
//  has read 0 — not merely nothing, which is what it says before powerd
//  publishes at boot — and the stored setting has read 0, since pmset exits
//  0 even when its write failed. Each is counted once seen, so another
//  app's 1 coming after both does not make the helper undo it. Until then
//  the record stays and the helper retries every few seconds.
//
//  ── The guards, kept here ──────────────────────────────────────────────────
//
//  Whatever the app checked, once a second while holding:
//    - the lease, and SleepDisabled itself (0 is a takeover; unreadable
//      three times running ends it, `unverifiable`);
//    - heat: macOS reporting serious or critical thermal pressure, the chip
//      at 95 °C or more for 5 s (FanLimits', the fans' own line), or no
//      temperature three times running (`sensorsLost`). Mandatory: while
//      SleepDisabled is set the kernel's own thermal-emergency sleep is off,
//      so this is the only heat cut-off left;
//    - power: on the adapter only, unless the app passed the person's
//      battery opt-in — and then it ends at 20% or less, or in Low Power
//      Mode. A power source that cannot be read counts as a battery whose
//      charge is not known, which ends it. The 20% floor holds on the
//      adapter too, unless the battery is charging: an adapter too weak for
//      the load still reads "AC Power" while the battery runs down, and the
//      kernel's own low-battery sleep is off while SleepDisabled is set;
//    - twelve hours per hold, whatever the app's session says.
//  "Three running" means three looks in a row: one good reading between
//  failures starts the count again.
//  A start is refused for any of these before anything is written.
//
//  ── Ending ─────────────────────────────────────────────────────────────────
//
//  Every end goes through `end`: pmset 0, read back, the record removed.
//  Then, because clearing SleepDisabled does not make the kernel look at a
//  lid already shut, the Mac is put to sleep (IOPMSleepSystem, from here —
//  the one process still there when the app has died) when its lid is
//  closed and closing it sleeps the Mac (`AppleClamshellCausesSleep`: not in
//  clamshell mode with a display), or when the person chose "Sleep now". A
//  person who switches the option off at an open lid is never put to sleep,
//  since the lid is open. An end that does not confirm leaves the helper
//  "recovering", retrying every few seconds with the record kept, and the
//  Mac is not asked to sleep: it could not.
//
//  ── Sleep notifications ────────────────────────────────────────────────────
//
//  A Mac holding cannot sleep, so will-sleep arriving means the setting was
//  cleared under the hold: it ends (`sleep`). From then until the Mac says
//  it is powering on, a start is refused (`asleep`), as a fan's is.
//

import Foundation
import LocalNookSMC
import os

// MARK: - When to end

enum SleepHoldPolicy {
    /// Consecutive failed reads — temperature, or SleepDisabled — that end it.
    static let failureLimit = 3

    /// What one watchdog look found.
    struct Observation: Equatable {
        var heartbeatAge: TimeInterval
        var lease: TimeInterval
        /// This look's reading; nil when it could not be read.
        var sleepDisabled: Bool?
        var unreadableReads: Int
        var thermalState: ProcessInfo.ThermalState
        var hotFor: TimeInterval?
        var tooHotAfter: TimeInterval
        var sensorFailures: Int
        var power: PowerSourceReading
        var allowsBattery: Bool
        var heldFor: TimeInterval
        var ceiling: TimeInterval
    }

    /// Why the hold must end now, or nil. In order: someone else cleared
    /// it, the app is gone, heat, power, the ceiling, and a setting that
    /// can no longer be read.
    static func endReason(_ look: Observation) -> SleepHoldEndReason? {
        if look.sleepDisabled == false { return .takenOver }
        if look.heartbeatAge > look.lease { return .appGone }
        if look.thermalState == .serious || look.thermalState == .critical { return .thermalPressure }
        if let hot = look.hotFor, hot >= look.tooHotAfter { return .tooHot }
        if look.sensorFailures >= failureLimit { return .sensorsLost }
        if let power = powerReason(look.power, allowsBattery: look.allowsBattery) { return power }
        if look.heldFor >= look.ceiling { return .ceiling }
        if look.unreadableReads >= failureLimit { return .unverifiable }
        return nil
    }

    /// Why the power source does not allow a hold, or nil: anything but the
    /// adapter needs the battery opt-in, and then a charge above
    /// `SleepHoldLimits.batteryFloor` and Low Power Mode off. On the adapter
    /// the floor holds too while the battery is not charging — a weak
    /// charger, a hub's passthrough, a heavy load — whose "AC Power" would
    /// otherwise run a held Mac to its cut-off.
    static func powerReason(_ power: PowerSourceReading, allowsBattery: Bool) -> SleepHoldEndReason? {
        if power.onAC {
            guard let percent = power.batteryPercent, percent <= SleepHoldLimits.batteryFloor, !power.charging
            else { return nil }
            return .batteryLow
        }
        guard allowsBattery else { return .onBattery }
        if power.lowPowerMode { return .lowPowerMode }
        guard let percent = power.batteryPercent, percent > SleepHoldLimits.batteryFloor else { return .batteryLow }
        return nil
    }

    /// Whether the Mac is put to sleep once a hold has ended and
    /// SleepDisabled reads 0: "Sleep now" always; a sleep already on its
    /// way never; anything else only with the lid closed and closing it
    /// sleeping the Mac — so a person switching it off at an open lid, or
    /// a Mac running a display in clamshell mode, is left as it is.
    static func sleepsAfterEnd(_ reason: SleepHoldEndReason, lid: LidReading?) -> Bool {
        switch reason {
        case .sleepNow: return true
        case .sleep: return false
        default:
            guard let lid else { return false }
            return lid.closed && lid.causesSleep
        }
    }

    /// The refusal a start gets for what would end it at once.
    static func refusal(for reason: SleepHoldEndReason) -> SleepHoldError {
        switch reason {
        case .onBattery: .onBattery
        case .batteryLow: .batteryLow
        case .lowPowerMode: .lowPowerMode
        case .thermalPressure: .thermalPressure
        case .tooHot: .tooHot
        case .sensorsLost: .noTemperatures
        default: .controlFailed
        }
    }
}

// MARK: - The controller

final class SleepHoldController: @unchecked Sendable {
    struct Timing: Sendable {
        var lease: TimeInterval = SleepHoldLimits.lease
        var watchdog: TimeInterval = 1
        var tooHotAfter: TimeInterval = FanLimits.tooHotSeconds
        var ceiling: TimeInterval = SleepHoldLimits.ceiling
        /// How long pmset's change may take to reach the kernel.
        var readBack: TimeInterval = 2
        var readBackGap: TimeInterval = 0.05
        /// Between attempts at a release that did not confirm.
        var retryGap: TimeInterval = 5
        var shutdownRetry: TimeInterval = 20
        /// Asking for sleep is retried while the kernel catches up with the
        /// setting just cleared.
        var sleepAttempts = 3
        var sleepGap: TimeInterval = 0.5
        var idleExit: TimeInterval = 10

        static let standard = Timing()
    }

    private enum Phase: Equatable {
        case idle
        case holding
        /// A release did not confirm; retried every `retryGap`.
        case recovering
    }

    /// What a release that did not confirm will report once it does.
    private enum PendingEnd: Equatable {
        case reason(SleepHoldEndReason)
        /// Undoing a start that never took: nothing to report, and no
        /// sleep to ask for.
        case undoStart
    }

    private let queue = DispatchQueue(label: "com.localnook.app.fan-helper.sleep-hold")
    private let sleepQueue = DispatchQueue(label: "com.localnook.app.fan-helper.sleep-request")
    private let pmset: any PmsetRunning
    private let registry: any PowerManagementReading
    private let power: any PowerSourceReader
    private let temperature: any ChipTemperatureReading
    private let sleeper: any SystemSleeping
    private let record: any SleepHoldRecording
    private let timing: Timing
    private let clock: @Sendable () -> TimeInterval
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let onIdle: @Sendable () -> Void
    private let log = Logger(subsystem: FanHelperIdentity.label, category: "sleep-hold")

    // Everything below belongs to `queue`.
    private var connections: Set<UUID> = []
    private var phase = Phase.idle
    private var owner: UUID?
    private var allowsBattery = false
    private var heldSince: TimeInterval = 0
    private var lastHeartbeat: TimeInterval = 0
    private var hotSince: TimeInterval?
    private var sensorFailures = 0
    private var unreadableReads = 0
    private var lastEnd: SleepHoldEnd?
    /// What a release that did not confirm will report once it does.
    private var pendingEnd: PendingEnd?
    private var nextRetryAt: TimeInterval = 0
    private var asleep = false
    private var watchdog: DispatchSourceTimer?
    private var idleGeneration = 0

    init(pmset: any PmsetRunning, registry: any PowerManagementReading, power: any PowerSourceReader,
         temperature: any ChipTemperatureReading, sleeper: any SystemSleeping, record: any SleepHoldRecording,
         timing: Timing = .standard,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         onIdle: @escaping @Sendable () -> Void) {
        self.pmset = pmset
        self.registry = registry
        self.power = power
        self.temperature = temperature
        self.sleeper = sleeper
        self.record = record
        self.timing = timing
        self.clock = clock
        self.thermalState = thermalState
        self.onIdle = onIdle
    }

    // MARK: Connections

    func connectionOpened(_ id: UUID) {
        queue.async {
            self.connections.insert(id)
            self.idleGeneration += 1
        }
    }

    /// The app quit, crashed or let go: its hold ends.
    func connectionClosed(_ id: UUID) {
        queue.async {
            self.connections.remove(id)
            if self.owner == id, self.phase == .holding { self.end(.appGone) }
            self.scheduleIdleExit()
        }
    }

    // MARK: Requests

    /// `data` is a JSON SleepHoldRequest, validated here whatever the app
    /// checked.
    func handle(_ data: Data, for id: UUID, reply: @escaping @Sendable (SleepHoldStatus) -> Void) {
        queue.async {
            guard let request = SleepHoldRequest.decode(data) else {
                return reply(self.status(for: id, error: .invalidRequest))
            }
            switch request.action {
            case .status:
                reply(self.status(for: id))
            case .start(let allowBattery):
                reply(self.start(allowBattery: allowBattery, for: id))
            case .heartbeat:
                if self.owner == id, self.phase == .holding { self.lastHeartbeat = self.clock() }
                reply(self.status(for: id))
            case .release(let cause):
                if self.owner == id, self.phase == .holding {
                    self.end(Self.reason(for: cause))
                } else if self.phase == .recovering {
                    self.retry()
                }
                reply(self.status(for: id))
                self.scheduleIdleExit()
            case .sleepNow:
                reply(self.sleepNow(for: id))
                self.scheduleIdleExit()
            }
        }
    }

    private static func reason(for cause: SleepHoldReleaseCause) -> SleepHoldEndReason {
        switch cause {
        case .sessionEnded: .sessionEnded
        case .switchedOff: .switchedOff
        case .appQuitting: .appQuitting
        }
    }

    // MARK: Lifecycle

    /// At launch, and at every boot: a record means a helper died holding,
    /// or the Mac went down with the hold on. True once nothing is held;
    /// false while the release is still being retried.
    @discardableResult
    func recoverAtLaunch() -> Bool {
        queue.sync {
            defer { scheduleIdleExit() }
            guard record.exists() else { return true }
            log.notice("found the sleep hold's record at launch; restoring sleep")
            phase = .recovering
            return end(.helperRestarted)
        }
    }

    /// The Mac is about to sleep. Synchronous: sleep waits for it. Nothing
    /// is held again until `poweredOn`.
    func willSleep() {
        queue.sync {
            asleep = true
            if phase == .holding { end(.sleep) }
        }
    }

    func poweredOn() {
        queue.sync { asleep = false }
    }

    /// SIGTERM or SIGINT: let go, retrying for up to `shutdownRetry`. The
    /// completion gets true once nothing is held.
    func shutdown(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let deadline = self.clock() + self.timing.shutdownRetry
            @Sendable func attempt() {
                if self.phase == .idle, !self.record.exists() {
                    completion(true)
                } else if self.phase == .recovering ? self.end(self.retryReason(or: .helperStopping), isRetry: true)
                                                    : self.end(.helperStopping) {
                    completion(true)
                } else if self.clock() >= deadline {
                    completion(false)
                } else {
                    self.queue.asyncAfter(deadline: .now() + min(1, self.timing.retryGap)) { attempt() }
                }
            }
            attempt()
        }
    }

    /// Nothing held and nobody connected: what the helper's exit waits for.
    var isIdle: Bool {
        queue.sync { connections.isEmpty && phase == .idle }
    }

    // MARK: Taking the hold

    private func start(allowBattery: Bool, for id: UUID) -> SleepHoldStatus {
        switch phase {
        case .holding:
            guard owner == id else { return status(for: id, error: .localNookOtherConnection) }
            // The person changed whether it may run on battery.
            allowsBattery = allowBattery
            lastHeartbeat = clock()
            if let reason = SleepHoldPolicy.powerReason(power.read(), allowsBattery: allowBattery) {
                end(reason)
                return status(for: id, error: SleepHoldPolicy.refusal(for: reason))
            }
            return status(for: id)
        case .recovering:
            guard retry() else { return status(for: id, error: .controlFailed) }
        case .idle:
            break
        }
        guard !asleep else { return status(for: id, error: .asleep) }

        // Every guard before anything is written.
        if let reason = SleepHoldPolicy.powerReason(power.read(), allowsBattery: allowBattery) {
            return status(for: id, error: SleepHoldPolicy.refusal(for: reason))
        }
        let thermal = thermalState()
        if thermal == .serious || thermal == .critical { return status(for: id, error: .thermalPressure) }
        guard let hottest = temperature.hottest() else { return status(for: id, error: .noTemperatures) }
        if hottest >= FanLimits.tooHotCelsius { return status(for: id, error: .tooHot) }

        // A record left by a helper that died holding: undone first.
        if record.exists() {
            phase = .recovering
            guard end(.helperRestarted) else { return status(for: id, error: .controlFailed) }
        }
        // Not LocalNook's — in force, or stored for the next boot: never
        // taken, never cleared.
        let kernel = registry.sleepDisabled()
        let stored = registry.storedSleepDisabled()
        guard let enforced = kernel.enforced, stored != .unreadable else {
            return status(for: id, error: .controlFailed)
        }
        guard !enforced, stored != .on else { return status(for: id, error: .otherAppHolds) }
        guard record.create() else { return status(for: id, error: .controlFailed) }

        log.notice("disabling sleep for the lid (battery \(allowBattery ? "allowed" : "not allowed", privacy: .public))")
        let outcome = pmset.run(disableSleep: true)
        if outcome.succeeded, readBackHeld() {
            phase = .holding
            owner = id
            allowsBattery = allowBattery
            heldSince = clock()
            lastHeartbeat = heldSince
            hotSince = nil
            sensorFailures = 0
            unreadableReads = 0
            // A reason from before this hold would be read as the end of it.
            lastEnd = nil
            pendingEnd = nil
            startWatchdog()
            return status(for: id)
        }
        // It may have been written and not read back: undone like a release,
        // with no end to report and no sleep asked for.
        log.error("disabling sleep did not confirm: \(String(describing: outcome), privacy: .public)")
        phase = .recovering
        end(nil)
        return status(for: id, error: .controlFailed)
    }

    // MARK: Ending

    /// The one way a hold ends: pmset 0 (not for a takeover, which is 0
    /// already), read back — the kernel and the stored setting — the record
    /// removed, then sleep, by the policy. True when nothing is held
    /// afterwards, including when nothing was. `nil` undoes a start that did
    /// not take: no end is reported and no sleep asked for, on a retry too.
    /// A retry of "Sleep now" sleeps only by the lid's rule: the person who
    /// asked may long since have moved on.
    @discardableResult
    private func end(_ reason: SleepHoldEndReason?, isRetry: Bool = false) -> Bool {
        guard phase != .idle || record.exists() else { return true }
        let confirmed: Bool
        if reason == .takenOver {
            confirmed = true
        } else {
            let outcome = pmset.run(disableSleep: false)
            confirmed = outcome.succeeded && readBackReleased()
            if !outcome.succeeded {
                log.error("restoring sleep: pmset \(String(describing: outcome), privacy: .public)")
            }
        }
        if confirmed, record.remove() {
            let rule = reason == .sleepNow && isRetry ? SleepHoldEndReason.sessionEnded : reason
            let sleeps = rule.map { SleepHoldPolicy.sleepsAfterEnd($0, lid: registry.lid()) } ?? false
            if let reason {
                lastEnd = SleepHoldEnd(reason: reason, sleptMac: sleeps)
                log.notice("sleep restored: \(reason.rawValue, privacy: .public)\(sleeps ? "; asking the Mac to sleep" : "", privacy: .public)")
            }
            clearHold()
            pendingEnd = nil
            phase = .idle
            stopWatchdog()
            if sleeps { requestSleep() }
            scheduleIdleExit()
            return true
        }
        log.error("restoring sleep did not confirm; retrying")
        // The first reason is the one reported: a retry passes it back in.
        if let reason {
            pendingEnd = .reason(reason)
        } else if pendingEnd == nil {
            pendingEnd = .undoStart
        }
        clearHold()
        phase = .recovering
        nextRetryAt = clock() + timing.retryGap
        startWatchdog()
        return false
    }

    /// One more attempt at a release that did not confirm.
    @discardableResult
    private func retry() -> Bool {
        end(retryReason(or: .helperRestarted), isRetry: true)
    }

    /// What a retry ends with: the pending reason, none for an undone
    /// start, or `fallback` when nothing is pending (a record found).
    private func retryReason(or fallback: SleepHoldEndReason) -> SleepHoldEndReason? {
        switch pendingEnd {
        case .reason(let reason): reason
        case .undoStart: nil
        case nil: fallback
        }
    }

    private func clearHold() {
        owner = nil
        allowsBattery = false
        hotSince = nil
        sensorFailures = 0
        unreadableReads = 0
    }

    /// "Sleep now": the hold let go, then the Mac asked to sleep. With
    /// nothing held it still sleeps — what the person asked for — unless
    /// SleepDisabled reads 1, which is not LocalNook's to clear.
    private func sleepNow(for id: UUID) -> SleepHoldStatus {
        switch phase {
        case .holding:
            guard owner == id else { return status(for: id, error: .localNookOtherConnection) }
            return status(for: id, error: end(.sleepNow) ? nil : .controlFailed)
        case .recovering:
            guard retry() else { return status(for: id, error: .controlFailed) }
            fallthrough
        case .idle:
            guard registry.sleepDisabled().enforced == false else { return status(for: id, error: .otherAppHolds) }
            log.notice("asking the Mac to sleep: Sleep now")
            requestSleep()
            return status(for: id)
        }
    }

    private func requestSleep() {
        let sleeper = sleeper
        let attempts = max(1, timing.sleepAttempts)
        let gap = timing.sleepGap
        let log = log
        sleepQueue.async {
            for attempt in 1...attempts {
                if sleeper.sleepNow() { return }
                if attempt < attempts { Thread.sleep(forTimeInterval: gap) }
            }
            log.error("the Mac did not accept the request to sleep")
        }
    }

    /// Polls the kernel's SleepDisabled until it reads 1, for up to
    /// `readBack`: pmset's change reaches it through powerd, a moment later.
    private func readBackHeld() -> Bool {
        let deadline = clock() + timing.readBack
        while true {
            if registry.sleepDisabled() == .on { return true }
            if clock() >= deadline { return false }
            Thread.sleep(forTimeInterval: timing.readBackGap)
        }
    }

    /// Polls, for up to `readBack`, until both the kernel and the stored
    /// setting have read 0 since this pmset 0. Each counts once seen: a 1
    /// another app writes after both were is not this helper's to undo. A
    /// kernel with no property yet (a boot before powerd has published) or
    /// a stored 1 (pmset's write failed, though it exited 0) is not 0.
    private func readBackReleased() -> Bool {
        let deadline = clock() + timing.readBack
        var kernelOff = false
        var storedOff = false
        while true {
            if !kernelOff { kernelOff = registry.sleepDisabled() == .off }
            if !storedOff { storedOff = registry.storedSleepDisabled() == .off }
            if kernelOff, storedOff { return true }
            if clock() >= deadline { return false }
            Thread.sleep(forTimeInterval: timing.readBackGap)
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timing.watchdog, repeating: timing.watchdog,
                       leeway: .milliseconds(Int(max(1, timing.watchdog * 100))))
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func tick() {
        switch phase {
        case .idle:
            stopWatchdog()
        case .recovering:
            guard clock() >= nextRetryAt else { return }
            retry()
        case .holding:
            let now = clock()
            // Held, the kernel has published it: absent now is as unreadable.
            let disabled: Bool? = switch registry.sleepDisabled() {
            case .on: true
            case .off: false
            case .absent, .unreadable: nil
            }
            unreadableReads = disabled == nil ? unreadableReads + 1 : 0
            let hottest = temperature.hottest()
            sensorFailures = hottest == nil ? sensorFailures + 1 : 0
            if let hottest { hotSince = hottest >= FanLimits.tooHotCelsius ? (hotSince ?? now) : nil }
            let look = SleepHoldPolicy.Observation(
                heartbeatAge: now - lastHeartbeat, lease: timing.lease,
                sleepDisabled: disabled, unreadableReads: unreadableReads,
                thermalState: thermalState(), hotFor: hotSince.map { now - $0 },
                tooHotAfter: timing.tooHotAfter, sensorFailures: sensorFailures,
                power: power.read(), allowsBattery: allowsBattery,
                heldFor: now - heldSince, ceiling: timing.ceiling)
            if let reason = SleepHoldPolicy.endReason(look) { end(reason) }
        }
    }

    // MARK: Status

    private func status(for id: UUID, error: SleepHoldError? = nil) -> SleepHoldStatus {
        let holding = phase == .holding
        return SleepHoldStatus(
            owner: holding ? (owner == id ? .thisConnection : .localNookOtherConnection) : .nobody,
            recovering: phase == .recovering,
            sleepDisabled: registry.sleepDisabled().enforced,
            allowsBattery: holding && allowsBattery,
            heldSeconds: holding ? max(0, clock() - heldSince) : nil,
            lastEnd: lastEnd, error: error)
    }

    // MARK: Idle

    private func scheduleIdleExit() {
        guard connections.isEmpty, phase == .idle else { return }
        idleGeneration += 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + timing.idleExit) {
            guard generation == self.idleGeneration, self.connections.isEmpty, self.phase == .idle else { return }
            self.onIdle()
        }
    }

    // MARK: Inspection, for the self-test

    struct Snapshot: Equatable {
        var isIdle: Bool
        var isHolding: Bool
        var isRecovering: Bool
        var allowsBattery: Bool
        var lastEnd: SleepHoldEnd?
        var hasWatchdog: Bool
        var isAsleep: Bool
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(isIdle: phase == .idle, isHolding: phase == .holding, isRecovering: phase == .recovering,
                     allowsBattery: allowsBattery, lastEnd: lastEnd, hasWatchdog: watchdog != nil,
                     isAsleep: asleep)
        }
    }
}
