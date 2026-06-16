// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — main SwiftUI view.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import SwiftUI
import DiaScannerLib
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scanner = ScannerDevice()
    @State private var showSavePanel = false
    @State private var saveURL: URL?

    var body: some View {
        HSplitView {
            // ─── Control panel ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 16) {
                Text("PX-2130 Dia Scanner")
                    .font(.headline)
                    .padding(.top, 4)

                Divider()

                // Connection status
                HStack {
                    Circle()
                        .fill(scanner.isConnected ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(scanner.isConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(.secondary)
                }

                // Connect / Disconnect
                Button(scanner.isConnected ? "Disconnect" : "Connect Scanner") {
                    Task {
                        if scanner.isConnected {
                            await scanner.disconnect()
                        } else {
                            await scanner.connect()
                        }
                    }
                }
                .disabled(scanner.isBusy)

                Divider()

                // Capture
                Button {
                    Task { await scanner.captureFrame() }
                } label: {
                    Label("Capture Frame", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scanner.isConnected || scanner.isBusy)

                // Save
                Button {
                    saveImage()
                } label: {
                    Label("Save Image…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(scanner.capturedImage == nil)

                Divider()

                // Image info
                if let img = scanner.capturedImage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resolution")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(img.size.width)) × \(Int(img.size.height)) px")
                            .font(.caption.monospacedDigit())
                    }
                }

                Spacer()

                // Error display
                if let err = scanner.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()
            .frame(width: 200)

            // ─── Image preview ────────────────────────────────────────
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if scanner.isBusy {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Working…")
                            .foregroundStyle(.secondary)
                    }
                } else if scanner.isConnected, let frame = scanner.liveFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if let img = scanner.capturedImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 64))
                            .foregroundStyle(.tertiary)
                        Text("No image captured")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, UTType.tiff]
        panel.nameFieldStringValue = "scan.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try scanner.saveImage(to: url)
            } catch {
                // Could present an alert; for now log
                print("Save failed: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 700)
}
