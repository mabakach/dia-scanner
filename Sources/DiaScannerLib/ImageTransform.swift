// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — image display transform.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

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
