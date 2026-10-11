//
//  FanHardware.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  What the fan controller needs from the Mac, as a protocol, so the state
//  machine can be run in the helper's self-test against a double — without
//  root and without touching a fan.
//
//  The real conformer joins three things over one read-only SMCReader: the
//  writer (SMCFanWriter, the only SMC writes), and LocalNookSMC's
//  ThermalReader for the temperature the watchdog and the Cool preset follow.
//  All of it is used from one queue at a time — the controller's, or its
//  work queue while a start runs, never both at once.
//

import Foundation
import LocalNookSMC

protocol FanHardware: AnyObject, Sendable {
    /// Every fan as the controller reports it now; empty when any cannot be
    /// read.
    func readFans() -> [FanReading]
    /// Whether another controller's unlock (`Ftst`) is set.
    func unlockEngaged() -> Bool
    /// The hotter of processor and graphics, or nil when neither answers.
    func readHottest() -> Double?
    /// Takes every fan to `level`. Nil on success; see SMCFanWriter.start.
    func start(level: Int) -> FanHelperError?
    /// A new level while holding the fans; false if a fan was taken back.
    func update(level: Int) -> Bool
    /// Still manual, still at the targets set.
    func verify() -> Bool
    /// Every fan back to automatic; true only once they all read so.
    func restore() -> Bool
    /// Another controller has set a fan this process took: out of automatic
    /// mode, but not at a target this process wrote. False when it has taken
    /// nothing — a relaunched helper cannot tell, and hands everything back.
    func heldByAnother() -> Bool
    /// Only the fans still as this process left them go back; another
    /// controller's, and `Ftst`, are not written. True once none reads as
    /// this process's.
    func yield() -> Bool
}

/// The Mac's own fans.
final class SMCFanHardware: FanHardware, @unchecked Sendable {
    private let writer: SMCFanWriter
    private let thermals: ThermalReader

    private init(writer: SMCFanWriter, thermals: ThermalReader) {
        self.writer = writer
        self.thermals = thermals
    }

    /// Opens AppleSMC and finds the fans, or says why it cannot.
    static func open() -> Result<any FanHardware, FanHelperError> {
        guard let reader = SMCReader() else { return .failure(.unsupportedHardware) }
        switch SMCFanWriter.connect(reader: reader) {
        case .failure(let error):
            return .failure(error)
        case .success(let writer):
            let thermals = watchdogReader(source: reader, brandString: ThermalCatalog.currentBrandString())
            return .success(SMCFanHardware(writer: writer, thermals: thermals))
        }
    }

    /// The watchdog's temperature reader: one read a second while the helper
    /// holds the fans, of the processor and graphics keys only. `hottest` is
    /// all the watchdog and Cool use, and the fans are read by the writer
    /// already, so the battery and fan keys would be reads for nothing.
    static func watchdogReader(source: any SMCKeyReading, brandString: String?) -> ThermalReader {
        ThermalReader(source: source, brandString: brandString, interval: 1, readsBatteryAndFans: false)
    }

    func readFans() -> [FanReading] { writer.readFans() }
    func unlockEngaged() -> Bool { writer.unlockEngaged() }
    func readHottest() -> Double? { thermals.read().hottest }
    func start(level: Int) -> FanHelperError? { writer.start(level: level) }
    func update(level: Int) -> Bool { writer.update(level: level) }
    func verify() -> Bool { writer.verify() }
    func restore() -> Bool { writer.restore() }
    func heldByAnother() -> Bool { writer.heldByAnother() }
    func yield() -> Bool { writer.yield() }
}
