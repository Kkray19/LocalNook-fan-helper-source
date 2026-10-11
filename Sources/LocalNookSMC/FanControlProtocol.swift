//
//  FanControlProtocol.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  The contract between the app and its root fan helper, and the arithmetic
//  both sides must agree on.
//
//  ── JSON over Data, and small ──────────────────────────────────────────────
//
//  Every argument and reply crossing the XPC connection is JSON in a `Data`,
//  so there are no custom NSSecureCoding classes for a root process to
//  unarchive. The helper still decodes whatever an authenticated caller
//  sends, so the payload is capped before the decoder sees it (Vorssaint's
//  audit found its own uncapped), and every request is validated *after*
//  decoding, in the helper, whatever the app already checked.
//
//  ── No raw speeds ──────────────────────────────────────────────────────────
//
//  A request names a mode — Auto, a level in 5% steps, or the Cool preset —
//  never an rpm. The helper turns a level into a target between the fan's
//  own firmware minimum and maximum, so nothing a caller sends can stop a
//  fan or push it past its rating.
//
//  ── Cool ───────────────────────────────────────────────────────────────────
//
//  One built-in curve rather than an editor: the hotter of processor and
//  graphics drives it, from 0% at 45 °C to 100% at 85 °C, rounded *up* to
//  the next 5% so the fan errs towards cooling. It lowers only once the
//  temperature has fallen 2 °C below what the current level needs, so a
//  reading hovering on a boundary does not step the fan up and down every
//  second.
//

import Foundation
// The helper's sources import LocalNookSMC and nothing else, so what LocalNookShared
// holds (the code-signing pin, the sleep hold's messages, the wire) reaches them
// through here, and the helper's own files stay exactly as they were.
@_exported import LocalNookShared

// MARK: - Identity

public enum FanHelperIdentity {
    /// launchd label, Mach service name and signing identifier, all one.
    public static let label = "com.localnook.app.fan-helper"
    public static let appIdentifier = "com.localnook.app"
    public static let installedBinary = "/Library/PrivilegedHelperTools/com.localnook.app.fan-helper"
    public static let installedPlist = "/Library/LaunchDaemons/com.localnook.app.fan-helper.plist"
    public static let lockPath = "/var/run/localnook-fan-control.lock"
    public static let markerPath = "/var/run/localnook-fan-control.active"
    public static let vorssaintMarkerPath = "/var/run/vorssaint-fan-control.active"
    /// The sleep hold's record (SleepHoldController): written, root's and
    /// private, before the helper first sets SleepDisabled, and removed only
    /// once it reads 0 again. Beside the helper rather than in /var/run,
    /// which a boot clears — SleepDisabled survives one, so the record must
    /// too. launchd keeps the helper running while it exists.
    public static let sleepHoldRecordPath = "/Library/PrivilegedHelperTools/com.localnook.app.fan-helper.sleep-hold"
    /// Bumped whenever the helper's behavior or this protocol changes. The
    /// app refuses a helper reporting any other revision and offers
    /// "Update helper" instead of sending it anything.
    /// 2 (2026-09-26): the helper logs a mode change within a hold, and
    /// each step Cool takes, so the log alone says which level a hand-back
    /// ended.
    /// 3 (2026-10-06): the sleep hold ("Keep running with the lid closed"),
    /// its `sleepHold` call, its record and the job's RunAtLoad.
    /// The number itself lives in LocalNookShared, the owner's own module,
    /// because the app reads it too (GPL boundary, 2026-10-08).
    public static let revision = HelperWire.revision
    /// Largest request or reply either side will decode.
    public static let maxPayloadBytes = HelperWire.maxPayloadBytes
}

// MARK: - The XPC surface

