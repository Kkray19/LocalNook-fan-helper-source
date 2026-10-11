//
//  ThermalCatalog.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  Which of the controller's two thousand keys are the processor, the
//  graphics, the battery and the fans, and what one number each of them
//  should show.
//
//  ── The generation maps, and why one is not trusted blindly ────────────────
//
//  Utilities carry per-chip lists of "the CPU core sensors" (Vorssaint's
//  come from Stats: MIT, Copyright (c) 2019 Serhiy Mytrovtsiy; its notice is
//  in LICENSES/MIT-Stats.txt, which goes with this file wherever it is
//  published). On this M3 the M3 list is wrong: none of its twelve
//  `Tf` performance-core keys exist, and the three keys of it that do are
//  all efficiency-cluster sensors — so a utility trusting the list shows
//  the *coolest* cluster, about 88 °C, while the performance cores sit at
//  95–108 °C. Key names are also shared across generations (every key of
//  the M1 list exists on this M3), so a list only helps when it is the
//  right one. The rule here: use the chip's list only if at least half of
//  it exists on this Mac *and* at least one of the keys present is a
//  performance-core key. Otherwise take every processor sensor. That keeps
//  the list's answer wherever it matches and fixes the one case observed
//  failing, which on this M3 lands on the true hottest reading.
//
//  ── The maximum, never an average ──────────────────────────────────────────
//
//  The processor keys come in fixed-offset pairs and triples (the second of
//  a pair is exactly the first plus 10.1 °C), so any mean is a mean of
//  bookkeeping, not of silicon. The hottest reading is the one that decides
//  throttling and fan speed, so it is the one shown.
//
//  ── Cost ───────────────────────────────────────────────────────────────────
//
//  Discovery walks every index once — about 2,000 calls, 200 ms — and asks
//  for a key's size and type only when its *name* is one of ours, so the
//  expensive half of the walk is skipped for 95% of keys. It runs lazily,
//  on the first sample, never on the main thread, and again only if every
//  cached key stops answering. After that a sample is about 84 reads,
//  8–20 ms of kernel time on a utility queue, taken only while a view is
//  showing the result.
//

import Darwin
import Foundation

// MARK: - What a sample yields

/// One fan, as the controller reports it. Speeds in rpm.
public struct FanReading: Sendable, Equatable, Codable {
    public var index: Int
    /// Actual speed now.
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double
    /// What the controller is steering towards, when it says.
    public var target: Double?
    /// 0 or 3 is the firmware's own control; 1 is manual — something has
    /// taken the fan over. Nil when the Mac has no readable mode key.
    public var mode: UInt8?

    public var isAutomatic: Bool { mode == nil || mode == 0 || mode == 3 }

    public init(index: Int, rpm: Double, minimum: Double, maximum: Double,
                target: Double? = nil, mode: UInt8? = nil) {
        self.index = index
        self.rpm = rpm
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.mode = mode
    }
}

/// Everything a sample yields, in °C. Each figure is absent, not zero, when
/// the Mac has no plausible reading for it.
public struct ThermalSnapshot: Sendable, Equatable {
    /// The hottest processor reading.
    public var cpu: Double?
    /// The hottest performance-cluster (`Tp`) and efficiency-cluster (`Te`)
    /// readings, given only when both exist.
    public var cpuPerformance: Double?
    public var cpuEfficiency: Double?
    public var gpu: Double?
    /// From the controller's battery sensors. The app prefers the public
    /// AppleSmartBattery reading when the Mac publishes one.
    public var battery: Double?
    public var fans: [FanReading]
    /// Seconds on ThermalClock: monotonic, counting sleep. Only meaningful
    /// against another snapshot's `observedAt`.
    public var observedAt: TimeInterval

    public init(cpu: Double? = nil, cpuPerformance: Double? = nil, cpuEfficiency: Double? = nil,
                gpu: Double? = nil, battery: Double? = nil, fans: [FanReading] = [],
                observedAt: TimeInterval = 0) {
        self.cpu = cpu
        self.cpuPerformance = cpuPerformance
        self.cpuEfficiency = cpuEfficiency
        self.gpu = gpu
        self.battery = battery
        self.fans = fans
        self.observedAt = observedAt
    }

    /// The hotter of processor and graphics: what a fan curve follows.
    public var hottest: Double? {
        switch (cpu, gpu) {
        case let (cpu?, gpu?): max(cpu, gpu)
        case let (cpu?, nil): cpu
        case let (nil, gpu?): gpu
        case (nil, nil): nil
        }
    }

