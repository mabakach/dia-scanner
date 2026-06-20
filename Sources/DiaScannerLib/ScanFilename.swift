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
    /// Minimum digit width for the counter; values < actual digit count are ignored.
    /// 1 means no leading zeros; 3 means "001", "042", "100", "1000", …
    public var counterPadding: Int

    public init(prefix: String = "scan", counter: Int = 1, counterPadding: Int = 3) {
        self.prefix = prefix
        self.counter = counter
        self.counterPadding = counterPadding
    }

    /// Counter formatted with leading zeros according to `counterPadding`.
    public var formattedCounter: String {
        String(format: "%0\(max(1, counterPadding))d", counter)
    }

    /// Returns the filename (without directory) for the given format: `prefix_counter.ext`.
    public func filename(for format: OutputFormat) -> String {
        "\(prefix)_\(formattedCounter).\(format.fileExtension)"
    }

    /// Increments the counter by one.
    public mutating func increment() {
        counter += 1
    }

    /// Parses a user-typed counter string into a `(counter, padding)` pair.
    ///
    /// A leading zero signals zero-padding; the padding equals the total character count.
    /// Returns `nil` for non-numeric or negative input.
    public static func parseCounterInput(_ text: String) -> (counter: Int, padding: Int)? {
        guard let value = Int(text), value >= 0 else { return nil }
        let padding = text.hasPrefix("0") && text.count > 1 ? text.count : 1
        return (counter: value, padding: padding)
    }
}
