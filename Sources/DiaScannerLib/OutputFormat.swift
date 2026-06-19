// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — output image format.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import AppKit
import UniformTypeIdentifiers

/// Supported image output formats, backed by macOS NSBitmapImageRep encoders.
public enum OutputFormat: String, CaseIterable, Sendable {
    case jpeg     = "jpeg"
    case png      = "png"
    case bmp      = "bmp"
    case tiff     = "tiff"
    case jpeg2000 = "jpeg2000"

    public var displayName: String {
        switch self {
        case .jpeg:     return "JPEG"
        case .png:      return "PNG"
        case .bmp:      return "BMP"
        case .tiff:     return "TIFF"
        case .jpeg2000: return "JPEG 2000"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg:     return "jpg"
        case .png:      return "png"
        case .bmp:      return "bmp"
        case .tiff:     return "tiff"
        case .jpeg2000: return "jp2"
        }
    }

    /// Whether this format supports a lossy quality parameter (0.0–1.0).
    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .jpeg2000: return true
        case .png, .bmp, .tiff: return false
        }
    }

    public var utType: UTType {
        switch self {
        case .jpeg:     return .jpeg
        case .png:      return .png
        case .bmp:      return .bmp
        case .tiff:     return .tiff
        case .jpeg2000: return UTType("public.jpeg-2000") ?? .jpeg
        }
    }

    public var bitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .jpeg:     return .jpeg
        case .png:      return .png
        case .bmp:      return .bmp
        case .tiff:     return .tiff
        case .jpeg2000: return .jpeg2000
        }
    }

    /// Encodes `image` to `Data` using the macOS built-in encoder.
    /// - Parameter quality: Compression quality in 0.0–1.0 (ignored for lossless formats).
    public func encode(_ image: NSImage, quality: Double = 0.85) throws -> Data {
        guard let tiff   = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            throw OutputFormatError.encodingFailed("Failed to create bitmap representation")
        }

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if supportsQuality {
            properties[.compressionFactor] = max(0.0, min(1.0, quality))
        }

        guard let data = bitmap.representation(using: bitmapFileType, properties: properties) else {
            throw OutputFormatError.encodingFailed("NSBitmapImageRep returned nil for \(displayName)")
        }
        return data
    }
}

public enum OutputFormatError: Error, LocalizedError {
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let msg): return "Image encoding failed: \(msg)"
        }
    }
}