    /// True when the sample found nothing at all to show.
    public var isEmpty: Bool {
        cpu == nil && gpu == nil && battery == nil && fans.isEmpty
    }
}

/// A clock for sample ages: monotonic, and counting sleep, so a reading
/// from before the lid closed is correctly old afterwards.
public enum ThermalClock {
    public static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

// MARK: - Classification

/// What a temperature key measures, by its name.
public enum ThermalKeyClass: String, Sendable, CaseIterable, Codable {
    /// `Tp*`, taken to be the performance cluster (Stats', macmon's and
    /// Vorssaint's reading; `TCMz`, the controller's own maximum, equals the
    /// hottest of them on an M3).
    case performance
    /// `Te*`, the efficiency cluster.
    case efficiency
    /// `Tf0*`/`Tf4*`, which Stats lists as M3 Pro/Max performance cores. Only
    /// on the M3 generation, and unverified here: this M3 has none.
    case cpuOther
    /// `Tg*`.
    case gpu
    /// `TB0T`…`TB9T`, `flt `.
    case battery
    /// `TG0B`…`TG9B`, `ioft`: the same gas-gauge readings in another type,
    /// used only when no `TB*T` answers.
    case batteryFallback

    public var isProcessor: Bool { self == .performance || self == .efficiency || self == .cpuOther }
}

public enum ThermalCatalog {
    /// Chip sensors: a reading outside this is a placeholder (0, -1.5) or a
    /// fault, never a temperature.
    public static let chipRange: Range<Double> = 10..<125

    public static func isPlausibleChip(_ value: Double) -> Bool {
        value.isFinite && chipRange.contains(value)
    }

    /// Battery sensors: open at both ends — a battery at 90 °C is a sensor
    /// fault, and one at or below 1 °C is an unpopulated key.
    public static func isPlausibleBattery(_ value: Double) -> Bool {
        value.isFinite && value > 1 && value < 90
    }

    /// The chip generation from `machdep.cpu.brand_string`: 3 for "Apple M3",
    /// "Apple M3 Pro" or "Apple M3 Max"; nil for anything else, including a
    /// generation no map exists for.
    public static func generation(brandString: String?) -> Int? {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard brand.hasPrefix("Apple M") else { return nil }
        let rest = brand.dropFirst("Apple M".count)
        guard let first = rest.first, let generation = first.wholeNumberValue,
              (1...5).contains(generation)
        else { return nil }
        let after = rest.dropFirst()
        guard after.isEmpty || after.first == " " else { return nil }
        return generation
    }

    /// This Mac's brand string, or nil when sysctl will not say.
    public static func currentBrandString() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0
        else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Vorssaint's per-generation core sensors (from Stats), unchanged.
    public static func coreMap(generation: Int?) -> Set<String>? {
        switch generation {
        case 1: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case 2: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D",
                 "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case 3: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
                 "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case 4: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D",
                 "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case 5: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U",
                 "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default: nil
        }
    }

    /// The chip's map, cut to the keys this Mac has — or nil when the map
    /// fails the rule in the header (under half present, or no
    /// performance-core key among those present) and every processor key
    /// should be used instead.
    public static func usableCoreMap(generation: Int?, available: Set<String>) -> Set<String>? {
        guard let map = coreMap(generation: generation) else { return nil }
        let present = map.intersection(available)
        guard present.count * 2 >= map.count,
              present.contains(where: { $0.hasPrefix("Tp") || $0.hasPrefix("Tf") })
        else { return nil }
        return present
    }