/// Four calls for the fans, each replying with a JSON-encoded
/// FanHelperStatus, and one for the sleep hold (revision 3), replying with
/// a JSON-encoded SleepHoldStatus. A helper of an earlier revision has no
/// `sleepHold`: the app asks `status` first and sends it only to a helper
/// that reports this revision.
@objc public protocol FanHelperXPC {
    func status(_ reply: @escaping @Sendable (Data) -> Void)
    /// `request` is a JSON-encoded FanRequest.
    func apply(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// The lease: the owner calls this every 2 s while it holds the fans.
    func heartbeat(_ reply: @escaping @Sendable (Data) -> Void)
    /// Back to the firmware's own control, from any authenticated caller.
    func restore(_ reply: @escaping @Sendable (Data) -> Void)
    /// `request` is a JSON-encoded SleepHoldRequest (SleepHoldProtocol.swift).
    func sleepHold(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - Messages

public enum FanMode: Codable, Sendable, Equatable, Hashable {
    case automatic
    /// 0…100 in steps of 5; 100 is Max.
    case fixed(level: Int)
    case cool

    /// The choices the System page offers: Auto · Cool · 50% · Max.
    public static let choices: [FanMode] = [.automatic, .cool, .fixed(level: 50), .fixed(level: 100)]

    public var isValid: Bool {
        switch self {
        case .automatic, .cool: true
        case .fixed(let level): FanLimits.isValidLevel(level)
        }
    }
}

public struct FanRequest: Codable, Sendable, Equatable {
    public var mode: FanMode

    public init(mode: FanMode) {
        self.mode = mode
    }

    /// A request from the wire, or nil when it is over the payload cap, not
    /// a request, or asks for a mode that is not valid.
    public static func decode(_ data: Data) -> FanRequest? {
        guard let request = FanWire.decode(FanRequest.self, from: data), request.mode.isValid
        else { return nil }
        return request
    }
}

/// Who holds the fans, as the helper sees it from the asking connection.
public enum FanOwner: String, Codable, Sendable {
    /// The firmware's own control.
    case system
    case thisConnection
    /// Another LocalNook connection — a second copy, or one left from before
    /// a relaunch.
    case localNookOtherConnection
    /// Something that is not LocalNook has a fan out of automatic mode.
    case otherApp
}

/// Why the helper gave the fans back without being asked to.
///
/// `otherAppTookOver`: another controller set a fan the helper held, so the
/// helper let go of it without writing to it.
public enum FanHandBackReason: String, Codable, Sendable {
    case userChose, appGone, sleep, tooHot, thermalPressure, systemTookOver,
         otherAppTookOver, sensorsLost, helperRestarted, helperStopping
}

/// `asleep`: the Mac has announced sleep and has not fully woken since.
/// Fans taken then would be held through the sleep, so none are.
public enum FanHelperError: String, Codable, Sendable, Error {
    case noFans, unsupportedHardware, otherAppControls, invalidRequest, controlFailed, notRoot, asleep
}

public struct FanHelperStatus: Codable, Sendable, Equatable {
    public var revision: Int
    public var mode: FanMode
    public var owner: FanOwner
    public var fans: [FanReading]
    /// The hotter of processor and graphics, as the helper last read it.
    public var hottest: Double?
    /// "Vorssaint" when its marker file exists, "another app" otherwise when
    /// something else holds a fan; nil when nothing does.
    public var otherController: String?
    public var lastHandBack: FanHandBackReason?
    public var error: FanHelperError?

    public init(revision: Int = FanHelperIdentity.revision, mode: FanMode = .automatic,
                owner: FanOwner = .system, fans: [FanReading] = [], hottest: Double? = nil,
                otherController: String? = nil, lastHandBack: FanHandBackReason? = nil,
                error: FanHelperError? = nil) {
        self.revision = revision
        self.mode = mode
        self.owner = owner
        self.fans = fans
        self.hottest = hottest
        self.otherController = otherController
        self.lastHandBack = lastHandBack
        self.error = error
    }

    public static func decode(_ data: Data) -> FanHelperStatus? {
        FanWire.decode(FanHelperStatus.self, from: data)
    }
}

/// The wire format: JSON, capped at `FanHelperIdentity.maxPayloadBytes`. The
/// encoding itself is LocalNookShared's `HelperWire` (the app speaks it
/// too); this keeps the helper's own call sites as they were.
public enum FanWire {
    /// The JSON for `value`, or nil if it would exceed the cap.
    public static func encode<Value: Encodable>(_ value: Value) -> Data? {
        HelperWire.encode(value)
    }

    /// `data` decoded as `type`, or nil when it is empty, over the cap —
    /// checked before the decoder runs — or not valid JSON of that type.
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        HelperWire.decode(type, from: data)
    }
}

// MARK: - Limits and arithmetic

public enum FanLimits {
    public static let maximumFans = 8
    /// No Mac fan is rated anywhere near this; a reading above it is a fault.
    public static let maximumRPM = 20_000.0
    public static let levelStep = 5
    public static let levels = 0...100

    /// The heat line: a chip held at or above this for `tooHotSeconds`,
    /// with the fan below full speed, and the helper gives the fan back to
    /// macOS. Kept here, not in the helper, because the app says it out loud
    /// — Settings' guide and footer, the System page's hot color — and a
    /// second copy in the app could drift from what the helper does.
    public static let tooHotCelsius = 95.0
    public static let tooHotSeconds: TimeInterval = 5

    /// Mode 0, or 3, is the firmware in charge. Anything else is manual.
    public static func isAutomatic(mode: UInt8) -> Bool { mode == 0 || mode == 3 }

    /// `FNum` as a fan count: a whole number in 1…8, or nil.
    public static func fanCount(from value: Double?) -> Int? {
        guard let value, value.isFinite, value == value.rounded() else { return nil }
        let count = Int(value)
        return (1...maximumFans).contains(count) ? count : nil
    }

    public static func isValidRPM(_ rpm: Double) -> Bool {
        rpm.isFinite && rpm >= 0 && rpm <= maximumRPM
    }

    /// Firmware bounds worth trusting: 0 ≤ minimum < maximum ≤ 20,000.
    public static func validBounds(minimum: Double, maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum > minimum && maximum <= maximumRPM
    }

    public static func isValidLevel(_ level: Int) -> Bool {
        levels.contains(level) && level.isMultiple(of: levelStep)
    }

    /// The target for `level` percent between the fan's own bounds:
    /// min + (max − min) × level / 100, clamped to [min, max]. Nil when the
    /// bounds are not worth trusting. So 0% is the firmware minimum, never a
    /// stopped fan, and 100% is its rated maximum, never beyond.
    public static func targetRPM(level: Int, min minimum: Double, max maximum: Double) -> Double? {
        guard validBounds(minimum: minimum, maximum: maximum) else { return nil }
        let target = minimum + (maximum - minimum) * Double(level) / 100
        return Swift.min(maximum, Swift.max(minimum, target))
    }
}

public struct FanCurve: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var temperature: Double
        public var level: Int

        public init(temperature: Double, level: Int) {
            self.temperature = temperature
            self.level = level
        }
    }

