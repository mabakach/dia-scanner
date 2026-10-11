# PX-2130 Dia Scanner — macOS Driver

A macOS driver and capture application for the **Reflecta PX-2130** slide/transparency scanner (USB VID `05A9`, PID `1550`).

The scanner has no macOS support from the manufacturer.
This project reverse-engineered the USB protocol from the Windows driver and ported the Linux kernel driver ([gspca_ov534_9](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/usb/gspca/ov534_9.c)) to Swift/Objective-C using Apple's IOKit and IOUSBHost frameworks.

## Download

Download the latest signed and notarized `DiaScanner-<version>.dmg` from the [Releases page](https://github.com/mabakach/dia-scanner/releases).

1. Open the DMG and drag **DiaScanner** into **Applications**.
2. Connect the scanner via USB and launch the app.

The app is a universal binary (Apple Silicon and Intel) and requires macOS 14 or later.

## Hardware

| Component | Details |
|-----------|---------|
| USB bridge | OmniVision OV550 (`05A9:1550`) |
| Image sensor | OmniVision OV5621 |
| Native resolution | 2592 × 1680 pixels |
| Output format | SBGGR8 (BGGR Bayer pattern, 8 bpp) |
| Frame rate | ~2 fps |
| Connection | USB 2.0 (isochronous transfer) |

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 or later (the Xcode project uses Swift 6 language mode; releases are built with Xcode 26)
- Swift Package Manager (`swift-tools-version: 5.10`)

## Building

```sh
# Build everything
swift build

# Run the command-line capture tool
swift run DiaScannerCLI [output-path] [--format jpeg|png|bmp|tiff|jpeg2000] [--quality 1-100] [--negative]
# Saves <output-path>.raw (Bayer) and <output-path>.<format> (demosaiced, PNG by default)
# Defaults to /tmp/diascanner_capture if no path given; log goes to /tmp/diascanner.log

# Run the SwiftUI app
swift run DiaScanner

# Run unit tests
swift test
```

`DiaScanner.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`).

The app is not sandboxed and ships without entitlements; it accesses the USB device directly via IOKit.

## Releases

Pushing a tag `v*` runs `.github/workflows/release.yml`. It builds a universal app, signs it with a Developer ID certificate, notarizes and staples it, and publishes `DiaScanner-<version>.dmg` as a GitHub release.

## Repository structure

```
Sources/
  DiaScannerUSBBridge/   Low-level IOKit/IOUSBHost wrapper (Objective-C)
  DiaScannerLib/         Core driver and image-processing library (Swift)
    OV5621Sensor.swift     Sensor init sequences, ported from gspca_ov534_9
    OV2640Sensor.swift     Earlier OV2640 sensor support (superseded by OV5621)
    OV550Controller.swift  OV550 ASIC bridge register commands
    USBTransport.swift     USB transport protocol
    IOKitUSBTransport.swift USB transport implementation
    FrameParser.swift      UVC-style payload header parser
    BayerDemosaic.swift    BGGR → RGB demosaic
    NegativeFilter.swift   Negative inversion and orange-mask removal
    PositiveFilter.swift   Vignetting correction and auto-levels for slides
    BrightnessContrastFilter.swift, ImageTransform.swift, RGBHistogram.swift
    OutputFormat.swift, ScanFilename.swift  Save formats and file naming
    LicenseText.swift      License text shown in the About dialog
    ScannerDevice.swift    High-level ObservableObject for the SwiftUI app
  DiaScanner/            SwiftUI app (ContentView, AboutView, app entry point)
  DiaScannerCLI/         Command-line capture tool

Tests/DiaScannerTests/   Unit tests for the library (parser, demosaic, filters, formats, …)
linux/                   Upstream Linux driver sources (reference)
  ov534_9.c              gspca_ov534_9 — the kernel driver this port is based on
  ov2640.c               OV2640 sensor driver (reference for the earlier sensor guess)
tools/
  analyze_raw.py         Diagnostic tool: statistics and BMP export for .raw captures
manual/                  German user manual PDF
windows-driver/          Original Windows x64 driver installer (reference only)
project.yml              XcodeGen project definition
.github/workflows/       Release workflow (signed and notarized DMG)
```

## How it works

The OV550 bridge chip exposes a USB vendor-class interface with a simple register read/write protocol (USB control transfers to endpoint 0). Six of its registers (F1–F6) implement an SCCB (I²C-compatible) bridge to the OV5621 image sensor.

On connect, the driver:
1. Sends the bridge reset sequence (E7, E0 registers) and reads the sensor chip ID via SCCB to confirm it is an OV5621.
2. Applies the 13-entry bridge init table and 99-entry sensor register table from `gspca_ov534_9`.
3. Switches the USB interface to alternate setting 1, which activates the isochronous IN endpoint (0x81, `wMaxPacketSize` = 3060 bytes/microframe).

Each captured frame (4 354 560 bytes) arrives as a stream of isochronous USB microframes carrying UVC-style 12-byte payload headers. The driver keeps 8 asynchronous URBs in flight (`IOUSBHostPipe enqueueIORequestWithData:completionHandler:`) to avoid dropping microframes between batches. Frames are delimited by PTS (presentation timestamp) changes in the payload headers.

## Capture output

Raw frames are BGGR Bayer 8-bit. The CLI and GUI both demosaic to 24-bit RGB using bilinear interpolation.

The GUI shows a live view and offers:
- film type: positive (slide) or negative (inversion with per-channel orange-mask removal)
- auto-levels ("Stretch"), brightness, contrast and vignetting correction
- rotate and flip
- save as JPEG, PNG, BMP, TIFF or JPEG 2000 with a configurable file name prefix and counter

The CLI applies negative inversion with `--negative`.

## License

GPL-2.0-only. See [License.md](License.md).

This project incorporates code derived from:
- **ov534_9.c** — Linux gspca_ov534_9 driver  
  Copyright (C) 2009–2011 Jean-Francois Moine, Antonio Ospite, Jim Paris; prototype by Mark Ferrell.  
  Licensed under GPL-2.0-or-later.

## References

- [Linux gspca_ov534_9 driver](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/usb/gspca/ov534_9.c)
- OV5621 sensor datasheet (not publicly available; register sequences taken from the Linux driver)