    /// What `name` measures, or nil when it is not a key this app reads.
    /// Decided from the name alone, so discovery can skip the key-info call
    /// for everything else.
    public static func classify(_ name: String, generation: Int?) -> ThermalKeyClass? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes[0] == UInt8(ascii: "T") else { return nil }
        let isDigit = { (byte: UInt8) in (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
        switch bytes[1] {
        case UInt8(ascii: "p"): return .performance
        case UInt8(ascii: "e"): return .efficiency
        case UInt8(ascii: "g"): return .gpu
        case UInt8(ascii: "f"):
            guard generation == 3,
                  bytes[2] == UInt8(ascii: "0") || bytes[2] == UInt8(ascii: "4")
            else { return nil }
            return .cpuOther
        case UInt8(ascii: "B"):
            return isDigit(bytes[2]) && bytes[3] == UInt8(ascii: "T") ? .battery : nil
        case UInt8(ascii: "G"):
            return isDigit(bytes[2]) && bytes[3] == UInt8(ascii: "B") ? .batteryFallback : nil
        default:
            return nil
        }
    }

    /// Whether a key of `keyClass` has the type it must have to be read as
    /// a temperature: `flt ` of 4 bytes, or `ioft` of 8 for the fallback.
    public static func accepts(_ key: SMCKey, as keyClass: ThermalKeyClass) -> Bool {
        switch keyClass {
        case .batteryFallback: key.type == "ioft" && key.size == 8
        default: key.type == "flt " && key.size == 4
        }
    }

    /// `FNum`, or a per-fan key discovery keeps: actual, minimum, maximum,
    /// target and both spellings of the mode key.
    public static func isFanKeyName(_ name: String) -> Bool {
        if name == "FNum" { return true }
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes[0] == UInt8(ascii: "F"),
              (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[1])
        else { return false }
        return ["Ac", "Mn", "Mx", "Tg", "md", "Md"].contains(String(decoding: bytes[2...], as: UTF8.self))
    }

    // MARK: Selection

    /// The processor figures from `readings` (name → °C, anything the reader
    /// got back). Implausible readings are dropped first. With a usable map
    /// the mapped readings decide, falling back to every processor reading
    /// only when none of the mapped ones is plausible; the performance and
    /// efficiency maxima come from the same set, so they never disagree with
    /// the headline figure.
    public static func selectCPU(readings: [String: Double], coreMap: Set<String>?)
        -> (cpu: Double?, performance: Double?, efficiency: Double?)
    {
        let plausible = readings.filter { isPlausibleChip($0.value) }
        var used = plausible
        if let coreMap {
            let mapped = plausible.filter { coreMap.contains($0.key) }
            if !mapped.isEmpty { used = mapped }
        }
        let performance = used.filter { $0.key.hasPrefix("Tp") }.values.max()
        let efficiency = used.filter { $0.key.hasPrefix("Te") }.values.max()
        let bothClusters = performance != nil && efficiency != nil
        return (used.values.max(),
                bothClusters ? performance : nil,
                bothClusters ? efficiency : nil)
    }

    /// The hottest plausible chip reading, or nil.
    public static func hottestChip(_ values: [Double]) -> Double? {
        values.filter(isPlausibleChip).max()
    }

    /// The warmest plausible `TB*T` reading, or the fallback's when no
    /// primary key answers plausibly.
    public static func selectBattery(primary: [Double], fallback: [Double]) -> Double? {
        primary.filter(isPlausibleBattery).max() ?? fallback.filter(isPlausibleBattery).max()
    }

    // MARK: Fans

    /// One fan from its raw values, or nil when the reading cannot be
    /// trusted: an actual speed outside 0…20,000 rpm, or bounds that are not
    /// 0 ≤ minimum < maximum ≤ 20,000. A target outside that range is
    /// dropped rather than failing the fan; so is a mode that is not a byte.
    public static func fanReading(index: Int, actual: Double?, minimum: Double?, maximum: Double?,
                                  target: Double?, mode: Double?) -> FanReading? {
        guard let actual, FanLimits.isValidRPM(actual),
              let minimum, let maximum, FanLimits.validBounds(minimum: minimum, maximum: maximum)
        else { return nil }
        let target = target.flatMap { FanLimits.isValidRPM($0) ? $0 : nil }
        let mode = mode.flatMap { value -> UInt8? in
            guard value.isFinite, value >= 0, value <= 255, value == value.rounded() else { return nil }
            return UInt8(value)
        }
        return FanReading(index: index, rpm: actual, minimum: minimum, maximum: maximum,
                          target: target, mode: mode)
    }

    /// Every fan or none: one fan that cannot be read makes the whole
    /// sample's fan figures unusable, as in Vorssaint, rather than showing a
    /// two-fan Mac as a one-fan Mac.
    public static func validatedFans(_ fans: [FanReading?]) -> [FanReading] {
        guard !fans.isEmpty, fans.count <= FanLimits.maximumFans else { return [] }
        let valid = fans.compactMap { $0 }
        return valid.count == fans.count ? valid : []
    }

    /// The mode key to use for a fan: `F<n>md` when the Mac has one, else
    /// `F<n>Md`; either must be exactly one byte.
    public static func modeKey(lowercase: SMCKey?, uppercase: SMCKey?) -> SMCKey? {
        if let lowercase, lowercase.size == 1 { return lowercase }
        if let uppercase, uppercase.size == 1 { return uppercase }
        return nil
    }

    // MARK: Discovery

    /// The one index walk. Names are checked before any key-info call; a
    /// key is kept only when its type is the one its class must have.
    public static func discover(using smc: any SMCKeyReading, generation: Int?) -> ThermalKeySet {
        var set = ThermalKeySet(generation: generation)
        // An M3 enumerates 2,088. Anything wildly beyond that is a count
        // gone wrong, and walking it would be minutes of kernel calls.
        let count = min(smc.keyCount(), 20_000)
        var fanKeys: [String: SMCKey] = [:]
        for index in 0..<max(0, count) {
            set.walkedIndices += 1
            guard let code = smc.key(at: index) else { continue }
            let name = SMCCodec.fourCCString(code)
            let keyClass = classify(name, generation: generation)
            guard keyClass != nil || isFanKeyName(name) else { continue }
            set.infoCalls += 1
            guard let key = smc.info(code) else { continue }
            if let keyClass {
                if accepts(key, as: keyClass) { set.chips[keyClass, default: []].append(key) }
            } else {
                fanKeys[name] = key
            }
        }

        let processorNames = Set(ThermalKeyClass.allCases.filter(\.isProcessor)
            .flatMap { set.keys($0) }.map(\.name))
        set.coreMap = usableCoreMap(generation: generation, available: processorNames)

        if let countKey = fanKeys["FNum"], let fanCount = FanLimits.fanCount(from: smc.value(countKey)) {
            var fans: [FanKeys] = []
            for index in 0..<fanCount {
                guard let actual = fanKeys["F\(index)Ac"],
                      let minimum = fanKeys["F\(index)Mn"],
                      let maximum = fanKeys["F\(index)Mx"]
                else { fans = []; break }
                fans.append(FanKeys(index: index, actual: actual, minimum: minimum, maximum: maximum,
                                    target: fanKeys["F\(index)Tg"],
                                    mode: modeKey(lowercase: fanKeys["F\(index)md"],
                                                  uppercase: fanKeys["F\(index)Md"])))
            }
            set.fans = fans
        }
        return set
    }
}

/// The keys one discovery found.
public struct ThermalKeySet: Sendable, Equatable {
    public var generation: Int?
    public var chips: [ThermalKeyClass: [SMCKey]] = [:]
    /// The chip's core map, cut to this Mac, when it passed the rule in
    /// ThermalCatalog's header; nil means every processor key is used.
    public var coreMap: Set<String>?
    public var fans: [FanKeys] = []
    /// What the walk cost: indices visited, and key-info calls made.
    public var walkedIndices = 0
    public var infoCalls = 0

