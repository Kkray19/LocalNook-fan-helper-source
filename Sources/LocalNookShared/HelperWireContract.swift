//
//  HelperWireContract.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the MIT License. See LICENSES/MIT-LocalNookShared.txt.
//
//  The root fan helper's wire, revision 3, written down as text: the JSON
//  the helper writes and accepts for a fixed set of values, the five XPC
//  selectors, the Mach service name and the cap.
//
//  Why it is here. The app and the helper are two programs, and each holds
//  its own Swift types for the fans' messages (the helper's in
//  LocalNookSMC, the app's in LocalNookSensors); the two share no type, only
//  bytes. So each program's suite checks its own encoder and decoder
//  against the strings below: the app's in FanWireTests, the helper's in its
//  own `--self-test`. A change to either side that changes a byte fails that
//  side's suite; changing a string here fails the other's. The texts were
//  produced by the helper's encoder on 2026-10-08 (the app's FanWireTests
//  recorded them then) and are what installed revision-3 helpers speak.
//
//  Change nothing here without a new helper revision and the owner's
//  say-so, and then in both programs at once. When the helper's source is
//  published on its own, this file goes with it, unchanged: the two copies
//  must stay byte for byte the same.
//
//  Text only: no logic, no third-party code. The owner's own, linked by both
//  programs, like the rest of LocalNookShared.
//

public enum HelperWireContract {
    /// The protocol revision the texts below belong to.
    public static let revision = 3

    /// The largest request or reply either side encodes or decodes.
    public static let maxPayloadBytes = 4096

    /// The Mach service the helper's launchd job registers and the app
    /// connects to (it is also the job's label).
    public static let machServiceName = "com.localnook.app.fan-helper"

    /// The five methods the helper's XPC interface exports. NSXPC matches a
    /// method by its selector and argument types, so each program may
    /// declare the protocol under its own name, as long as these hold.
    public static let selectors: Set<String> = [
        "status:", "apply:reply:", "heartbeat:", "restore:", "sleepHold:reply:",
    ]

    // MARK: Fan requests (`FanRequest`)

    /// `FanRequest(mode: .automatic)`.
    public static let requestAutomatic = #"{"mode":{"automatic":{}}}"#
    /// `FanRequest(mode: .cool)`.
    public static let requestCool = #"{"mode":{"cool":{}}}"#
    /// `FanRequest(mode: .fixed(level: 50))`.
    public static let requestFixed50 = #"{"mode":{"fixed":{"level":50}}}"#
    /// `FanRequest(mode: .fixed(level: 100))`.
    public static let requestFixed100 = #"{"mode":{"fixed":{"level":100}}}"#

    // MARK: Fan status (`FanHelperStatus`, `FanReading`)

    /// `FanHelperStatus()`: four keys, sorted; nothing absent is written.
    public static let statusDefault = #"{"fans":[],"mode":{"automatic":{}},"owner":"system","revision":3}"#

    /// `FanHelperStatus(mode: .cool, owner: .thisConnection, fans: [FanReading(index: 0,
    /// rpm: 3100, minimum: 2317, maximum: 6800, target: 3200, mode: 1)], hottest: 71.5,
    /// lastHandBack: .tooHot)`.
    public static let statusHeld =
        #"{"fans":[{"index":0,"maximum":6800,"minimum":2317,"mode":1,"rpm":3100,"target":3200}],"#
        + #""hottest":71.5,"lastHandBack":"tooHot","mode":{"cool":{}},"owner":"thisConnection","revision":3}"#

    /// `FanReading(index: 1, rpm: 2400.5, minimum: 2317, maximum: 6800)`: no
    /// target and no mode, so four keys.
    public static let fanWithoutTargetOrMode = #"{"index":1,"maximum":6800,"minimum":2317,"rpm":2400.5}"#

    /// `FanHelperStatus(owner: .otherApp, otherController: "Vorssaint", error: .otherAppControls)`.
    public static let statusOtherApp = #"{"error":"otherAppControls","fans":[],"mode":{"automatic":{}},"#
        + #""otherController":"Vorssaint","owner":"otherApp","revision":3}"#

    /// `FanHelperStatus(mode: .fixed(level: 85), owner: .localNookOtherConnection)`.
    public static let statusFixed85 =
        #"{"fans":[],"mode":{"fixed":{"level":85}},"owner":"localNookOtherConnection","revision":3}"#

    // MARK: The words of the enumerations

    /// `FanOwner`'s raw values.
    public static let owners: Set<String> = ["system", "thisConnection", "localNookOtherConnection", "otherApp"]

    /// `FanHandBackReason`'s raw values.
    public static let handBackReasons: Set<String> = [
        "userChose", "appGone", "sleep", "tooHot", "thermalPressure", "systemTookOver",
        "otherAppTookOver", "sensorsLost", "helperRestarted", "helperStopping",
    ]

    /// `FanHelperError`'s raw values.
    public static let errors: Set<String> = [
        "noFans", "unsupportedHardware", "otherAppControls", "invalidRequest", "controlFailed",
        "notRoot", "asleep",
    ]

    // MARK: Texts the helper refuses

    /// Requests the helper's decoder refuses: a bare string for a mode, a
    /// level written as text, and a level that is not a multiple of 5 (the
    /// last decodes, and is then refused as not valid).
    public static let refusedRequests = [
        #"{"mode":"automatic"}"#,
        #"{"mode":{"fixed":{"level":"50"}}}"#,
        #"{"mode":{"fixed":{"level":52}}}"#,
    ]

    // MARK: The sleep hold (`SleepHoldRequest`, `SleepHoldStatus`)

    /// `SleepHoldRequest(action: .status)`.
    public static let sleepHoldStatusRequest = #"{"action":{"status":{}}}"#
    /// `SleepHoldRequest(action: .start(allowBattery: true))`.
    public static let sleepHoldStartOnBattery = #"{"action":{"start":{"allowBattery":true}}}"#
    /// `SleepHoldRequest(action: .release(.sessionEnded))`: the cause under `_0`.
    public static let sleepHoldRelease = #"{"action":{"release":{"_0":"sessionEnded"}}}"#
    /// `SleepHoldStatus()`.
    public static let sleepHoldStatusDefault =
        #"{"allowsBattery":false,"owner":"nobody","recovering":false,"revision":3}"#
}
