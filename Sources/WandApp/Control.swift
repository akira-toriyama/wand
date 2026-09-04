// Shared constants for the CLI ↔ daemon IPC bridge. The daemon
// side (Controller.installCLIControl) observes
// `controlNotificationName`; the client side (Main.swift's argv
// dispatch) posts to it and exits.
//
// Name is deliberately distinct from the bundle id
// (`com.wand.wand`) so the bundle id can change later without
// breaking already-installed clients. Same trick facet uses with
// `com.facet.app.control`.

import Foundation

let controlNotificationName = "com.wand.app.control"

/// The running daemon rewrites this file on start / reload / each
/// recognised gesture; `wand daemon --show` reads it. A plain file
/// sidesteps needing a request/response IPC channel (DNC is one-way).
let statusPath = "/tmp/wand.status"
