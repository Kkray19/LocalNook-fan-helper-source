//
//  SleepHold.swift
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
//  THE HELPER'S ONE SPAWN, AND WHAT IT READS ABOUT THE MAC'S SLEEP
//  ─────────────────────────────────────────────────────────────────────────
//
//  WHY THIS EXISTS
//  The user asked on 2026-10-06 for "Keep running with the lid closed", in
//  this helper, knowing it widens what runs as root. Closing a MacBook's lid
//  sleeps it whatever power assertions are held; the one setting that stops
//  it is SleepDisabled (`pmset disablesleep 1`), which only root may set.
//  pmset sets it through IOPMSetSystemPowerSetting, which is in no public
//  header and reaches the kernel through powerd, whose entitlement
//  (com.apple.private.iokit.rootdomain-set-property) no third party can
//  have. So the helper runs Apple's own /usr/bin/pmset rather than call
//  private API — the first process it has ever started.
//
//  SCOPE
//  Exactly two argument lists, and nothing else, ever:
//    /usr/bin/pmset disablesleep 1
//    /usr/bin/pmset disablesleep 0
//  They are built here from a Bool, so no caller can form another, and the
//  spawn itself checks every list it is handed against that allowlist, and
//  its environment against PATH alone: anything else is a `precondition`
//  failure, as an SMC write outside the fan keys is — but for the
//  self-test, which drives the spawn's mechanics with harmless programs and
//  never runs the daemon. No shell: posix_spawn of the path itself, with a
//  fixed environment (PATH alone), every descriptor but /dev/null closed
//  (POSIX_SPAWN_CLOEXEC_DEFAULT), signals back to their defaults and none
//  blocked — the helper ignores SIGTERM, and a child must not inherit that —
//  and a 5 s limit, after which it is killed. Its output is not read, nor
//  its exit code trusted alone: pmset exits 0 even when its write failed
//  (it only prints "failed to set the value"). What matters is read back.
//
//  READING IT BACK
//  Two places, both read-only and both undocumented, never by parsing
//  `pmset -g`, which would be a third command:
//    * The kernel's: IOPMrootDomain's `SleepDisabled`. The kernel sets that
//      property in the same `setProperties` call that queues the flag its
//      sleep checks read (IOPMrootDomain.cpp, `userDisabledAllSleep`), so it
//      is what is enforced, not what was asked for. It arrives through
//      powerd a moment after pmset returns, so the controller polls it for
//      up to two seconds. powerd publishes it — true or false — only once a
//      stored system setting exists (pm_PMSettings.m,
//      `PMActivateSystemPowerSettings`), and not before powerd has started
//      at boot: absent, the kernel enforces its own default, false, but that
//      says nothing about what powerd is about to re-apply.
//    * The stored one: the `SleepDisabled` entry of the `SystemPowerSettings`
//      dictionary in the `com.apple.PowerManagement` preferences (any user,
//      this host) — what pmset writes and powerd re-applies at every boot.
//      Read through CFPreferences after a synchronize, so never a stale copy.
//  A start needs the kernel to read 1. A release is confirmed only once
//  both have read 0 after LocalNook's pmset 0: the kernel alone could be a
//  boot that has not re-applied the stored 1 yet, and pmset's exit code
//  alone a write that failed (SleepHoldController has the rule).
//
//  The lid is the same object's `AppleClamshellState`, and whether closing
//  it sleeps the Mac at all — false in clamshell mode, running a display on
//  power — `AppleClamshellCausesSleep`, which the kernel publishes from the
//  very test it applies (`shouldSleepOnClamshellClosed`); both undocumented,
//  both read only. The power source, the charge and whether it is charging
//  are IOKit's public power-source calls; Low Power Mode is ProcessInfo's.
//
//  SLEEPING
//  Clearing SleepDisabled does not make the kernel look at a lid already
//  closed again: a Mac shut while it was set stays awake. So after a hold
//  ends the controller may ask for sleep (IOPMSleepSystem), from here — the
//  one process still running when the app has died — and only after
//  SleepDisabled reads 0, retried briefly while the kernel catches up.
//
//  NEVER IN A TEST
//  `HelperProcess.mayChangeSystem` is false under `--self-test` and for any
//  user but root: the real spawn and the real sleep then refuse and do
//  nothing. The self-test runs the controller against doubles, and the
//  spawn's mechanics against harmless system programs.
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LocalNookSMC

