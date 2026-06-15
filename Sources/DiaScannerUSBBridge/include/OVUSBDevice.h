// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PX-2130 Slide Scanner macOS Driver — OV550 USB bridge handle.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * USB control transfer protocol and F-register SCCB bridge mechanism
 * derived from the Linux ov534-ov9xxx gspca driver
 * (drivers/media/usb/gspca/ov534_9.c):
 *   Copyright (C) 2009-2011 Jean-Francois Moine <http://moinejf.free.fr>
 *   Copyright (C) 2008      Antonio Ospite <ospite@studenti.unina.it>
 *   Copyright (C) 2008      Jim Paris <jim@jtan.com>
 *   Based on a prototype by Mark Ferrell <majortrips@gmail.com>
 *   USB protocol reverse engineered by Jim Paris.
 */

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVUSBError) {
    OVUSBErrorDeviceNotFound = 1,
    OVUSBErrorOpenFailed,
    OVUSBErrorInterfaceNotFound,
    OVUSBErrorInterfaceOpenFailed,
    OVUSBErrorRequestFailed,
    OVUSBErrorTimeout,
    OVUSBErrorPipeFailed,
};

extern NSErrorDomain const OVUSBErrorDomain;

/// Low-level USB device handle for OmniVision OV550 bridge chip.
/// All methods are synchronous and not thread-safe; call from a single serial queue.
@interface OVUSBDevice : NSObject

/// Opens the first OmniVision scanner (VID 0x05A9, PID 0x1550).
/// Swift: throws on failure.
- (BOOL)openDeviceWithError:(NSError *__autoreleasing *)error
    NS_SWIFT_NAME(connectScanner());

/// Closes the device and releases all IOKit resources.
- (void)disconnectDevice NS_SWIFT_NAME(disconnectScanner());

@property (readonly, nonatomic) BOOL isOpen;

// ─── OV550 ASIC register access ───────────────────────────────────

/// Writes a single byte to an OV550 ASIC register.
- (BOOL)writeRegister:(uint16_t)reg value:(uint8_t)value error:(NSError *__autoreleasing *)error;

/// Reads a single byte from an OV550 ASIC register.
/// Returns NSNumber wrapping the byte, or throws on error.
- (nullable NSNumber *)readRegister:(uint16_t)reg error:(NSError *__autoreleasing *)error;

/// Executes a sequence of [register, value, mask] triplets (ASIC registers).
- (BOOL)applyRegisterSequence:(NSData *)triplets error:(NSError *__autoreleasing *)error;

// ─── OV2640 sensor register access (I2C via OV550 bridge) ─────────

/// Writes to OV2640 sensor register via OV550 I2C bridge.
- (BOOL)writeSensorRegister:(uint8_t)reg value:(uint8_t)value error:(NSError *__autoreleasing *)error;

/// Reads from OV2640 sensor register via OV550 I2C bridge.
/// Returns NSNumber wrapping the byte, or throws on error.
- (nullable NSNumber *)readSensorRegister:(uint8_t)reg error:(NSError *__autoreleasing *)error;

/// Executes a sequence of [register, value, mask] sensor triplets (via I2C).
- (BOOL)applySensorRegisterSequence:(NSData *)triplets error:(NSError *__autoreleasing *)error;

/// Reads F6 once to acknowledge/clear any stale NACK status left by a previous run.
/// Call after power-on, before the first SCCB write.
- (void)clearSCCBStatus;

// ─── Interface and streaming ──────────────────────────────────────

/// Selects the USB interface alternate setting (0=idle, 1=streaming).
- (BOOL)setAlternateInterface:(uint8_t)altSetting error:(NSError *__autoreleasing *)error;

/// Reads one complete RAW8 frame from the isochronous IN pipe.
/// `frameBytes` is the expected payload size — used as the hard cap to detect a
/// full frame independent of EOF. Pass 0 to rely solely on FID/EOF markers.
- (nullable NSData *)readFrameWithTimeout:(NSTimeInterval)timeout
                               frameBytes:(NSUInteger)frameBytes
                                    error:(NSError *__autoreleasing *)error;

/// Streams raw isochronous data (including UVC-style headers) for `duration` seconds.
/// Returns a single buffer with each captured microframe's actual data concatenated.
/// Each entry in `packetSizes` is the byte count for the corresponding microframe.
/// Intended for diagnostic dumps — not used in the normal capture path.
- (nullable NSData *)rawIsochDumpWithDuration:(NSTimeInterval)duration
                                  packetSizes:(NSMutableArray<NSNumber *> *_Nullable)packetSizes
                                        error:(NSError *__autoreleasing *)error;

/// Reads from the bulk IN endpoint.
- (nullable NSData *)readBulkData:(NSUInteger)length timeout:(NSTimeInterval)timeout error:(NSError *__autoreleasing *)error;

/// Probes multiple I2C bridge approaches and logs results to /tmp/diascanner.log.
- (void)probeI2CBridge;

@end

NS_ASSUME_NONNULL_END
