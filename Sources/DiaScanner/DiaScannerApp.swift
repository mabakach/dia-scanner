// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — SwiftUI app entry point.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import SwiftUI
import AppKit
import DiaScannerLib

@main
struct DiaScannerApp: App {

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