// MARK: - The process

enum HelperProcess {
    static let isSelfTest = CommandLine.arguments.contains("--self-test")

    /// Whether this process may change the Mac's sleep: root, and never the
    /// self-test.
    static var mayChangeSystem: Bool { !isSelfTest && geteuid() == 0 }
}

// MARK: - The command

/// The two argument lists, and the check the spawn makes.
enum PmsetCommand {
    static let program = "/usr/bin/pmset"

    static func arguments(disableSleep: Bool) -> [String] {
        [program, "disablesleep", disableSleep ? "1" : "0"]
    }

    static let allowed: Set<[String]> = [arguments(disableSleep: true), arguments(disableSleep: false)]

    static func permits(_ argv: [String]) -> Bool { allowed.contains(argv) }

    /// PATH alone: nothing the helper's own environment holds reaches pmset.
    static let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    static let timeout: TimeInterval = 5
}

/// How a spawned program ended.
enum SpawnOutcome: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    /// Still running at the limit, and killed.
    case timedOut
    /// posix_spawn or waitpid failed, with that errno.
    case failed(Int32)
    /// Not attempted: not root, or the self-test.
    case refused

    var succeeded: Bool { self == .exited(0) }

    /// What waitpid's status word says: the low seven bits are the signal
    /// that ended it, zero for a normal exit with its code in the next byte.
    static func from(waitStatus status: Int32) -> SpawnOutcome {
        let signal = status & 0x7f
        if signal == 0 { return .exited((status >> 8) & 0xff) }
        return .signaled(signal)
    }
}

/// Runs pmset. The real one spawns it; the self-test's records.
protocol PmsetRunning: AnyObject, Sendable {
    func run(disableSleep: Bool) -> SpawnOutcome
}

final class SpawnedPmset: PmsetRunning, @unchecked Sendable {
    func run(disableSleep: Bool) -> SpawnOutcome {
        let argv = PmsetCommand.arguments(disableSleep: disableSleep)
        guard HelperProcess.mayChangeSystem else { return .refused }
        return HelperSpawn.run(argv, environment: PmsetCommand.environment, timeout: PmsetCommand.timeout)
    }
}

/// The spawn itself. Its one caller in the daemon is SpawnedPmset; the
/// self-test drives it with harmless system programs to check the
/// mechanics, and is the only process in which it starts anything but the
/// two pmset lists.
enum HelperSpawn {
    /// What the spawn will start: the allowlist, with PATH alone — and,
    /// in the self-test only, anything (it never runs the daemon).
    static func permits(_ argv: [String], environment: [String], selfTest: Bool) -> Bool {
        selfTest || (PmsetCommand.permits(argv) && environment == PmsetCommand.environment)
    }

    static func run(_ argv: [String], environment: [String], timeout: TimeInterval) -> SpawnOutcome {
        // At the spawn, as the SMC writer checks its keys at the write: no
        // path through this file starts anything else as root.
        precondition(permits(argv, environment: environment, selfTest: HelperProcess.isSelfTest),
                     "the helper runs pmset disablesleep 1 or 0, with PATH alone, and nothing else")
        guard let path = argv.first else { return .failed(EINVAL) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Every descriptor closed but the three below; signals back to their
        // defaults (the helper ignores SIGTERM and SIGINT, and a child would
        // inherit that) and none blocked.
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setsigdefault(&attributes, &all) == 0,
              posix_spawnattr_setsigmask(&attributes, &none) == 0
        else { return .failed(EINVAL) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failed(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 {
            let mode = descriptor == 0 ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", mode, 0) == 0
            else { return .failed(EINVAL) }
        }

        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.map { strdup($0) } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, arguments, variables)
        guard spawned == 0 else { return .failed(spawned) }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return .from(waitStatus: status) }
            if waited == -1, errno != EINTR { return .failed(errno) }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                return .timedOut
            }
            usleep(10_000)
        }
    }
}