    public init(generation: Int?) {
        self.generation = generation
    }

    public func keys(_ keyClass: ThermalKeyClass) -> [SMCKey] { chips[keyClass] ?? [] }

    public var isEmpty: Bool { chips.values.allSatisfy(\.isEmpty) && fans.isEmpty }

    /// Every key a sample reads, for "did any of them answer".
    public var keyCount: Int {
        chips.values.reduce(0) { $0 + $1.count }
            + fans.reduce(0) { $0 + 3 + ($1.target == nil ? 0 : 1) + ($1.mode == nil ? 0 : 1) }
    }
}

/// One fan's keys.
public struct FanKeys: Sendable, Equatable {
    public var index: Int
    public var actual: SMCKey
    public var minimum: SMCKey
    public var maximum: SMCKey
    public var target: SMCKey?
    public var mode: SMCKey?

    public init(index: Int, actual: SMCKey, minimum: SMCKey, maximum: SMCKey,
                target: SMCKey?, mode: SMCKey?) {
        self.index = index
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.mode = mode
    }
}

// MARK: - Holding a value through a missed read

/// Keeps the last good value through a few missed reads, so one busy
/// controller response does not blank a figure for a tick.
///
/// Held for at most `maxMisses` consecutive misses and at most
/// max(12 s, 2.2 × the sampling interval) since the last real read, as in
/// Vorssaint. The interval is the cadence samples are *meant* to arrive at,
/// not the time since the last one: after the nook has been closed for ten
/// minutes, a reading from before it closed is ten minutes old, and a miss
/// must not bring it back. The age only moves on a real read.
public struct ThermalStabilizer<Value: Sendable & Equatable>: Sendable {
    public let maxMisses: Int
    private var held: Value?
    private var updatedAt: TimeInterval = 0
    private var misses = 0

    public init(maxMisses: Int = 4) {
        self.maxMisses = maxMisses
    }

