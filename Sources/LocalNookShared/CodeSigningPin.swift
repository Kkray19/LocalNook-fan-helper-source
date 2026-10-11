//
//  CodeSigningPin.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the MIT License. See LICENSES/MIT-LocalNookShared.txt.
//
//  Moved from LocalNookSMC to LocalNookShared (GPL boundary, 2026-10-08):
//  the owner's own code, linked by the app and by the root helper, unchanged
//  but for this note.
//
//  How the app and the root fan helper recognize each other.
//
//  ── Pinned to the certificate, not to Apple ────────────────────────────────
//
//  Vorssaint's helper accepts callers matching "anchor apple generic and
//  certificate leaf[subject.OU] = <team>", which needs a paid Developer ID.
//  LocalNook is signed with a self-signed "LocalNook Developer" certificate
//  that has no team, so each side instead requires the other's identifier
//  *and* the SHA-1 of the very certificate it is signed with itself:
//
//      identifier "com.localnook.app" and certificate leaf = H"<sha1>"
//
//  Nothing is compiled in. Each binary reads its own leaf from its own
//  signature at run time, so the two only trust each other when one
//  certificate signed both. An ad-hoc build has no certificate at all, so
//  `ownLeafSHA1` is nil and fan control reports that it needs a signed
//  build; it never falls back to something weaker.
//
//  ── Validated before use ───────────────────────────────────────────────────
//
//  NSXPC traps on a requirement string it cannot parse, and a trap in the
//  root helper is a helper that died holding the fans. So the builder
//  accepts only a plain identifier and exactly forty hex digits, and then
//  asks Security to compile the result; anything else is nil.
//

import CryptoKit
import Foundation
import Security

public enum CodeSigningPin {
    /// Lowercase hex SHA-1 of the leaf certificate this process is signed
    /// with, or nil when it is ad-hoc signed, unsigned, or Security will not
    /// say.
    public static func ownLeafSHA1() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        return sha1Hex(SecCertificateCopyData(leaf) as Data)
    }

    /// Lowercase hex SHA-1 of `data`.
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `identifier "<identifier>" and certificate leaf = H"<leafSHA1>"`, or
    /// nil unless the identifier is a plain reverse-DNS name, the hash is
    /// exactly forty hex digits, and Security compiles the result.
    public static func requirement(identifier: String, leafSHA1: String) -> String? {
        guard isPlainIdentifier(identifier), isSHA1Hex(leafSHA1) else { return nil }
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(leafSHA1.lowercased())\""
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &compiled) == errSecSuccess,
              compiled != nil
        else { return nil }
        return text
    }

    /// Letters, digits, dots and hyphens, starting with a letter or digit —
    /// nothing that could close the quoted string and add a clause.
    public static func isPlainIdentifier(_ identifier: String) -> Bool {
        let bytes = Array(identifier.utf8)
        guard (1...255).contains(bytes.count) else { return false }
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        guard isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    public static func isSHA1Hex(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 40 && bytes.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        }
    }
}
