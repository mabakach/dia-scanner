// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — image display transform.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import AppKit
import CoreImage

/// Display-only transform applied to the live view and captured image.
/// Rotation is stored as a multiple of 90°, accumulated modulo 360.
public struct ImageTransform: Equatable {
    public private(set) var rotation: Int = 0   // 0, 90, 180, 270
    public private(set) var mirrorHorizontal: Bool = false
    public private(set) var mirrorVertical:   Bool = false

    public init() {}

    public mutating func rotateLeft()  { rotation = (rotation + 270) % 360 }
    public mutating func rotateRight() { rotation = (rotation +  90) % 360 }
    public mutating func toggleMirrorHorizontal() { mirrorHorizontal.toggle() }
    public mutating func toggleMirrorVertical()   { mirrorVertical.toggle() }

    public var isIdentity: Bool {
        rotation == 0 && !mirrorHorizontal && !mirrorVertical
    }
}

public extension NSImage {
    /// Returns a new image with this transform baked into the pixel data.
    /// CIImage uses Y-up coordinates, so clockwise rotation = negative angle,
    /// matching SwiftUI's `.rotationEffect` (which treats positive degrees as clockwise
    /// in its Y-down coordinate space). Mirror is applied after rotation, matching
    /// the order of `.rotationEffect` then `.scaleEffect` in the SwiftUI view.
    func applying(_ transform: ImageTransform) -> NSImage {
        guard !transform.isIdentity else { return self }
        guard let cgSrc = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }

        var ci = CIImage(cgImage: cgSrc)

        if transform.rotation != 0 {
            let radians = -CGFloat(transform.rotation) * .pi / 180.0
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: radians))
        }
        if transform.mirrorHorizontal {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        if transform.mirrorVertical {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
        }

        // Rotation and mirror may shift the extent into negative coordinates; normalize.
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX,
                                                   y: -ci.extent.minY))

        let ciCtx = CIContext()
        guard let cgResult = ciCtx.createCGImage(ci, from: ci.extent) else { return self }
        return NSImage(cgImage: cgResult, size: ci.extent.size)
    }
}