    public static func maxAge(interval: TimeInterval) -> TimeInterval {
        max(12, 2.2 * max(0, interval))
    }

    public mutating func update(_ reading: Value?, now: TimeInterval, interval: TimeInterval) -> Value? {
        if let reading {
            held = reading
            updatedAt = now
            misses = 0
            return reading
        }
        guard let value = held else { return nil }
        misses += 1
        if misses <= maxMisses, now - updatedAt <= Self.maxAge(interval: interval) { return value }
        held = nil
        misses = 0
        return nil
    }
}

// MARK: - Reading

/// What one sample cost and found. For the probe and the self-test; the
/// app shows none of it.
public struct ThermalDiagnostics: Sendable, Equatable {
    public var generation: Int?
    public var usesCoreMap = false
    public var counts: [ThermalKeyClass: Int] = [:]
    public var fanCount = 0
    /// Walks done by this reader so far; 1 after the first sample on a
    /// healthy Mac, and it should stay 1.
    public var discoveries = 0
    public var walkedIndices = 0
    public var infoCalls = 0
    /// Set on the sample that walked.
    public var discoverySeconds: Double?
    public var sampleSeconds: Double = 0
    public var readsAttempted = 0
    public var readsSucceeded = 0

    public init() {}
}

/// Discovery, reads and stabilizing, synchronously. Not thread-safe: one
/// serial queue at a time, never the main one. ThermalSampler wraps one in
/// its own queue; the fan helper uses one on its controller's. (Since
/// 2026-10-09 this library is the helper's only; the app has its own reader
/// in LocalNookSensors.)
public final class ThermalReader: @unchecked Sendable {
    private let smc: any SMCKeyReading
    public let generation: Int?
    /// The cadence samples are meant to arrive at; see ThermalStabilizer.
    public let interval: TimeInterval
    /// False for a reader that wants the chips alone — the fan helper's
    /// watchdog, which reads the fans through its writer and uses only
    /// `hottest`. Its snapshots then carry no battery and no fans.
    public let readsBatteryAndFans: Bool
    private let clock: @Sendable () -> TimeInterval
    /// Once the cached keys have all failed, or a walk found nothing, the
    /// next walk waits this long: a Mac whose controller has stopped
    /// answering must not be walked every tick.
    public static let rediscoveryInterval: TimeInterval = 60

    private var keys: ThermalKeySet?
    private var nextDiscoveryAt: TimeInterval = -.infinity
    private var discoveries = 0
    private var cpu = ThermalStabilizer<Double>()
    private var performance = ThermalStabilizer<Double>()
    private var efficiency = ThermalStabilizer<Double>()
    private var gpu = ThermalStabilizer<Double>()
    private var battery = ThermalStabilizer<Double>()
    private var fans = ThermalStabilizer<[FanReading]>(maxMisses: 3)

    /// Diagnostics of the latest `read()`.
    public private(set) var diagnostics = ThermalDiagnostics()

    /// The real controller, or nil when AppleSMC will not open.
    public convenience init?(interval: TimeInterval = 2) {
        guard let smc = SMCReader() else { return nil }
        self.init(source: smc, brandString: ThermalCatalog.currentBrandString(), interval: interval)
    }

    public init(source: any SMCKeyReading, brandString: String?, interval: TimeInterval = 2,
                readsBatteryAndFans: Bool = true,
                clock: @escaping @Sendable () -> TimeInterval = ThermalClock.now) {
        smc = source
        generation = ThermalCatalog.generation(brandString: brandString)
        self.interval = interval
        self.readsBatteryAndFans = readsBatteryAndFans
        self.clock = clock
    }

