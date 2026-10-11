//
//  HelperWire.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the MIT License. See LICENSES/MIT-LocalNookShared.txt.
//
//  What the app and the root fan helper agree on before either says anything
//  else: which protocol revision they speak, and how a message is written
//  down.
//
//  Every message crossing the helper's XPC connection is JSON in a `Data`,
//  never an archived class, so a root process has no object graph to
//  unarchive. It still decodes whatever an authenticated caller sends, so a
//  payload over the cap is refused before the decoder runs, in both
//  directions.
//
//  This file is the owner's own and is linked by both programs: the app and
//  the helper. Anything the two must agree on that is not a wire message
//  belongs here; the fans' messages and the helper's identity are each
//  side's own, and each side checks its own against HelperWireContract.swift.
//

import Foundation

public enum HelperWire {
    /// The protocol revision both sides report and check. Bumped whenever the
    /// helper's behavior or its messages change; the app refuses a helper
    /// reporting any other and offers "Update helper" instead of sending it
    /// anything. 3 added the sleep hold (2026-10-06).
    public static let revision = 3

    /// The largest request or reply either side will encode or decode.
    public static let maxPayloadBytes = 4096

    /// `value` as JSON with its keys in sorted order, or nil when it cannot
    /// be encoded or would not fit under the cap.
    public static func encode<Value: Encodable>(_ value: Value) -> Data? {
        // Sorted keys, otherwise the platform defaults: compact, `\/` for a
        // slash, UTF-8 for non-ASCII, whole doubles without a fraction, and
        // a non-finite double failing the encode.
        let writer = JSONEncoder()
        writer.outputFormatting = .sortedKeys
        let encoded: Data
        do {
            encoded = try writer.encode(value)
        } catch {
            return nil
        }
        return admitted(encoded)
    }

    /// `data` as a `Value`, or nil when it is empty, over the cap (checked
    /// before any decoding) or not JSON of that shape.
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        // The size decides first; the parser never sees a refused payload.
        guard let payload = admitted(data) else { return nil }
        return try? JSONDecoder().decode(type, from: payload)
    }

    /// The payload itself when the wire allows its size (1 through
    /// `maxPayloadBytes` bytes), else nil. JSON text is never zero bytes
    /// long, so for an encoder's output only the cap can refuse it.
    private static func admitted(_ payload: Data) -> Data? {
        (1...maxPayloadBytes) ~= payload.count ? payload : nil
    }
}