// MARK: - The power manager's state

/// The lid as the kernel publishes it.
struct LidReading: Equatable, Sendable {
    var closed: Bool
    /// Whether closing it sleeps the Mac: false in clamshell mode (a display
    /// and power connected), when the kernel itself would not sleep.
    var causesSleep: Bool
}

/// SleepDisabled as one place has it.
enum SleepSetting: Equatable, Sendable {
    case on, off
    /// Not there. The kernel's, until powerd publishes one — after it has
    /// started at boot, and only once a stored setting exists; the stored
    /// one, on a Mac where no system power setting was ever made.
    case absent
    /// Could not be read, or not a boolean.
    case unreadable

    /// What the kernel enforces, read from its property: absent is its own
    /// default, off. Nil when unreadable.
    var enforced: Bool? {
        switch self {
        case .on: true
        case .off, .absent: false
        case .unreadable: nil
        }
    }
}

protocol PowerManagementReading: AnyObject, Sendable {
    /// The kernel's SleepDisabled: what it enforces now.
    func sleepDisabled() -> SleepSetting
    /// The stored SleepDisabled: what powerd re-applies at every boot.
    func storedSleepDisabled() -> SleepSetting
    /// Nil on a Mac without a lid, or when it cannot be read.
    func lid() -> LidReading?
}

final class IORegistryPowerManagement: PowerManagementReading, @unchecked Sendable {
    func sleepDisabled() -> SleepSetting {
        guard let root = Self.rootDomain() else { return .unreadable }
        defer { IOObjectRelease(root) }
        guard let value = Self.property(root, "SleepDisabled") else { return .absent }
        return Self.setting(value as CFTypeRef)
    }

    /// pmset's own read (IOPMCopySystemPowerSettings), made through
    /// CFPreferences after a synchronize — which writes nothing here, since
    /// this process never sets a value — so a change pmset just made is seen.
    func storedSleepDisabled() -> SleepSetting {
        let domain = "com.apple.PowerManagement" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        guard let settings = CFPreferencesCopyValue("SystemPowerSettings" as CFString, domain,
                                                    kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        else { return .absent }
        guard CFGetTypeID(settings) == CFDictionaryGetTypeID(), let entries = settings as? [String: Any]
        else { return .unreadable }
        guard let value = entries["SleepDisabled"] else { return .absent }
        return Self.setting(value as CFTypeRef)
    }

    /// A CFBoolean, and nothing that merely bridges to one.
    private static func setting(_ value: CFTypeRef) -> SleepSetting {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unreadable }
        return CFBooleanGetValue((value as! CFBoolean)) ? .on : .off
    }

    func lid() -> LidReading? {
        guard let root = Self.rootDomain() else { return nil }
        defer { IOObjectRelease(root) }
        guard let closed = Self.property(root, "AppleClamshellState") as? Bool else { return nil }
        let causesSleep = Self.property(root, "AppleClamshellCausesSleep") as? Bool ?? true
        return LidReading(closed: closed, causesSleep: causesSleep)
    }

    private static func rootDomain() -> io_registry_entry_t? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        return root == 0 ? nil : root
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

// MARK: - Power source

struct PowerSourceReading: Equatable, Sendable {
    /// Running on the power adapter. False when it cannot be told.
    var onAC: Bool
    /// The internal battery's charge, 0…100; nil without one, or unreadable.
    var batteryPercent: Int?
    var lowPowerMode: Bool
    /// The battery is taking charge. False when it cannot be told — and on
    /// an adapter too weak for the load, which says "AC Power" while the
    /// battery runs down.
    var charging = false
}

protocol PowerSourceReader: AnyObject, Sendable {
    func read() -> PowerSourceReading
}

final class IOKitPowerSource: PowerSourceReader, @unchecked Sendable {
    func read() -> PowerSourceReading {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSourceReading(onAC: false, batteryPercent: nil, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var percent: Int?
        var charging = false
        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                    description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                    let current = description[kIOPSCurrentCapacityKey] as? Int,
                    let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
                else { continue }
                percent = max(0, min(100, current * 100 / maximum))
                charging = description[kIOPSIsChargingKey] as? Bool ?? false
                break
            }
        }
        return PowerSourceReading(onAC: providing == kIOPMACPowerKey, batteryPercent: percent,
                                  lowPowerMode: lowPower, charging: charging)
    }
}

