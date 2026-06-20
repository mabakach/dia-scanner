// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — About dialog.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import SwiftUI
import DiaScannerLib

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 16) {
            Text("DiaScanner")
                .font(.title)
                .bold()

            Text("Version \(version)")
                .foregroundStyle(.secondary)

            ScrollView {
                Text(gplV2LicenseText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.disabled)
            }
            .frame(height: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            Button("OK") {
                NSApplication.shared.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 520)
        .background(MiniaturizeButtonDisabler())
    }
}

// NSViewRepresentable bridge to reach the NSWindow and disable the minimize button,
// which SwiftUI exposes no native modifier for.
private struct MiniaturizeButtonDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    AboutView()
}
