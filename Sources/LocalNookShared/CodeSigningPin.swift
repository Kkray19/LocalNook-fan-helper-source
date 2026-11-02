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
//  How the app and the root fan helper recognize each other, and what an
//  update must be signed with.
//
//  ── Pinned to this binary's own signer ─────────────────────────────────────
//
//  Vorssaint's helper accepts callers matching "anchor apple generic and
//  certificate leaf[subject.OU] = <team>", which needs a paid Developer ID.
//  Here each side requires the other's identifier *and* the signer of its
//  own binary, read from its own signature at run time (`ownSigner`), in
//  one of two forms:
//
//  - Any certificate Apple did not issue as Developer ID (the self-signed
//    "LocalNook Developer" one the betas use, or an Apple Development one):
//    the SHA-1 of that very leaf,
//
//        identifier "com.localnook.app" and certificate leaf = H"<sha1>"
//
//  - A Developer ID Application certificate: its team, in the designated
//    requirement codesign writes for every Developer ID app (`codesign -d
//    -r-` prints it for any of them),
//
//        identifier "com.localnook.app" and anchor apple generic
//        and certificate 1[field.1.2.840.113635.100.6.2.6] exists
//        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
//        and certificate leaf[subject.OU] = "<team>"
//
//    Apple issues a new Developer ID certificate at each renewal or after a
//    revocation, and the new leaf has a new hash. Pinning that hash would
//    make every installed copy refuse the next update and every installed
//    helper refuse the app (the launch review's SEC-004); the team stays.
//
//  A binary counts as Developer ID only when its own signature meets that
//  second form without the identifier: Apple's root, Apple's Developer ID
//  intermediate, a Developer ID Application leaf, and the team its signature
//  names. Anything else with a certificate is pinned by its leaf, so a
//  self-signed build asks for exactly what it always has. Nothing is
//  compiled in, so the two programs only trust each other when one signer
//  signed both. An ad-hoc build has no certificate at all, so `ownSigner`
//  is nil and fan control reports that it needs a signed build; it never
//  falls back to something weaker.
//
//  ── Validated before use ───────────────────────────────────────────────────
//
//  NSXPC traps on a requirement string it cannot parse, and a trap in the
//  root helper is a helper that died holding the fans. So the builders
//  accept only a plain identifier and exactly forty hex digits or a
//  ten-character team, and then ask Security to compile the result;
//  anything else is nil.
//

import CryptoKit
import Foundation
import Security

public enum CodeSigningPin {
    /// Who signed a binary, in the form the other side pins.
    public enum Signer: Equatable, Sendable {
        /// A certificate Apple did not issue as Developer ID: that very leaf,
        /// as lowercase hex SHA-1.
        case leaf(sha1: String)
        /// A Developer ID Application certificate: the team Apple issued it
        /// to.
        case developerID(team: String)
    }

    /// This process's own signer, or nil when it is ad-hoc signed, unsigned,
    /// or Security will not say.
    public static func ownSigner() -> Signer? {
        ownStaticCode().flatMap(signer(of:))
    }

    /// Who signed `code`, or nil when it is ad-hoc signed, unsigned, or
    /// Security will not say. Developer ID only when its signature proves it
    /// (`isDeveloperID`); a team named by any other certificate is not
    /// trusted as one, and that certificate is pinned by its leaf.
    public static func signer(of code: SecStaticCode) -> Signer? {
        guard let information = signingInformation(of: code) else { return nil }
        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
           isDeveloperID(code, team: team) {
            return .developerID(team: team)
        }
        return leafSHA1(in: information).map { .leaf(sha1: $0) }
    }

    /// Lowercase hex SHA-1 of the leaf certificate this process is signed
    /// with, or nil when it is ad-hoc signed, unsigned, or Security will not
    /// say. A Developer ID build has one too; what it pins is `ownSigner`.
    public static func ownLeafSHA1() -> String? {
        guard let code = ownStaticCode(), let information = signingInformation(of: code) else { return nil }
        return leafSHA1(in: information)
    }

    /// Lowercase hex SHA-1 of `data`.
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The requirement that `identifier`, signed by `signer`, meets: one of
    /// the two below, or nil when that one is.
    public static func requirement(identifier: String, signer: Signer) -> String? {
        switch signer {
        case .leaf(let sha1): requirement(identifier: identifier, leafSHA1: sha1)
        case .developerID(let team): requirement(identifier: identifier, developerIDTeam: team)
        }
    }

    /// `identifier "<identifier>" and certificate leaf = H"<leafSHA1>"`, or
    /// nil unless the identifier is a plain reverse-DNS name, the hash is
    /// exactly forty hex digits, and Security compiles the result.
    public static func requirement(identifier: String, leafSHA1: String) -> String? {
        guard isPlainIdentifier(identifier), isSHA1Hex(leafSHA1) else { return nil }
        return compiled("identifier \"\(identifier)\" and certificate leaf = H\"\(leafSHA1.lowercased())\"")
    }

    /// `identifier "<identifier>" and ` followed by `developerIDClause`, or
    /// nil unless the identifier is a plain reverse-DNS name, the team is
    /// one, and Security compiles the result.
    public static func requirement(identifier: String, developerIDTeam team: String) -> String? {
        guard isPlainIdentifier(identifier), let clause = developerIDClause(team: team) else { return nil }
        return compiled("identifier \"\(identifier)\" and \(clause)")
    }

    /// Signed under Apple's root by Apple's Developer ID intermediate
    /// (…6.2.6), with a Developer ID Application leaf (…6.1.13) issued to
    /// `team`: codesign's own designated requirement for such an app, less
    /// the identifier. Nil unless `team` is ten capital letters or digits.
    static func developerIDClause(team: String) -> String? {
        guard isTeamIdentifier(team) else { return nil }
        return "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Whether `code`'s own signature is Developer ID Application for
    /// `team`. Only the signature is checked, not every page and resource:
    /// the running binary's pages are the kernel's to check, and this only
    /// decides which form of pin it asks of the other side.
    static func isDeveloperID(_ code: SecStaticCode, team: String) -> Bool {
        guard let text = developerIDClause(team: team) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else { return false }
        let signatureOnly = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, signatureOnly, requirement) == errSecSuccess
    }

    private static func ownStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signingInformation(of code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess
        else { return nil }
        return information as? [String: Any]
    }

    private static func leafSHA1(in information: [String: Any]) -> String? {
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        return sha1Hex(SecCertificateCopyData(leaf) as Data)
    }

    /// `text` when Security compiles it, else nil.
    private static func compiled(_ text: String) -> String? {
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

    /// Exactly ten capital letters or digits, as Apple issues team
    /// identifiers: nothing that could close the quoted string.
    public static func isTeamIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 10 && bytes.allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        }
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
