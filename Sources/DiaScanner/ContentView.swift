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
    @State private var outputFormat: OutputFormat = .png
    @State private var jpegQuality: Double = 0.85
    @State private var scanFilename = ScanFilename()
    @State private var counterText: String = "001"

    var body: some View {
        HSplitView {
            // ─── Control panel ────────────────────────────────────────
            ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
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

                // Output format
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output Format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Format", selection: $outputFormat) {
                        ForEach(OutputFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    if outputFormat.supportsQuality {
                        HStack {
                            Text("Quality")
                                .font(.caption2)
                            Spacer()
                            Text("\(Int(jpegQuality * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $jpegQuality, in: 0.01...1.0)
                    }
                }

                // Filename prefix + counter
                VStack(alignment: .leading, spacing: 6) {
                    Text("Filename")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("prefix", text: $scanFilename.prefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Text("_")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("#", text: $counterText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: counterText) { _, new in
                                if let parsed = ScanFilename.parseCounterInput(new) {
                                    scanFilename.counter = parsed.counter
                                    scanFilename.counterPadding = parsed.padding
                                }
                            }
                    }
                    Text(".\(outputFormat.fileExtension)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

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
                    Text("Histogram")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HistogramView(histogram: scanner.histogram)
                    Toggle("Stretch", isOn: $scanner.autoLevelsEnabled)
                        .font(.caption2)
                        .disabled(scanner.histogram == nil)
                    Text("Brightness & Contrast")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Brightness")
                            .font(.caption2)
                        Spacer()
                        Text(String(format: "%+.2f", scanner.brightness))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $scanner.brightness, in: -1...1)
                    HStack {
                        Text("Contrast")
                            .font(.caption2)
                        Spacer()
                        Text(String(format: "%+.2f", scanner.contrast))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $scanner.contrast, in: -1...1)
                    HStack {
                        Text("Vignette")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", scanner.vignetteK))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $scanner.vignetteK, in: 0...0.9)
                    Button("Reset") {
                        scanner.resetAdjustments()
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
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
            .padding(.trailing, 15)
            }
            .frame(width: 216)

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
        let fmt = outputFormat
        let quality = jpegQuality
        let defaultName = scanFilename.filename(for: fmt)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fmt.utType].compactMap { $0 }
        panel.nameFieldStringValue = defaultName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try scanner.saveImage(transformed, to: url, format: fmt, quality: quality)
                scanFilename.increment()
                counterText = scanFilename.formattedCounter
            } catch {
                print("Save failed: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1100, height: 950)
}

private struct HistogramView: View {
    let histogram: RGBHistogram?

    var body: some View {
        Canvas { ctx, size in
            guard let histogram else { return }
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
