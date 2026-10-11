//
//  ElevatedWindowSpace.swift
//  LocalNook
//
//  ─────────────────────────────────────────────────────────────────────────
//  THIRD-PARTY / PRIVATE API — OPT-IN ONLY
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this file,
//  You can obtain one at http://mozilla.org/MPL/2.0/
//
//  Copyright (c) 2018, Aditya Vaidyam and Contributors
//  Upstream modification by Alexander, 2024-10-27.
//  Derived from the CGSSpace wrapper in Parrot (https://github.com/avaidyam/Parrot)
//  by way of boring.notch (https://github.com/TheBoredTeam/boring.notch),
//  whose copy of the file carries the same MPL-2.0 notice.
//  Credits: LocalNook's THIRD_PARTY_LICENSES.md (§ 2), or, where this file is
//  published on its own, the README.md beside it.
//  ─────────────────────────────────────────────────────────────────────────
//
//  WHY THIS EXISTS
//  A normal `NSWindow.level` cannot place a window above another app's
//  full-screen space. The private CoreGraphics "Spaces" API can. LocalNook
//  therefore keeps this behind the `notch.useElevatedSpace` setting, OFF by
//  default. With it off, none of these symbols are ever called and the app
//  behaves normally — it simply sits below full-screen apps.
//
//  RISK: these are unsupported symbols. If a future macOS removes them the
//  dynamic lookup below fails and LocalNook silently falls back to standard
//  window levels rather than crashing.
//
//  Keeping this wrapper here, and the brightness reader in
//  DisplayServicesBrightness.swift beside it, keeps the app's entire private-
//  API boundary in `Vendor/`, easy to find and audit. (Until 0.5.0 this file
//  also held a second wrapper, a SkyLight space for Face Unlock's lock-screen
//  status; it went with that feature.)
//

import AppKit

/// Wrapper around the private CoreGraphics Spaces API.
///
/// Every symbol is resolved through `dlsym` at construction time and cached, so
/// a missing symbol degrades to "unavailable" instead of a launch-time crash
/// from an unresolved `@_silgen_name` import.
///
/// Declared `nonisolated` because `deinit` must tear the space down without
/// hopping to the main actor — a leaked space would leave an invisible
/// always-on-top layer behind after quit.
nonisolated final class ElevatedWindowSpace {
    private typealias ConnectionID = UInt
    private typealias SpaceID = UInt64

    private typealias DefaultConnectionFn = @convention(c) () -> ConnectionID
    private typealias SpaceCreateFn = @convention(c) (ConnectionID, Int, CFDictionary?) -> SpaceID
    private typealias SpaceDestroyFn = @convention(c) (ConnectionID, SpaceID) -> Void
    private typealias SpaceSetLevelFn = @convention(c) (ConnectionID, SpaceID, Int) -> Void
    private typealias SpaceWindowsFn = @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private typealias SpaceVisibilityFn = @convention(c) (ConnectionID, CFArray) -> Void

    /// Resolves a symbol from the already-loaded process image.
    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private let connection: ConnectionID
    private let spaceID: SpaceID
    private let addWindows: SpaceWindowsFn?
    private let removeWindows: SpaceWindowsFn?
    private let hideSpaces: SpaceVisibilityFn?
    private let destroySpace: SpaceDestroyFn?

    /// Window numbers currently attached to the space.
    private var members: Set<Int> = []

    init?() {
        guard
            let defaultConnection = Self.symbol("_CGSDefaultConnection", as: DefaultConnectionFn.self),
            let spaceCreate = Self.symbol("CGSSpaceCreate", as: SpaceCreateFn.self),
            let setLevel = Self.symbol("CGSSpaceSetAbsoluteLevel", as: SpaceSetLevelFn.self),
            let show = Self.symbol("CGSShowSpaces", as: SpaceVisibilityFn.self)
        else {
            NSLog("[LocalNook] Elevated space unavailable — using standard window level.")
            return nil
        }

        let cid = defaultConnection()
        // The magic 0x1 keeps Finder from redrawing desktop icons onto the space.
        let sid = spaceCreate(cid, 0x1, nil)
        guard sid != 0 else {
            NSLog("[LocalNook] Elevated space creation failed — using standard window level.")
            return nil
        }

        connection = cid
        spaceID = sid
        addWindows = Self.symbol("CGSAddWindowsToSpaces", as: SpaceWindowsFn.self)
        removeWindows = Self.symbol("CGSRemoveWindowsFromSpaces", as: SpaceWindowsFn.self)
        hideSpaces = Self.symbol("CGSHideSpaces", as: SpaceVisibilityFn.self)
        destroySpace = Self.symbol("CGSSpaceDestroy", as: SpaceDestroyFn.self)

        setLevel(cid, sid, Int(Int32.max))
        show(cid, [sid] as CFArray)
    }

    deinit {
        hideSpaces?(connection, [spaceID] as CFArray)
        destroySpace?(connection, spaceID)
    }

    /// Takes a window *number* rather than an `NSWindow` so this nonisolated
    /// type never touches main-actor AppKit state.
    func add(windowNumber number: Int) {
        guard number != 0, members.insert(number).inserted else { return }
        addWindows?(connection, [number] as CFArray, [spaceID] as CFArray)
    }

    func remove(windowNumber number: Int) {
        guard members.remove(number) != nil else { return }
        removeWindows?(connection, [number] as CFArray, [spaceID] as CFArray)
    }
}
