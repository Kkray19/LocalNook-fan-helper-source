//
//  FanHelperService.swift
//  LocalNookFanHelper
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSES/GPL-3.0-or-later.txt.
//
//  Portions adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  commit e4f9432), Copyright (C) 2026 Vorssaint, GPL-3.0-or-later.
//  Modified for LocalNook by Krish Kowli, 2026.
//
//  The XPC side of the helper: one session per connection, and the listener
//  delegate that hands each connection its session.
//
//  Who may connect is decided before any of this runs. main.swift sets the
//  listener's code-signing requirement — `identifier "com.localnook.app"`
//  and the SHA-1 of the certificate the helper itself is signed with — and
//  NSXPC checks it against the caller's audit token, not its process ID.
//  The self-test drives these same classes through an anonymous listener,
//  where there is no requirement to set.
//
//  Each session has its own UUID, which is what "owner" means to both
//  controllers — the fans' and the sleep hold's. When its connection goes
//  away — the app quit, crashed or let go — the invalidation handler tells
//  both, which hand back any fans that session held and restore sleep if it
//  held the Mac awake with its lid closed.
//

import Foundation
import LocalNookSMC

final class FanHelperSession: NSObject, FanHelperXPC, @unchecked Sendable {
    let id = UUID()
    private let controller: FanController
    private let hold: SleepHoldController

    init(controller: FanController, sleepHold: SleepHoldController) {
        self.controller = controller
        self.hold = sleepHold
    }

    func status(_ reply: @escaping @Sendable (Data) -> Void) {
        controller.status(for: id) { reply(Self.encode($0)) }
    }

    func apply(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        controller.apply(request, for: id) { reply(Self.encode($0)) }
    }

    func heartbeat(_ reply: @escaping @Sendable (Data) -> Void) {
        controller.heartbeat(for: id) { reply(Self.encode($0)) }
    }

    func restore(_ reply: @escaping @Sendable (Data) -> Void) {
        controller.restore(for: id) { reply(Self.encode($0)) }
    }

    func sleepHold(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        hold.handle(request, for: id) { reply(FanWire.encode($0) ?? Data()) }
    }

    /// The reply, within the payload cap. A status too large to send — it
    /// cannot be, with at most eight fans — goes without its fan list.
    static func encode(_ status: FanHelperStatus) -> Data {
        if let data = FanWire.encode(status) { return data }
        var trimmed = status
        trimmed.fans = []
        return FanWire.encode(trimmed) ?? Data()
    }
}

final class FanHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let controller: FanController
    private let sleepHold: SleepHoldController

    init(controller: FanController, sleepHold: SleepHoldController) {
        self.controller = controller
        self.sleepHold = sleepHold
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = FanHelperSession(controller: controller, sleepHold: sleepHold)
        let id = session.id
        connection.exportedInterface = NSXPCInterface(with: FanHelperXPC.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [controller, sleepHold] in
            controller.connectionClosed(id)
            sleepHold.connectionClosed(id)
        }
        controller.connectionOpened(id)
        sleepHold.connectionOpened(id)
        connection.resume()
        return true
    }
}
