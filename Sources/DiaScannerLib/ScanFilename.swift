// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — batch scan filename model.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

/// Tracks the filename prefix and counter used for batch scan saves.
public struct ScanFilename: Sendable {
    public var prefix: String
    public var counter: Int

    public init(prefix: String = "scan", counter: Int = 1) {
        self.prefix = prefix
        self.counter = counter
    }

    /// Returns the filename (without directory) for the given format: `prefix_counter.ext`.
    public func filename(for format: OutputFormat) -> String {
        "\(prefix)_\(counter).\(format.fileExtension)"
    }

    /// Increments the counter by one.
    public mutating func increment() {
        counter += 1
    }
}
