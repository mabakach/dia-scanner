# PX-2130 Dia Scanner — macOS Driver

A macOS driver and capture application for the **Reflecta PX-2130** slide/transparency scanner (USB VID `05A9`, PID `1550`).

The scanner has no macOS support from the manufacturer.
This project reverse-engineered the USB protocol from the Windows driver and ported the Linux kernel driver ([gspca_ov534_9](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/usb/gspca/ov534_9.c)) to Swift/Objective-C using Apple's IOKit and IOUSBHost frameworks.

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

- macOS 14 (Sonnet) or later
- Xcode 15 or later (Swift 5.10)
- Swift Package Manager

## Building

```sh
# Build everything
swift build

# Run the command-line capture tool
swift run DiaScannerCLI [output-path]
# Saves <output-path>.raw (Bayer) and <output-path>.png (demosaiced)
# Defaults to /tmp/diascanner_capture if no path given

# Run the SwiftUI app
swift run DiaScanner

# Run unit tests
swift test
```

The app requires the `com.apple.security.device.usb` entitlement (or runs unsandboxed) to access the USB device directly via IOKit.

## Repository structure

```
Sources/
  DiaScannerUSBBridge/   Low-level IOKit/IOUSBHost wrapper (Objective-C)
  DiaScannerLib/         Core driver library (Swift)
    OV5621Sensor.swift     Sensor init sequences, ported from gspca_ov534_9
    OV550Controller.swift  OV550 ASIC bridge register commands
    IOKitUSBTransport.swift USB transport implementation
    BayerDemosaic.swift    BGGR → RGB demosaic
    FrameParser.swift      UVC-style payload header parser
    ScannerDevice.swift    High-level ObservableObject for the SwiftUI app
  DiaScanner/            SwiftUI app (ContentView + app entry point)
  DiaScannerCLI/         Command-line capture tool

Tests/DiaScannerTests/   Unit tests (FrameParser, BayerDemosaic, OV550Controller)
linux/                   Upstream Linux driver sources (reference)
  ov534_9.c              gspca_ov534_9 — the kernel driver this port is based on
tools/
  analyze_raw.py         Diagnostic tool: statistics and BMP export for .raw captures
manual/                  German user manual PDF and OV2640 datasheet
windows-driver/          Original Windows x64 driver installer (reference only)
```

## How it works

The OV550 bridge chip exposes a USB vendor-class interface with a simple register read/write protocol (USB control transfers to endpoint 0). Six of its registers (F1–F6) implement an SCCB (I²C-compatible) bridge to the OV5621 image sensor.

On connect, the driver:
1. Sends the bridge reset sequence (E7, E0 registers) and reads the sensor chip ID via SCCB to confirm it is an OV5621.
2. Applies the 13-entry bridge init table and ~107-entry sensor register table from `gspca_ov534_9`.
3. Switches the USB interface to alternate setting 1, which activates the isochronous IN endpoint (0x81, `wMaxPacketSize` = 3060 bytes/microframe).

Each captured frame (4 354 560 bytes) arrives as a stream of isochronous USB microframes carrying UVC-style 12-byte payload headers. The driver maintains ≥ 8 asynchronous URBs in flight (`IOUSBHostPipe enqueueIORequestWithData:completionHandler:`) to avoid dropping microframes between batches. Frames are delimited by PTS (presentation timestamp) changes in the payload headers.

## Capture output

Raw frames are BGGR Bayer 8-bit. The CLI and GUI both demosaic to 24-bit RGB using a bilinear kernel. The film negative inversion (orange mask removal) is not yet applied — output currently looks like an orange negative.

## License

GPL-2.0-only. See [License.md](License.md).

This project incorporates code derived from:
- **ov534_9.c** — Linux gspca_ov534_9 driver  
  Copyright (C) 2009–2011 Jean-Francois Moine, Antonio Ospite, Jim Paris; prototype by Mark Ferrell.  
  Licensed under GPL-2.0-or-later.

## References

- [Linux gspca_ov534_9 driver](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/usb/gspca/ov534_9.c)
- OV5621 sensor datasheet (not publicly available; register sequences taken from the Linux driver)
- `manual/PX-2130 Diascanner - GERMAN Bildschirm.pdf` — original German user manual