    public let points: [Point]

    /// Lowering waits until the temperature is this far below what the
    /// current level needs.
    public static let hysteresis = 2.0

    /// The built-in "Cool" preset.
    public static let cool = FanCurve(uncheckedPoints: [
        Point(temperature: 45, level: 0),
        Point(temperature: 60, level: 35),
        Point(temperature: 75, level: 70),
        Point(temperature: 85, level: 100),
    ])

    /// A curve, or nil unless it has 2…8 points with temperatures strictly
    /// rising within 20…110 °C and valid levels that never fall.
    public init?(points: [Point]) {
        guard (2...8).contains(points.count) else { return nil }
        for (index, point) in points.enumerated() {
            guard point.temperature.isFinite, (20...110).contains(point.temperature),
                  FanLimits.isValidLevel(point.level)
            else { return nil }
            if index > 0 {
                let previous = points[index - 1]
                guard point.temperature > previous.temperature, point.level >= previous.level
                else { return nil }
            }
        }
        self.points = points
    }

    private init(uncheckedPoints: [Point]) {
        points = uncheckedPoints
    }

    /// The level for `temperature`: the first point's below the curve, the
    /// last one's above it, linear between, rounded up to the next 5%. Nil
    /// for a reading that is not a plausible chip temperature, so a lost
    /// sensor is never read as a cold one.
    public func level(at temperature: Double) -> Int? {
        guard ThermalCatalog.isPlausibleChip(temperature),
              let first = points.first, let last = points.last
        else { return nil }
        if temperature <= first.temperature { return first.level }
        if temperature >= last.temperature { return last.level }
        for index in 1..<points.count where temperature <= points[index].temperature {
            let lower = points[index - 1], upper = points[index]
            let progress = (temperature - lower.temperature) / (upper.temperature - lower.temperature)
            let raw = Double(lower.level) + Double(upper.level - lower.level) * progress
            let stepped = Int((raw / Double(FanLimits.levelStep) - 1e-9).rounded(.up)) * FanLimits.levelStep
            return Swift.min(FanLimits.levels.upperBound, Swift.max(FanLimits.levels.lowerBound, stepped))
        }
        return last.level
    }

    /// The level with hysteresis against `previous`: rising is immediate;
    /// falling takes the level the curve gives 2 °C warmer, so the fan only
    /// steps down once the temperature has really dropped.
    public func level(at temperature: Double, previous: Int?) -> Int? {
        guard let requested = level(at: temperature) else { return nil }
        guard let previous, requested < previous else { return requested }
        guard let held = level(at: temperature + Self.hysteresis) else { return requested }
        return Swift.min(previous, Swift.max(requested, held))
    }
}
