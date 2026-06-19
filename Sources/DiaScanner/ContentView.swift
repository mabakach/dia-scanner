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
    @State private var imageTransform = ImageTransform()

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
                Button {
                    Task {
                        if scanner.isConnected {
                            await scanner.disconnect()
                        } else {
                            await scanner.connect()
                        }
                    }
                } label: {
                    Text(scanner.isConnected ? "Disconnect" : "Connect Scanner")
                        .frame(maxWidth: .infinity)
                }
                .disabled(scanner.isBusy)

                Divider()

                // Film type
                VStack(alignment: .leading, spacing: 6) {
                    Text("Film Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Film Type", selection: $scanner.isNegativeMode) {
                        Text("Positive (Dia)").tag(false)
                        Text("Negative").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

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

                // Transform buttons
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button {
                            imageTransform.rotateLeft()
                        } label: {
                            Image(systemName: "rotate.left")
                        }
                        .help("Rotate 90° left")

                        Button {
                            imageTransform.rotateRight()
                        } label: {
                            Image(systemName: "rotate.right")
                        }
                        .help("Rotate 90° right")

                        Button {
                            imageTransform.toggleMirrorHorizontal()
                        } label: {
                            Image(systemName: "flip.horizontal")
                        }
                        .help("Mirror horizontal")

                        Button {
                            imageTransform.toggleMirrorVertical()
                        } label: {
                            Image(systemName: "flip.horizontal")
                                .rotationEffect(.degrees(90))
                        }
                        .help("Mirror vertical")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Adjustments
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adjustments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let hist = scanner.histogram {
                        Text("Histogram")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HistogramView(histogram: hist)
                        Toggle("Stretch", isOn: $scanner.autoLevelsEnabled)
                            .font(.caption2)
                    }
                    Text("Vignette")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Strength")
                            .font(.caption2)
                        Spacer()
                        Text(String(format: "%.2f", scanner.vignetteK))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $scanner.vignetteK, in: 0...0.9)
                }

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
                        .rotationEffect(.degrees(Double(imageTransform.rotation)))
                        .scaleEffect(
                            x: imageTransform.mirrorHorizontal ? -1 : 1,
                            y: imageTransform.mirrorVertical   ? -1 : 1
                        )
                        .padding(8)
                } else if let img = scanner.capturedImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(imageTransform.rotation)))
                        .scaleEffect(
                            x: imageTransform.mirrorHorizontal ? -1 : 1,
                            y: imageTransform.mirrorVertical   ? -1 : 1
                        )
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
        guard let captured = scanner.capturedImage else { return }
        let transformed = captured.applying(imageTransform)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, UTType.tiff]
        panel.nameFieldStringValue = "scan.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try scanner.saveImage(transformed, to: url)
            } catch {
                print("Save failed: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 700)
}

private struct HistogramView: View {
    let histogram: RGBHistogram

    var body: some View {
        Canvas { ctx, size in
            let maxR = max(1, histogram.r.max() ?? 1)
            let maxG = max(1, histogram.g.max() ?? 1)
            let maxB = max(1, histogram.b.max() ?? 1)
            let barW = max(size.width / 256, 1)
            for i in 0..<256 {
                let x = CGFloat(i) * barW
                for (values, maxVal, color) in [
                    (histogram.r, maxR, Color.red),
                    (histogram.g, maxG, Color.green),
                    (histogram.b, maxB, Color.blue)
                ] {
                    let h = size.height * log(CGFloat(values[i]) + 1) / log(CGFloat(maxVal) + 1)
                    ctx.fill(
                        Path(CGRect(x: x, y: size.height - h, width: barW, height: h)),
                        with: .color(color.opacity(0.5))
                    )
                }
            }
        }
        .frame(height: 64)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
