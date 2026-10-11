//
//  LaunchdPlistCheck.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  The helper's launchd job, exactly — so a plist nobody meant cannot be
//  installed as root.
//
//  The template ships in the app bundle (Contents/Resources), and the bundle
//  belongs to the user, so anything running as the user could rewrite it
//  before the one administrator prompt copies it into /Library/LaunchDaemons.
//  A launchd job runs whatever its plist says, as root: another Program,
//  arguments, an output path to clobber. The install script therefore copies
//  the plist into a root-owned place first and then asks this — the
//  helper already copied beside it and signature-checked — whether the copy
//  is the job below, key for key. Anything else and the install stops.
//
//  The release build asks the same of the template it ships, so this and
//  Resources/com.localnook.app.fan-helper.plist cannot drift apart.
//

import Foundation
import LocalNookSMC

enum LaunchdPlistCheck {
    /// The job. KeepAlive relaunches the helper after an unsuccessful exit,
    /// and whenever the fans' marker or the sleep hold's record exists — a
    /// helper that died holding the fans, or the Mac awake with its lid
    /// closed, comes back to undo it. RunAtLoad (said outright since
    /// revision 3; KeepAlive implied it before, launchd.plist(5)) starts it
    /// once when the job is loaded: at install and at every boot, which is
    /// when a record left by a Mac that lost power while holding is found —
    /// SleepDisabled survives a boot, so the record does too. That run does
    /// its launch recovery and, with nobody connected and nothing to undo,
    /// exits 0 after the ten second idle timer; SuccessfulExit false keeps
    /// it from being started again. (Not at once: a message to its Mach
    /// service may be what started it, and leaving before the listener
    /// checks in would only make launchd start it again.) Otherwise it is
    /// started by such a message, or by the marker or the record.
    static var expected: NSDictionary {
        let job: [String: Any] = [
            "Label": FanHelperIdentity.label,
            "Program": FanHelperIdentity.installedBinary,
            "MachServices": [FanHelperIdentity.label: true],
            "AssociatedBundleIdentifiers": [FanHelperIdentity.appIdentifier],
            "RunAtLoad": true,
            "KeepAlive": [
                "SuccessfulExit": false,
                "PathState": [
                    FanHelperIdentity.markerPath: true,
                    FanHelperIdentity.sleepHoldRecordPath: true,
                ] as [String: Any],
            ] as [String: Any],
            "ThrottleInterval": 5,
            "ExitTimeOut": 30,
        ]
        return job as NSDictionary
    }

    /// Whether `data` is a property list equal to `expected`: every key, no
    /// more, each with the same value and type.
    static func matches(_ data: Data) -> Bool {
        guard data.count <= 64 * 1024,
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return false }
        return sameValue(parsed, expected)
    }

    /// Whether the file at `path` is the job.
    static func verify(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return matches(data)
    }

    /// `--verify-plist <path>`: 0 when the file is the job, 1 otherwise,
    /// saying so on standard error.
    static func run(path: String) -> Int32 {
        guard verify(path: path) else {
            FileHandle.standardError.write(Data("LocalNookFanHelper: \(path) is not the fan helper's launchd job\n".utf8))
            return 1
        }
        return 0
    }

    /// Equality that also compares types, so `true` is not `1`.
    private static func sameValue(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (l as NSDictionary, r as NSDictionary):
            guard l.count == r.count else { return false }
            for case let (key as String, value) in l {
                guard let other = r[key], sameValue(value, other) else { return false }
            }
            return true
        case let (l as NSArray, r as NSArray):
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { sameValue($0, $1) }
        case let (l as String, r as String):
            return l == r
        case let (l as NSNumber, r as NSNumber):
            return isBoolean(l) == isBoolean(r) && l == r
        default:
            return false
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
