// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PX-2130 Slide Scanner macOS Driver — UVC-style payload header parser.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * Header decoding (EOH/ERR/SCR/PTS/EOF/FID flags) is derived from the
 * Linux ov534-ov9xxx gspca driver `sd_pkt_scan`
 * (drivers/media/usb/gspca/ov534_9.c):
 *   Copyright (C) 2009-2011 Jean-Francois Moine <http://moinejf.free.fr>
 *   Copyright (C) 2008      Antonio Ospite <ospite@studenti.unina.it>
 *   Copyright (C) 2008      Jim Paris <jim@jtan.com>
 */

import Foundation

/// Assembles complete image frames from a stream of isochronous USB packets.
///
/// OV550 packet framing protocol:
///   - Byte 0 = 0xFF → Start of Frame (remaining bytes = first pixel data)
///   - Byte 0 = 0xFE → End of Frame   (remaining bytes = last pixel data)
///   - Otherwise      → continuation data packet
public final class FrameParser {

    public var onFrameComplete: ((Data) -> Void)?

    private var buffer: Data
    private var inFrame = false
    private let expectedFrameSize: Int

    public init(frameWidth: Int, frameHeight: Int) {
        expectedFrameSize = frameWidth * frameHeight
        buffer = Data(capacity: expectedFrameSize)
    }

    /// Feed one isochronous USB packet into the parser.
    public func feed(_ packet: Data) {
        guard !packet.isEmpty else { return }

        let sync = packet[packet.startIndex]

        if sync == 0xFF {
            // Start of Frame — reset and collect remaining bytes
            buffer.removeAll(keepingCapacity: true)
            inFrame = true
            if packet.count > 1 {
                buffer.append(packet.suffix(from: packet.startIndex + 1))
            }
        } else if sync == 0xFE && inFrame {
            // End of Frame — append tail bytes and emit
            if packet.count > 1 {
                buffer.append(packet.suffix(from: packet.startIndex + 1))
            }
            let frame = buffer
            buffer.removeAll(keepingCapacity: true)
            inFrame = false
            onFrameComplete?(frame)
        } else if inFrame {
            buffer.append(packet)
        }
        // data before first SOF is discarded
    }

    /// Reset parser state (e.g. after error).
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        inFrame = false
    }
}
