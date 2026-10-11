//
//  FanController.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  Who holds the fans, for how long, and every way they go back to macOS.
//
//  ── One owner, on a lease ──────────────────────────────────────────────────
//
//  Only one connection holds the fans. Another LocalNook connection asking
//  while they are held is told `localNookOtherConnection` and changes
//  nothing. The owner renews a lease every 2 s; after 7 s without one the
//  helper hands the fans back (`appGone`). The lease is measured on
//  `systemUptime`, which stands still while the Mac sleeps, so a long sleep
//  is not mistaken for a dead app — sleep has its own hand-back below.
//
//  ── Never someone else's fans ──────────────────────────────────────────────
//
//  If any fan is out of automatic mode, or `Ftst` is set, and the helper did
//  not do it, the answer is `otherAppControls` — naming Vorssaint when its
//  marker file exists — and nothing is written, not even a hand-back.
//
//  The same holds once the helper has the fans. If another controller sets a
//  fan while the helper holds it — out of automatic mode, but not at a
//  target the helper wrote — every hand-back, whatever its reason, returns
//  only the fans still as the helper left them and leaves that one, and
//  `Ftst`, alone (`otherAppTookOver` when that is what ended control). The
//  firmware only ever takes a fan back to automatic, so this cannot mistake
//  it for another app. A new level — Cool following the chip, or the owner
//  choosing another — is written only after the same check: a fan another
//  controller has set makes the update fail without a write, and that
//  failure ends control like any other.
//
//  ── Lock and marker ────────────────────────────────────────────────────────
//
//  A root-only lock file excludes a second helper process, and a marker file
//  is created *before* the first write and removed only after a confirmed
//  hand-back. A helper that starts and finds the marker knows it died
//  holding the fans and hands them back first (`helperRestarted`); launchd
//  relaunches it for exactly that while the marker exists (the plist's
//  PathState). Both files must be owned by root, regular, private and singly
//  linked, and are opened without following links, so nothing in /var/run
//  can be swapped in to make the helper write elsewhere.
//
//  ── The watchdog ───────────────────────────────────────────────────────────
//
//  Once a second while the fans are held:
//    1. in Cool, the level is recomputed from the hottest reading, and
//       written only if it changed;
//    2. the fans are verified — still manual, still at their targets. Three
//       failures in a row and the firmware has taken them back; the helper
//       lets it (`systemTookOver`) and never takes them again by itself;
//    3. at 95 °C or more for 5 s while below 100%, the fans go back
//       (`tooHot`; both figures are FanLimits', which Settings quotes);
//       temperatures unreadable three times running, likewise
//       (`sensorsLost`). The reader holds a last good value through up to
//       four misses before it reports none, so that hand-back comes about
//       seven seconds after the sensors go quiet;
//    4. macOS reporting serious or critical thermal pressure ends it too
//       (`thermalPressure`).
//  A hand-back that does not confirm leaves the helper "recovering": the
//  marker stays, and the watchdog retries every second until the fans read
//  automatic.
//
//  ── Sleep ──────────────────────────────────────────────────────────────────
//
//  Before the Mac sleeps the fans are handed back, synchronously, and only
//  then is sleep allowed (SystemPowerWatcher). From then until the Mac says
//  it is powering back on, an apply is refused as `asleep` without writing:
//  user space runs on for a while after the announcement — and through dark
//  wakes — and anything taken then would be held through the sleep, on a
//  lease and a watchdog whose clocks stop with it. The helper never resumes
//  by itself; the app re-applies after wake from its in-memory choice. A
//  helper that could not register for sleep notifications at all takes
//  nothing: every apply but Auto is refused.
//
//  ── Threading ──────────────────────────────────────────────────────────────
//
//  All state belongs to one serial queue. A start can sleep for seconds on
//  some Macs (the `Ftst` path), so it runs on a second work queue while the
//  lease is suspended and status answers from what was last read; anything
//  that hands the fans back first waits for that work to finish, so a start
//  and a hand-back never write at the same time.
//

import Foundation
import LocalNookSMC
import os

// MARK: - Ownership files