// MARK: - Temperature

/// The hotter of processor and graphics, for the heat cut-off: the
/// kernel's own thermal-emergency sleep is off while SleepDisabled is set.
protocol ChipTemperatureReading: AnyObject, Sendable {
    func hottest() -> Double?
}

/// LocalNookSMC's read-only reader, opened on first use — on the sleep
/// hold's queue, the only one that reads it — and kept. A Mac whose sensor
/// controller will not open reads nil, and no hold is taken.
final class SMCChipTemperature: ChipTemperatureReading, @unchecked Sendable {
    private var reader: ThermalReader?
    private var opened = false

    func hottest() -> Double? {
        if !opened {
            opened = true
            reader = SMCReader().map {
                SMCFanHardware.watchdogReader(source: $0, brandString: ThermalCatalog.currentBrandString())
            }
        }
        return reader?.read().hottest
    }
}

// MARK: - Sleep

protocol SystemSleeping: AnyObject, Sendable {
    /// Asks the Mac to sleep now. True when the kernel accepted.
    func sleepNow() -> Bool
}

final class PowerManagerSleep: SystemSleeping, @unchecked Sendable {
    func sleepNow() -> Bool {
        guard HelperProcess.mayChangeSystem else { return false }
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return false }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }
}

// MARK: - The record

/// The file that says LocalNook set SleepDisabled. Used from the sleep
/// hold's queue only.
protocol SleepHoldRecording: AnyObject {
    /// A record this helper may trust is there.
    func exists() -> Bool
    /// Only where nothing exists yet.
    func create() -> Bool
    /// True once none is left.
    func remove() -> Bool
}

/// Root's, private, regular and singly linked, opened without following
/// links — the fan marker's rules — in /Library/PrivilegedHelperTools,
/// which a boot does not clear. Anything at the path that is not such a
/// file is not trusted as LocalNook's, and is left alone.
final class SleepHoldRecordFile: SleepHoldRecording {
    private let path: String
    /// Root in the helper; the self-test's own uid on a temporary file.
    private let ownerUID: uid_t

    init(path: String = FanHelperIdentity.sleepHoldRecordPath, ownerUID: uid_t = 0) {
        self.path = path
        self.ownerUID = ownerUID
    }

    static let contents = "v1 LocalNook set SleepDisabled\n"

    func exists() -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return isSecure(info)
    }

    /// On the disk itself before pmset 1 runs: F_FULLFSYNC, since a plain
    /// fsync on macOS leaves it in the drive's cache, and then the folder,
    /// so its name survives a power cut too. The record is what undoes a
    /// SleepDisabled that a lost power would otherwise leave for ever.
    func create() -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        let bytes = Array(Self.contents.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        var info = stat()
        let secure = fstat(descriptor, &info) == 0 && isSecure(info)
        let synced = Self.flush(descriptor)
        close(descriptor)
        guard written == bytes.count, synced, secure, syncFolder() else {
            _ = unlink(path)
            return false
        }
        return true
    }

    func remove() -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        guard isSecure(info) else { return false }
        guard unlink(path) == 0 else { return false }
        // Best effort: a removal a power cut undoes only makes the next
        // start run pmset 0 once more.
        _ = syncFolder()
        return true
    }

    /// To the medium: F_FULLFSYNC where the file system has it, else fsync.
    private static func flush(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }

    /// The folder holding the record, flushed so its entry is on disk.
    private func syncFolder() -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        let descriptor = open(folder.isEmpty ? "." : folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return Self.flush(descriptor)
    }

    private func isSecure(_ info: stat) -> Bool {
        info.st_uid == ownerUID && (info.st_mode & S_IFMT) == S_IFREG
            && (info.st_mode & mode_t(0o077)) == 0 && info.st_nlink == 1
    }
}