    /// One sample. Walks the key list first if it has not yet, which is the
    /// only slow part (≈200 ms, once).
    public func read() -> ThermalSnapshot {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = clock()
        var report = ThermalDiagnostics()
        report.generation = generation

        if keys == nil, started >= nextDiscoveryAt {
            let found = ThermalCatalog.discover(using: smc, generation: generation)
            discoveries += 1
            report.walkedIndices = found.walkedIndices
            report.infoCalls = found.infoCalls
            report.discoverySeconds = clock() - started
            nextDiscoveryAt = started + Self.rediscoveryInterval
            keys = found.isEmpty ? nil : found
        }

        var raw = ThermalSnapshot(observedAt: started)
        var attempted = 0, succeeded = 0
        func value(_ key: SMCKey) -> Double? {
            attempted += 1
            let result = smc.value(key)
            if result != nil { succeeded += 1 }
            return result
        }

        if let keys {
            let processor = ThermalKeyClass.allCases.filter(\.isProcessor).flatMap { keys.keys($0) }
            var readings: [String: Double] = [:]
            // With a usable map, the mapped keys first; the rest only when
            // none of those is plausible.
            let first = keys.coreMap.map { map in processor.filter { map.contains($0.name) } } ?? processor
            for key in first { readings[key.name] = value(key) }
            if keys.coreMap != nil, !readings.values.contains(where: ThermalCatalog.isPlausibleChip) {
                for key in processor where readings[key.name] == nil { readings[key.name] = value(key) }
            }
            let selected = ThermalCatalog.selectCPU(readings: readings, coreMap: keys.coreMap)
            raw.cpu = selected.cpu
            raw.cpuPerformance = selected.performance
            raw.cpuEfficiency = selected.efficiency
            raw.gpu = ThermalCatalog.hottestChip(keys.keys(.gpu).compactMap(value))
            if readsBatteryAndFans {
                let primary = keys.keys(.battery).compactMap(value)
                raw.battery = ThermalCatalog.selectBattery(
                    primary: primary,
                    fallback: primary.contains(where: ThermalCatalog.isPlausibleBattery)
                        ? [] : keys.keys(.batteryFallback).compactMap(value))
                raw.fans = ThermalCatalog.validatedFans(keys.fans.map { fan in
                    ThermalCatalog.fanReading(index: fan.index, actual: value(fan.actual),
                                              minimum: value(fan.minimum), maximum: value(fan.maximum),
                                              target: fan.target.flatMap(value),
                                              mode: fan.mode.flatMap(value))
                })
            }

            report.usesCoreMap = keys.coreMap != nil
            for keyClass in ThermalKeyClass.allCases { report.counts[keyClass] = keys.keys(keyClass).count }
            report.fanCount = keys.fans.count
            // Rediscover only when every cached key failed: one sensor going
            // quiet is not a reason to walk two thousand keys.
            if attempted > 0, succeeded == 0 { self.keys = nil }
        }

        var snapshot = ThermalSnapshot(observedAt: started)
        snapshot.cpu = cpu.update(raw.cpu, now: started, interval: interval)
        // The cluster figures are held only together, so a held one never
        // sits beside a fresh one from another sample.
        let clusters = raw.cpuPerformance != nil && raw.cpuEfficiency != nil
        let heldPerformance = performance.update(clusters ? raw.cpuPerformance : nil, now: started, interval: interval)
        let heldEfficiency = efficiency.update(clusters ? raw.cpuEfficiency : nil, now: started, interval: interval)
        if heldPerformance != nil, heldEfficiency != nil {
            snapshot.cpuPerformance = heldPerformance
            snapshot.cpuEfficiency = heldEfficiency
        }
        snapshot.gpu = gpu.update(raw.gpu, now: started, interval: interval)
        snapshot.battery = battery.update(raw.battery, now: started, interval: interval)
        snapshot.fans = fans.update(raw.fans.isEmpty ? nil : raw.fans, now: started, interval: interval) ?? []

        report.discoveries = discoveries
        report.readsAttempted = attempted
        report.readsSucceeded = succeeded
        report.sampleSeconds = clock() - started
        diagnostics = report
        return snapshot
    }
}

/// A ThermalReader on its own serial utility queue. The app's one entry
/// point: `sample` returns at once, and the completion runs on that queue,
/// never the main thread — the caller hops to main to publish.
public final class ThermalSampler: @unchecked Sendable {
    private let reader: ThermalReader
    private let queue = DispatchQueue(label: "com.localnook.app.thermals", qos: .utility)

    /// The real controller, or nil when AppleSMC will not open. `interval`
    /// is how often the caller means to sample.
    public convenience init?(interval: TimeInterval = 2) {
        guard let reader = ThermalReader(interval: interval) else { return nil }
        self.init(reader: reader)
    }

    public init(reader: ThermalReader) {
        self.reader = reader
    }

    public func sample(completion: @escaping @Sendable (ThermalSnapshot) -> Void) {
        queue.async { [reader] in completion(reader.read()) }
    }

    public func sampleWithDiagnostics(
        completion: @escaping @Sendable (ThermalSnapshot, ThermalDiagnostics) -> Void
    ) {
        queue.async { [reader] in
            let snapshot = reader.read()
            completion(snapshot, reader.diagnostics)
        }
    }
}