/// The lock and the marker. Used from the controller's queue only.
protocol FanOwnership: AnyObject {
    var isHeld: Bool { get }
    func acquire() -> Bool
    func release()
    func markerExists() -> Bool
    func createMarker() -> Bool
    func removeMarker() -> Bool
    /// Vorssaint's marker, which only names who holds the fans.
    func otherControllerMarkerExists() -> Bool
}

final class FanOwnershipFiles: FanOwnership {
    private let lockPath: String
    private let markerPath: String
    private let otherMarkerPath: String
    /// Root in the helper; the self-test's own uid, so the same checks can
    /// run without root on files in a temporary directory.
    private let ownerUID: uid_t
    private var lockDescriptor: Int32 = -1

    init(lockPath: String = FanHelperIdentity.lockPath,
         markerPath: String = FanHelperIdentity.markerPath,
         otherMarkerPath: String = FanHelperIdentity.vorssaintMarkerPath,
         ownerUID: uid_t = 0) {
        self.lockPath = lockPath
        self.markerPath = markerPath
        self.otherMarkerPath = otherMarkerPath
        self.ownerUID = ownerUID
    }

    deinit { release() }

    var isHeld: Bool { lockDescriptor >= 0 }

    func acquire() -> Bool {
        if isHeld { return true }
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        guard isSecure(descriptor: descriptor), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    func release() {
        guard isHeld else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    func markerExists() -> Bool {
        var info = stat()
        guard lstat(markerPath, &info) == 0 else { return false }
        return isSecure(info)
    }

    /// Only while holding the lock, and only where nothing exists yet.
    func createMarker() -> Bool {
        guard isHeld else { return false }
        let descriptor = open(markerPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        let contents = Array("v1\n".utf8)
        let written = contents.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let secure = isSecure(descriptor: descriptor)
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == contents.count, synced, secure else {
            _ = unlink(markerPath)
            return false
        }
        return true
    }

    func removeMarker() -> Bool {
        var info = stat()
        guard lstat(markerPath, &info) == 0 else { return true }
        // Something that is not our marker is left alone, and reported as
        // not removed, so the helper keeps treating the fans as held.
        guard isSecure(info) else { return false }
        return unlink(markerPath) == 0
    }

    func otherControllerMarkerExists() -> Bool {
        var info = stat()
        return lstat(otherMarkerPath, &info) == 0
    }

    private func isSecure(descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && isSecure(info)
    }

    private func isSecure(_ info: stat) -> Bool {
        info.st_uid == ownerUID && (info.st_mode & S_IFMT) == S_IFREG
            && (info.st_mode & mode_t(0o077)) == 0 && info.st_nlink == 1
    }
}

// MARK: - When to hand back

enum FanControlPolicy {
    /// Consecutive verification or sensor failures that end control.
    static let failureLimit = 3

    /// Why the fans must go back now, or nil. In order: the app has gone
    /// quiet, the firmware has them, the chip is too hot, the sensors are
    /// gone, macOS is under thermal pressure.
    static func handBackReason(heartbeatAge: TimeInterval, lease: TimeInterval,
                               verificationFailures: Int, sensorFailures: Int,
                               hotFor: TimeInterval?, tooHotAfter: TimeInterval, level: Int,
                               thermalState: ProcessInfo.ThermalState) -> FanHandBackReason? {
        if heartbeatAge > lease { return .appGone }
        if verificationFailures >= failureLimit { return .systemTookOver }
        if let hotFor, hotFor >= tooHotAfter, level < FanLimits.levels.upperBound { return .tooHot }
        if sensorFailures >= failureLimit { return .sensorsLost }
        if thermalState == .serious || thermalState == .critical { return .thermalPressure }
        return nil
    }

    /// The level a mode starts at: its own for a fixed level, the Cool
    /// curve's for the hottest reading, nil when Cool has no reading.
    static func level(for mode: FanMode, hottest: Double?, previous: Int?) -> Int? {
        switch mode {
        case .automatic: nil
        case .fixed(let level): FanLimits.isValidLevel(level) ? level : nil
        case .cool: hottest.flatMap { FanCurve.cool.level(at: $0, previous: previous) }
        }
    }
}

// MARK: - The controller

final class FanController: @unchecked Sendable {
    struct Timing: Sendable {
        var lease: TimeInterval = 7
        var watchdog: TimeInterval = 1
        var tooHotAfter: TimeInterval = FanLimits.tooHotSeconds
        var idleExit: TimeInterval = 10
        var shutdownRetry: TimeInterval = 20
        var retryGap: TimeInterval = 1

        static let standard = Timing()
    }

    private enum Phase: Equatable {
        case idle
        /// A start is running on the work queue; the token tells its
        /// completion whether a hand-back overtook it.
        case starting(UUID)
        case controlling
        /// A hand-back did not confirm; retried every watchdog tick.
        case recovering
    }

    private let queue = DispatchQueue(label: "com.localnook.app.fan-helper.controller")
    private let workQueue = DispatchQueue(label: "com.localnook.app.fan-helper.work")
    private let makeHardware: @Sendable () -> Result<any FanHardware, FanHelperError>
    private let ownership: any FanOwnership
    private let timing: Timing
    private let clock: @Sendable () -> TimeInterval
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let onIdle: @Sendable () -> Void
    private let log = Logger(subsystem: FanHelperIdentity.label, category: "controller")

    // Everything below belongs to `queue`.
    private var hardware: (any FanHardware)?
    private var hardwareError: FanHelperError?
    private var connections: Set<UUID> = []
    private var phase = Phase.idle
    private var owner: UUID?
    private var mode = FanMode.automatic
    private var level: Int?
    private var lastHeartbeat: TimeInterval = 0
    private var verificationFailures = 0
    private var sensorFailures = 0
    private var hotSince: TimeInterval?
    private var lastHottest: Double?
    private var lastFans: [FanReading] = []
    private var lastHandBack: FanHandBackReason?
    /// Sleep was announced and full wake has not come back since.
    private var asleep = false
    /// Sleep notifications are being delivered. When they cannot be
    /// registered for, nothing would hand the fans back before a sleep, so
    /// nothing is taken at all.
    private var sleepWatched = true
    private var watchdog: DispatchSourceTimer?
    private var idleGeneration = 0

    init(hardware: @escaping @Sendable () -> Result<any FanHardware, FanHelperError>,
         ownership: any FanOwnership,
         timing: Timing = .standard,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         onIdle: @escaping @Sendable () -> Void) {
        self.makeHardware = hardware
        self.ownership = ownership
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

    /// The app quit, crashed or let go: its fans go back.
    func connectionClosed(_ id: UUID) {
        queue.async {
            self.connections.remove(id)
            if self.owner == id, self.phase != .idle, self.phase != .recovering {
                self.handBack(.appGone)
            }
            self.scheduleIdleExit()
        }
    }

    // MARK: Requests

    func status(for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        queue.async { reply(self.status(for: id)) }
    }

    /// `data` is a JSON FanRequest, validated here whatever the app checked.
    func apply(_ data: Data, for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        queue.async {
            guard let request = FanRequest.decode(data) else {
                reply(self.status(for: id, error: .invalidRequest))
                return
            }
            self.apply(request.mode, for: id, reply: reply)
        }
    }

    func heartbeat(for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        queue.async {
            if self.owner == id, self.phase == .controlling { self.lastHeartbeat = self.clock() }
            reply(self.status(for: id))
        }
    }

    /// From any authenticated caller: the user chose Auto.
    func restore(for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        queue.async {
            let restored = self.handBack(.userChose)
            reply(self.status(for: id, error: restored ? nil : .controlFailed))
            self.scheduleIdleExit()
        }
    }

    // MARK: Lifecycle

    /// At launch: a marker means a helper died holding the fans. True once
    /// nothing is held; false while a hand-back is still being retried.
    @discardableResult
    func recoverAtLaunch() -> Bool {
        queue.sync {
            defer { scheduleIdleExit() }
            guard ownership.acquire() else { return false }
            guard ownership.markerExists() else {
                ownership.release()
                return true
            }
            log.notice("found the marker at launch; handing the fans back")
            phase = .recovering
            return handBack(.helperRestarted)
        }
    }

    /// The Mac is about to sleep. Synchronous: sleep waits for it. Nothing
    /// is taken again until `poweredOn`.
    func willSleep() {
        queue.sync {
            asleep = true
            guard phase != .idle || ownership.markerExists() else { return }
            handBack(.sleep)
        }
    }

    /// Full wake, or a sleep that was cancelled: starts are allowed again.
    func poweredOn() {
        queue.sync { asleep = false }
    }

    /// The helper could not register for sleep notifications. From here on
    /// every apply but Auto is refused (`controlFailed`) — the lease and the
    /// watchdog stop with the Mac, so a hold nobody hands back before sleep
    /// would last through it. Status, heartbeat and restore still answer.
    func sleepNotificationsUnavailable() {
        queue.sync { sleepWatched = false }
    }

    /// SIGTERM or SIGINT: hand back, retrying for up to `shutdownRetry`.
    /// The completion gets true once nothing is held.
    func shutdown(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let deadline = self.clock() + self.timing.shutdownRetry
            @Sendable func attempt() {
                if self.handBack(.helperStopping) {
                    completion(true)
                } else if self.clock() >= deadline {
                    completion(false)
                } else {
                    self.queue.asyncAfter(deadline: .now() + self.timing.retryGap) { attempt() }
                }
            }
            attempt()
        }
    }

    /// Nothing held and nobody connected: what the helper's exit waits for.
    var isIdle: Bool {
        queue.sync { connections.isEmpty && phase == .idle }
    }

    // MARK: Taking the fans

    private func apply(_ requested: FanMode, for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        if requested == .automatic {
            let restored = handBack(.userChose)
            reply(status(for: id, error: restored ? nil : .controlFailed))
            return
        }
        // Nothing would hand the fans back before a sleep.
        guard sleepWatched else { return reply(status(for: id, error: .controlFailed)) }
        // Checked before anything else: whatever holds or recovers the fans
        // now has already been handed back by willSleep, or is being retried.
        guard !asleep else { return reply(status(for: id, error: .asleep)) }
        switch phase {
        case .starting:
            // One request at a time; the app does not send a second.
            reply(status(for: id, error: owner == id ? .controlFailed : nil))
        case .recovering:
            reply(status(for: id, error: handBack(.helperRestarted) ? nil : .controlFailed))
        case .controlling:
            guard owner == id else {
                reply(status(for: id))
                return
            }
            change(to: requested, for: id, reply: reply)
        case .idle:
            begin(requested, for: id, reply: reply)
        }
    }

    /// The owner picked another mode while holding the fans.
    private func change(to requested: FanMode, for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        guard let hardware else { return reply(status(for: id, error: .controlFailed)) }
        let hottest = requested == .cool ? hardware.readHottest() : nil
        guard let next = FanControlPolicy.level(for: requested, hottest: hottest, previous: level) else {
            return reply(status(for: id, error: .controlFailed))
        }
        if next == level || hardware.update(level: next) {
            // Logged like a start, so the log alone says which level a later
            // hand-back ended: a heat hand-back only ever ends one below 100%.
            log.notice("changing the fans from \(self.level ?? 0, privacy: .public)% to \(next, privacy: .public)% (\(Self.modeName(requested), privacy: .public))")
            mode = requested
            level = next
            lastHeartbeat = clock()
            verificationFailures = 0
            reply(status(for: id))
        } else {
            handBack(.systemTookOver)
            reply(status(for: id, error: .controlFailed))
        }
    }

    private func begin(_ requested: FanMode, for id: UUID, reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        guard let hardware = loadHardware() else {
            return reply(status(for: id, error: hardwareError ?? .unsupportedHardware))
        }
        guard ownership.acquire() else { return reply(status(for: id, error: .controlFailed)) }
        if ownership.markerExists() {
            // Left by a helper that died holding the fans: hand them back
            // before anything new.
            phase = .recovering
            guard handBack(.helperRestarted), ownership.acquire() else {
                return reply(status(for: id, error: .controlFailed))
            }
        }
        let fans = hardware.readFans()
        lastFans = fans
        guard !fans.isEmpty else {
            ownership.release()
            return reply(status(for: id, error: .unsupportedHardware))
        }
        if fans.contains(where: { !$0.isAutomatic }) || hardware.unlockEngaged() {
            ownership.release()
            return reply(status(for: id, error: .otherAppControls))
        }
        let hottest = requested == .cool ? hardware.readHottest() : nil
        guard let startLevel = FanControlPolicy.level(for: requested, hottest: hottest, previous: nil) else {
            ownership.release()
            return reply(status(for: id, error: .controlFailed))
        }
        guard ownership.createMarker() else {
            ownership.release()
            return reply(status(for: id, error: .controlFailed))
        }
        let token = UUID()
        phase = .starting(token)
        owner = id
        mode = requested
        level = startLevel
        lastHottest = hottest
        // A reason from before this hold would be read as the end of it.
        lastHandBack = nil
        log.notice("taking the fans at \(startLevel, privacy: .public)% (\(Self.modeName(requested), privacy: .public))")
        workQueue.async {
            let error = hardware.start(level: startLevel)
            self.queue.async { self.finishStart(token, error: error, for: id, reply: reply) }
        }
    }

    private func finishStart(_ token: UUID, error: FanHelperError?, for id: UUID,
                             reply: @escaping @Sendable (FanHelperStatus) -> Void) {
        guard phase == .starting(token) else {
            // A hand-back overtook the start and has already undone it.
            return reply(status(for: id))
        }
        if let error {
            log.error("could not take the fans: \(error.rawValue, privacy: .public)")
            if error == .controlFailed {
                // Something was written: confirm the hand-back the writer
                // already attempted, marker and all.
                handBack(nil)
            } else {
                // Nothing was written; above all, not someone else's fans.
                _ = ownership.removeMarker()
                ownership.release()
                clearControl()
                phase = .idle
            }
            return reply(status(for: id, error: error))
        }
        phase = .controlling
        lastHeartbeat = clock()
        verificationFailures = 0
        sensorFailures = 0
        hotSince = nil
        startWatchdog()
        reply(status(for: id))
    }

    // MARK: Handing back

    /// Every fan back to macOS, the marker removed, the lock released. True
    /// when nothing is held afterwards — including when nothing was. A
    /// failure leaves the helper recovering, retrying each tick.
    ///
    /// A fan another controller has set since the helper took it is not the
    /// helper's to hand back: then only the helper's own go back (`yield`),
    /// and a verification failure is reported as `otherAppTookOver`.
    @discardableResult
    private func handBack(_ asked: FanHandBackReason?) -> Bool {
        if isStarting { workQueue.sync {} }
        let wasActive = phase != .idle
        guard ownership.acquire() else { return !wasActive }
        let markerExisted = ownership.markerExists()
        guard wasActive || markerExisted else {
            ownership.release()
            return true
        }
        let hardware = loadHardware()
        let otherApp = hardware?.heldByAnother() ?? false
        let reason = otherApp && asked == .systemTookOver ? FanHandBackReason.otherAppTookOver : asked
        let released = hardware.map { otherApp ? $0.yield() : $0.restore() } ?? false
        if released, ownership.removeMarker() {
            if let reason { lastHandBack = reason }
            log.notice("fans handed back: \(reason?.rawValue ?? "failed start", privacy: .public)")
            clearControl()
            phase = .idle
            ownership.release()
            stopWatchdog()
            scheduleIdleExit()
            return true
        }
        log.error("hand-back did not confirm; retrying")
        if let reason { lastHandBack = reason }
        clearControl()
        phase = .recovering
        startWatchdog()
        return false
    }

    /// The mode as the log names it: "Max", "50%", "Cool". Levels alone read
    /// the same for Max and for Cool at full speed.
    static func modeName(_ mode: FanMode) -> String {
        switch mode {
        case .automatic: "Auto"
        case .cool: "Cool"
        case .fixed(let level): level >= FanLimits.levels.upperBound ? "Max" : "\(level)%"
        }
    }

    private func clearControl() {
        owner = nil
        mode = .automatic
        level = nil
        verificationFailures = 0
        sensorFailures = 0
        hotSince = nil
        lastHottest = nil
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
            return
        case .starting:
            return
        case .recovering:
            handBack(lastHandBack ?? .helperRestarted)
            return
        case .controlling:
            break
        }
        guard let hardware else {
            handBack(.systemTookOver)
            return
        }
        let now = clock()
        let hottest = hardware.readHottest()
        lastHottest = hottest
        sensorFailures = hottest == nil ? sensorFailures + 1 : 0

        var intact: Bool
        if mode == .cool, let hottest,
           let next = FanCurve.cool.level(at: hottest, previous: level), next != level {
            intact = hardware.update(level: next)
            if intact {
                // Info, not notice: Cool steps by itself as the chip warms
                // and cools, and `log show --info` is there when it matters.
                log.info("Cool: \(self.level ?? 0, privacy: .public)% to \(next, privacy: .public)% at \(Int(hottest.rounded()), privacy: .public) °C")
                level = next
            }
        } else {
            intact = hardware.verify()
        }
        verificationFailures = intact ? 0 : verificationFailures + 1

        if let hottest {
            hotSince = hottest >= FanLimits.tooHotCelsius ? (hotSince ?? now) : nil
        }
        let reason = FanControlPolicy.handBackReason(
            heartbeatAge: now - lastHeartbeat, lease: timing.lease,
            verificationFailures: verificationFailures, sensorFailures: sensorFailures,
            hotFor: hotSince.map { now - $0 }, tooHotAfter: timing.tooHotAfter,
            level: level ?? 0, thermalState: thermalState())
        if let reason { handBack(reason) }
    }

    // MARK: Status

    private func status(for id: UUID, error: FanHelperError? = nil) -> FanHelperStatus {
        var reportedError = error
        if isStarting {
            // The work queue has the hardware; answer from the last read.
        } else if let hardware = loadHardware() {
            lastFans = hardware.readFans()
        } else if reportedError == nil {
            reportedError = hardwareError
        }
        let owner: FanOwner
        switch phase {
        case .controlling, .starting:
            owner = self.owner == id ? .thisConnection : .localNookOtherConnection
        case .recovering:
            owner = .localNookOtherConnection
            reportedError = reportedError ?? .controlFailed
        case .idle:
            let heldElsewhere = lastFans.contains { !$0.isAutomatic }
                || (hardware?.unlockEngaged() ?? false)
            owner = heldElsewhere ? .otherApp : .system
        }
        let namesOther = owner == .otherApp || reportedError == .otherAppControls
        let other = namesOther ? (ownership.otherControllerMarkerExists() ? "Vorssaint" : "another app") : nil
        let holding = phase == .controlling || isStarting
        return FanHelperStatus(revision: FanHelperIdentity.revision,
                               mode: holding ? mode : .automatic,
                               owner: owner, fans: lastFans,
                               hottest: phase == .controlling ? lastHottest : nil,
                               otherController: other, lastHandBack: lastHandBack,
                               error: reportedError)
    }

    private var isStarting: Bool {
        if case .starting = phase { return true }
        return false
    }

    private func loadHardware() -> (any FanHardware)? {
        if let hardware { return hardware }
        switch makeHardware() {
        case .success(let opened):
            hardware = opened
            hardwareError = nil
            return opened
        case .failure(let error):
            hardwareError = error
            return nil
        }
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
        var isControlling: Bool
        var isRecovering: Bool
        var mode: FanMode
        var level: Int?
        var lastHandBack: FanHandBackReason?
        var hasWatchdog: Bool
        var isAsleep: Bool
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(isIdle: phase == .idle, isControlling: phase == .controlling,
                     isRecovering: phase == .recovering, mode: mode, level: level,
                     lastHandBack: lastHandBack, hasWatchdog: watchdog != nil, isAsleep: asleep)
        }
    }
}
