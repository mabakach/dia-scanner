# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Archival repository for the **PX-2130 Diascanner** (slide/transparency scanner). Contains the Windows 64-bit driver and German user manual. There is no source code.

## Contents

- `manual/` — German user manual PDF for the PX-2130 scanner
- `windows-driver/64BitDriver/` — Windows x64 driver installer (OmniVision OV550, USB VID `05a9` PID `1550`, driver from 2007)

## Device info

- USB device: OmniVision OV550 (`05a9:1550`)
- Driver package: `OVTScanner_Vista64.msi` (Windows Vista/7/8/10 x64)
- The `.set` files in `OvtCam/` are camera calibration/configuration files
