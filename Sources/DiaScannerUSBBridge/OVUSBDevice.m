// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * Based on ov2640 Camera Driver
 * Copyright (C) 2010 Alberto Panizzo <maramaopercheseimorto@gmail.com>
 * Copyright 2005-2009 Freescale Semiconductor, Inc. All Rights Reserved.
 * Copyright (C) 2006, OmniVision
 */

#import "OVUSBDevice.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USB.h>
#import <IOUSBHost/IOUSBHost.h>

NSErrorDomain const OVUSBErrorDomain = @"com.diascanner.usb";

#define OV_VENDOR_ID   0x05A9
#define OV_PRODUCT_ID  0x1550

// USB control request direction + type
#define OV550_REQ_WRITE  0x40   // vendor | host→device | device
#define OV550_REQ_READ   0xC0   // vendor | device→host | device
#define OV550_BREQUEST   0x01   // bRequest for all OV550 register ops

#define OV2640_I2C_WRITE_ADDR  0x60

// Isoch IN endpoint address (direction=IN(bit7) | endpoint number 1)
#define OV550_ISOCH_IN_ADDR    0x81

static NSError *ovError(OVUSBError code, NSString *description) {
    return [NSError errorWithDomain:OVUSBErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation OVUSBDevice {
    // Legacy device interface: used only for control transfers (ASIC register access)
    IOUSBDeviceInterface300 **_device;
    // Modern host interface: used for alternate setting changes and isochronous reads
    IOUSBHostInterface      *_hostIface;
    dispatch_queue_t         _isochQueue;
    BOOL _isOpen;
}

- (void)dealloc { [self disconnectDevice]; }

- (BOOL)isOpen { return _isOpen; }

// ─── Open / Close ──────────────────────────────────────────────────

- (BOOL)openDeviceWithError:(NSError **)error {
    // ── Step 1: open device via legacy IOKit (control transfers) ──
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    SInt32 vendor  = OV_VENDOR_ID;
    SInt32 product = OV_PRODUCT_ID;
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID),
                         CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor));
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID),
                         CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product));

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict);
    if (!service) {
        if (error) *error = ovError(OVUSBErrorDeviceNotFound,
            @"PX-2130 scanner not found. Check USB connection (VID=0x05A9, PID=0x1550).");
        return NO;
    }

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    IOReturn ret = IOCreatePlugInInterfaceForService(service,
                        kIOUSBDeviceUserClientTypeID,
                        kIOCFPlugInInterfaceID,
                        &plugIn, &score);
    IOObjectRelease(service);

    if (ret != kIOReturnSuccess || !plugIn) {
        if (error) *error = ovError(OVUSBErrorOpenFailed,
            [NSString stringWithFormat:@"IOCreatePlugInInterfaceForService: 0x%08x", ret]);
        return NO;
    }

    IOUSBDeviceInterface300 **dev = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(plugIn,
                     CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                     (void **)&dev);
    (*plugIn)->Release(plugIn);

    if (hr || !dev) {
        if (error) *error = ovError(OVUSBErrorOpenFailed, @"QueryInterface for device interface failed");
        return NO;
    }
    _device = dev;

    ret = (*dev)->USBDeviceOpen(dev);
    if (ret != kIOReturnSuccess) {
        if (error) *error = ovError(OVUSBErrorOpenFailed,
            [NSString stringWithFormat:@"USBDeviceOpen: 0x%08x", ret]);
        (*dev)->Release(dev);
        _device = NULL;
        return NO;
    }

    // USB bus reset clears OV550 firmware state (SCCB bridge, PRE, FIFO) that persists
    // across software close/open cycles as long as USB power is present.  Without this,
    // run-2 always fails with SCCB NACK because the OV550's SCCB controller is stuck
    // in a state left over from the previous isoch run's C3/PRE activity.
    IOReturn resetRet = (*dev)->ResetDevice(dev);
    [self _log:[NSString stringWithFormat:@"USB ResetDevice: 0x%08x", resetRet]];
    usleep(2000000);  // 2s: after isoch run the SCCB bridge needs longer to clear than 500ms

    (*dev)->SetConfiguration(dev, 1);

    // ── Step 2: open interface via IOUSBHostInterface (isoch + alt setting) ──
    if (![self _openHostInterfaceWithError:error]) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        _device = NULL;
        return NO;
    }

    _isOpen = YES;
    return YES;
}

- (BOOL)_openHostInterfaceWithError:(NSError **)error {
    // Find the IOUSBHostInterface service for our device's interface 0
    CFMutableDictionaryRef matchingDict =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@(OV_VENDOR_ID)
                                                       productID:@(OV_PRODUCT_ID)
                                                       bcdDevice:nil
                                                 interfaceNumber:@0
                                              configurationValue:@1
                                                  interfaceClass:nil
                                               interfaceSubclass:nil
                                               interfaceProtocol:nil
                                                           speed:nil
                                                  productIDArray:nil];
    if (!matchingDict) {
        if (error) *error = ovError(OVUSBErrorInterfaceNotFound, @"createMatchingDictionary returned nil");
        return NO;
    }

    io_service_t ifService = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict);
    // matchingDict consumed by IOServiceGetMatchingService
    if (!ifService) {
        if (error) *error = ovError(OVUSBErrorInterfaceNotFound, @"IOUSBHostInterface service not found");
        return NO;
    }

    _isochQueue = dispatch_queue_create("com.diascanner.usb.isoch", DISPATCH_QUEUE_SERIAL);

    NSError *hostErr = nil;
    _hostIface = [[IOUSBHostInterface alloc] initWithIOService:ifService
                                                       options:0
                                                         queue:_isochQueue
                                                         error:&hostErr
                                               interestHandler:nil];
    IOObjectRelease(ifService);

    if (!_hostIface) {
        [self _log:[NSString stringWithFormat:@"IOUSBHostInterface init failed: %@", hostErr]];
        if (error) *error = hostErr ?: ovError(OVUSBErrorInterfaceOpenFailed,
            @"IOUSBHostInterface init failed");
        return NO;
    }
    [self _log:@"IOUSBHostInterface opened OK"];
    return YES;
}

- (void)disconnectDevice {
    if (_hostIface) {
        [_hostIface destroyWithOptions:0];
        _hostIface = nil;
    }
    _isochQueue = nil;
    if (_device) {
        (*_device)->USBDeviceClose(_device);
        (*_device)->Release(_device);
        _device = NULL;
    }
    _isOpen = NO;
}

// ─── ASIC Register Access (legacy IOKit, endpoint 0) ──────────────

- (BOOL)writeRegister:(uint16_t)reg value:(uint8_t)value error:(NSError **)error {
    if (!_device) {
        if (error) *error = ovError(OVUSBErrorRequestFailed, @"Device not open");
        return NO;
    }
    uint8_t buf = value;
    IOUSBDevRequest request = {
        .bmRequestType = OV550_REQ_WRITE,
        .bRequest      = OV550_BREQUEST,
        .wValue        = 0,
        .wIndex        = reg,
        .wLength       = 1,
        .pData         = &buf,
    };
    IOReturn ret = (*_device)->DeviceRequest(_device, &request);
    if (ret != kIOReturnSuccess) {
        if (error) *error = ovError(OVUSBErrorRequestFailed,
            [NSString stringWithFormat:@"writeReg 0x%04X=0x%02X failed: 0x%08X", reg, value, ret]);
        return NO;
    }
    return YES;
}

- (nullable NSNumber *)readRegister:(uint16_t)reg error:(NSError **)error {
    if (!_device) {
        if (error) *error = ovError(OVUSBErrorRequestFailed, @"Device not open");
        return nil;
    }
    uint8_t buf = 0;
    IOUSBDevRequest request = {
        .bmRequestType = OV550_REQ_READ,
        .bRequest      = OV550_BREQUEST,
        .wValue        = 0,
        .wIndex        = reg,
        .wLength       = 1,
        .pData         = &buf,
    };
    IOReturn ret = (*_device)->DeviceRequest(_device, &request);
    if (ret != kIOReturnSuccess) {
        if (error) *error = ovError(OVUSBErrorRequestFailed,
            [NSString stringWithFormat:@"readReg 0x%04X failed: 0x%08X", reg, ret]);
        return nil;
    }
    return @(buf);
}

- (BOOL)applyRegisterSequence:(NSData *)triplets error:(NSError **)error {
    const uint8_t *bytes = triplets.bytes;
    NSUInteger len = triplets.length;
    if (len % 3 != 0) {
        if (error) *error = ovError(OVUSBErrorRequestFailed, @"Triplet data must be multiple of 3");
        return NO;
    }
    for (NSUInteger i = 0; i < len; i += 3) {
        uint8_t reg   = bytes[i];
        uint8_t value = bytes[i+1];
        uint8_t mask  = bytes[i+2];
        if (mask != 0xFF) {
            NSNumber *cur = [self readRegister:reg error:error];
            if (!cur) return NO;
            value = (cur.unsignedCharValue & ~mask) | (value & mask);
        }
        if (![self writeRegister:reg value:value error:error]) return NO;
    }
    return YES;
}

// ─── SCCB Sensor Register Access (OV534/OV550 F-register bridge) ──
// Per ov534_9.c Linux driver (which supports 0x05a9:0x1550 — our device):
// 0xF1 = slave write address (0x60 for OV2640)
// 0xF2 = target sensor register address (SUBADDR)
// 0xF3 = write data
// 0xF4 = read result (READ)
// 0xF5 = operation trigger: 0x37=3-phase write, 0x33=read phase1, 0xF9=read phase2
// 0xF6 = status: 0x00=success, 0x04=NACK/fail, 0x03=busy

- (BOOL)_sccbWaitIdle {
    // Poll F6 (STATUS) up to 5 times × 20ms = 100ms max.
    // Reading F5 before F6 each iteration: F5 read completes the OV550's post-write state
    // machine cycle, allowing F6 to reflect the result of the current operation.
    for (int i = 0; i < 5; i++) {
        usleep(20000);  // 20ms per poll — SCCB 3-phase write takes <1ms, so one poll is enough
        [self _rawRead:0x01 reg:0xF5];  // complete OV550 post-write cycle before reading status
        NSNumber *v = [self _rawRead:0x01 reg:0xF6];
        if (!v) break;
        uint8_t s = v.unsignedCharValue;
        if (s == 0x00) return YES;
        if (s == 0x03) continue;  // busy — retry
        if (s == 0x04) {
            [self _log:[NSString stringWithFormat:@"SCCB NACK (F6=0x04) at attempt %d", i + 1]];
            return NO;
        }
    }
    return YES;
}

- (BOOL)writeSensorRegister:(uint8_t)reg value:(uint8_t)value error:(NSError **)error {
    if (![self writeRegister:0xF2 value:reg   error:error]) return NO;  // SUBADDR
    if (![self writeRegister:0xF3 value:value error:error]) return NO;  // WRITE data
    if (![self writeRegister:0xF5 value:0x37  error:error]) return NO;  // OPERATION: 3-phase write
    if (![self _sccbWaitIdle]) {
        if (error) *error = ovError(OVUSBErrorTimeout, @"SCCB write timeout/NACK");
        return NO;
    }
    return YES;
}

- (void)clearSCCBStatus {
    // Read F6 once to acknowledge any stale NACK status from a previous run.
    // Reading F5 here (without a pending trigger) triggers spurious OV550 state machine
    // cycles that corrupt subsequent writes — only read F5 inside _sccbWaitIdle.
    [self _rawRead:0x01 reg:0xF6];
}

- (nullable NSNumber *)readSensorRegister:(uint8_t)reg error:(NSError **)error {
    // Phase 1: 2-phase write (sets register pointer) — F5=0x33
    if (![self writeRegister:0xF2 value:reg  error:error]) return nil;  // SUBADDR
    if (![self writeRegister:0xF5 value:0x33 error:error]) return nil;  // OPERATION: read phase1
    if (![self _sccbWaitIdle]) {
        // OV2640 SCCB doesn't ACK the 9th bit — NACK here is expected; log but continue
        [self _log:[NSString stringWithFormat:@"SCCB read p1 NACK reg=0x%02X (continuing)", reg]];
    }
    // Phase 2: 2-phase read — F5=0xF9, result in F4
    if (![self writeRegister:0xF5 value:0xF9 error:error]) return nil;  // OPERATION: read phase2
    if (![self _sccbWaitIdle]) {
        [self _log:[NSString stringWithFormat:@"SCCB read p2 NACK reg=0x%02X (continuing)", reg]];
    }
    return [self readRegister:0xF4 error:error];  // READ result (may be garbage if NACK)
}

- (BOOL)applySensorRegisterSequence:(NSData *)triplets error:(NSError **)error {
    const uint8_t *bytes = triplets.bytes;
    NSUInteger len = triplets.length;
    if (len % 3 != 0) {
        if (error) *error = ovError(OVUSBErrorRequestFailed, @"Triplet data must be multiple of 3");
        return NO;
    }
    for (NSUInteger i = 0; i < len; i += 3) {
        uint8_t reg   = bytes[i];
        uint8_t value = bytes[i+1];
        uint8_t mask  = bytes[i+2];
        if (mask != 0xFF) {
            NSNumber *cur = [self readSensorRegister:reg error:error];
            if (!cur) return NO;
            value = (cur.unsignedCharValue & ~mask) | (value & mask);
        }
        if (![self writeSensorRegister:reg value:value error:error]) return NO;
        if (reg == 0x12 && (value & 0x80)) usleep(2000);  // post-reset delay
    }
    return YES;
}

// ─── Alternate Interface (IOUSBHostInterface) ──────────────────────

- (BOOL)setAlternateInterface:(uint8_t)altSetting error:(NSError **)error {
    if (!_hostIface) {
        if (error) *error = ovError(OVUSBErrorInterfaceNotFound, @"Host interface not open");
        return NO;
    }
    NSError *hostErr = nil;
    BOOL ok = [_hostIface selectAlternateSetting:altSetting error:&hostErr];
    if (!ok) {
        [self _log:[NSString stringWithFormat:@"selectAlternateSetting:%d failed: %@", altSetting, hostErr]];
        if (error) *error = hostErr ?: ovError(OVUSBErrorRequestFailed,
            [NSString stringWithFormat:@"selectAlternateSetting:%d failed", altSetting]);
    } else {
        [self _log:[NSString stringWithFormat:@"selectAlternateSetting:%d OK", altSetting]];
    }
    return ok;
}

// ─── Isochronous frame capture (IOUSBHostPipe) ─────────────────────
//
// Uses IOUSBHostInterface/IOUSBHostPipe instead of the legacy IOUSBInterfaceInterface300.
// firstFrameNumber=0 requests automatic scheduling on XHCI (avoids bandwidth reservation errors).

- (nullable NSData *)readFrameWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (!_hostIface) {
        if (error) *error = ovError(OVUSBErrorPipeFailed, @"Host interface not open");
        return nil;
    }

    // Log key ASIC state
    NSNumber *e0  = [self _rawRead:0x01 reg:0xE0];
    NSNumber *e7  = [self _rawRead:0x01 reg:0xE7];
    NSNumber *c3  = [self _rawRead:0x01 reg:0xC3];
    NSNumber *r8c = [self _rawRead:0x01 reg:0x8C];
    [self _log:[NSString stringWithFormat:
        @"isoch enter: E0=0x%02X E7=0x%02X C3=0x%02X 8C=0x%02X",
        e0?e0.unsignedCharValue:0xFF, e7?e7.unsignedCharValue:0xFF,
        c3?c3.unsignedCharValue:0xFF, r8c?r8c.unsignedCharValue:0xFF]];

    // Get the isochronous IN pipe
    NSError *hostErr = nil;
    IOUSBHostPipe *pipe = [_hostIface copyPipeWithAddress:OV550_ISOCH_IN_ADDR error:&hostErr];
    if (!pipe) {
        [self _log:[NSString stringWithFormat:@"copyPipeWithAddress:0x81 failed: %@", hostErr]];
        if (error) *error = hostErr ?: ovError(OVUSBErrorPipeFailed,
            @"copyPipeWithAddress:0x81 failed — is alt=1 active?");
        return nil;
    }
    [self _log:@"isoch: pipe 0x81 obtained from IOUSBHostInterface"];

    // Log endpoint descriptor and derive kPktSize
    const IOUSBHostIOSourceDescriptors *srcDesc = pipe.descriptors;
    uint32_t kPktSize = 3060;
    if (srcDesc) {
        uint16_t wMPS = USBToHostWord(srcDesc->descriptor.wMaxPacketSize);
        uint16_t payload = wMPS & 0x07FF;
        uint16_t mult    = ((wMPS >> 11) & 0x03) + 1;
        uint32_t perMF   = (uint32_t)payload * mult;
        [self _log:[NSString stringWithFormat:
            @"isoch pipe: wMaxPacketSize=0x%04X payload=%u mult=%u bytesPerMF=%u",
            wMPS, payload, mult, perMF]];
        if (perMF > 0) kPktSize = perMF;
    } else {
        [self _log:@"isoch pipe: descriptors nil, using kPktSize=3060"];
    }

    // Each isochronous transaction covers one microframe slot (kPktSize bytes max).
    // kBatch=512 (64ms per batch) ensures the full burst (~214 MFs = 26ms) fits
    // within the batch regardless of where in the batch VSYNC arrives (firstAt).
    // With kBatch=256 (32ms), a late VSYNC (firstAt>42) loses burst data in the
    // processing gap between batch submissions. kBatch=1024 exceeds XHCI scheduler limits.
    const NSUInteger kBatch = 512;

    NSMutableData *batchBuf = [NSMutableData dataWithLength:(size_t)kBatch * kPktSize];
    IOUSBHostIsochronousTransaction *txList =
        (IOUSBHostIsochronousTransaction *)calloc(kBatch, sizeof(IOUSBHostIsochronousTransaction));

    NSMutableData *accum = [NSMutableData dataWithCapacity:700000];
    int8_t currentFID = -1;   // -1 = not yet seen first packet
    NSData *result = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSUInteger batchIndex = 0;
    NSUInteger dumpedBatches = 0;
    BOOL prevBatchDense = NO;

    // Seed the frame schedule 16 microframes (~2ms) ahead to ensure we're in the future.
    // Track nextFrameNumber explicitly so each batch is scheduled gaplessly from the
    // previous one — using firstFrameNumber:0 (auto) causes XHCI to drop the bandwidth
    // reservation after a few batches when starting from a fresh USB replug.
    // frameNumberWithTime: returns USB 1ms frames; kBatch=512 microframes = 64 USB frames.
    // Advance by 64 per batch for gapless coverage; clamp if processing falls behind.
    const uint64_t kBatchUSBFrames = 64;
    uint64_t nextFrameNumber = [_hostIface frameNumberWithTime:nil] + 16;

    while (!result && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        // Start streaming (E0=0x00) here, at batch 0, immediately before sendIORequestWithData.
        // configureForOV2640RAW8 armed C3 and loaded the FIFO with E0=0x08. The E0=0x08→0x00
        // transition latches the FIFO/PRE config. Moving startStream here (vs. calling it from
        // main.swift before readFrame) shrinks the race window from ~10ms to ~3ms (one USB
        // control transfer), so C3 firing at the first VSYNC (~500ms away) is caught by batch 0.
        if (batchIndex == 0) {
            [self writeRegister:0xE0 value:0x00 error:nil]; // startStream — latches FIFO/C3
            nextFrameNumber = [_hostIface frameNumberWithTime:nil] + 16;
            [self _log:@"startStream (E0=0x00) at batch 0: FIFO/C3 latched, pipe active in <1ms"];
        }

        // Set up transactions: each covers one packet-sized slot in batchBuf
        memset(txList, 0, kBatch * sizeof(IOUSBHostIsochronousTransaction));
        for (NSUInteger i = 0; i < kBatch; i++) {
            txList[i].requestCount = kPktSize;
            txList[i].offset       = (uint32_t)(i * kPktSize);
        }

        // Synchronous call — blocks until all kBatch transactions complete or error
        BOOL ok = [pipe sendIORequestWithData:batchBuf
                              transactionList:txList
                         transactionListCount:kBatch
                             firstFrameNumber:nextFrameNumber
                                      options:0
                                        error:&hostErr];
        // Advance by exactly one batch duration for gapless coverage.
        // Clamp to current+2 if processing overhead caused us to fall behind.
        nextFrameNumber += kBatchUSBFrames;
        uint64_t nowFrame = [_hostIface frameNumberWithTime:nil];
        if (nextFrameNumber < nowFrame) {
            nextFrameNumber = nowFrame + 2;
        }

        if (!ok && hostErr) {
            IOReturn kr = (IOReturn)hostErr.code;
            if (kr != kIOReturnSuccess && kr != kIOReturnUnderrun) {
                [self _log:[NSString stringWithFormat:@"isoch batch[%zu] fatal kr=0x%08X accum=%zu: %@",
                    (size_t)batchIndex, (uint32_t)kr, accum.length, hostErr]];
                // If burst already received enough data, return it rather than failing
                if (accum.length >= 480000) {
                    result = [accum copy];
                }
                break;
            }
        }

        // Parse OV550 isochronous packets (UVC-compatible payload format):
        // byte[0] = bHeaderLength (0x0C = 12); byte[1] = bmHeaderInfo flags:
        //   bit 0 = FID (toggles on each new frame boundary)
        //   bit 1 = EOF (last packet of a frame)
        //   bit 6 = ERR (discard this payload)
        // Pixel data starts at byte[hlen]. Strip header, accumulate payload.
        const uint8_t *batchBytes = (const uint8_t *)batchBuf.bytes;
        uint32_t nonEmpty = 0;
        NSUInteger firstNonEmptyIdx = NSNotFound;
        for (NSUInteger i = 0; i < kBatch && !result; i++) {
            uint32_t actual = txList[i].completeCount;
            if (actual == 0) continue;
            nonEmpty++;
            if (firstNonEmptyIdx == NSNotFound) firstNonEmptyIdx = i;

            const uint8_t *pkt  = batchBytes + (size_t)i * kPktSize;
            uint8_t hlen  = pkt[0];
            uint8_t flags = (actual >= 2) ? pkt[1] : 0;

            if (hlen == 0 || hlen > actual) continue;  // malformed packet

            uint8_t fid = flags & 0x01;
            uint8_t eof = (flags >> 1) & 0x01;
            uint8_t err = (flags >> 6) & 0x01;
            if (err) continue;

            // FID toggle → previous accumulation is one complete frame
            if (currentFID >= 0 && fid != (uint8_t)currentFID && accum.length > 0) {
                [self _log:[NSString stringWithFormat:
                    @"isoch FID toggle batch[%zu] pkt[%zu]: %zu bytes → frame done",
                    (size_t)batchIndex, i, accum.length]];
                result = [accum copy];
                break;
            }
            currentFID = fid;

            uint32_t payloadLen = actual - hlen;
            if (payloadLen > 0) {
                // Cap at exactly one frame (1600×1200 RAW8 = 1,920,000 bytes)
                NSUInteger remaining = 1920000 - accum.length;
                NSUInteger toAppend = payloadLen < remaining ? payloadLen : remaining;
                [accum appendBytes:pkt + hlen length:toAppend];
                if (accum.length >= 1920000) {
                    [self _log:[NSString stringWithFormat:
                        @"isoch full frame (%zu bytes) at batch[%zu] pkt[%zu]",
                        accum.length, (size_t)batchIndex, i]];
                    result = [accum copy];
                    break;
                }
            }

            // EOF bit: end of this frame
            if (eof && accum.length > 0) {
                [self _log:[NSString stringWithFormat:
                    @"isoch EOF bit batch[%zu] pkt[%zu]: %zu bytes → frame done",
                    (size_t)batchIndex, i, accum.length]];
                result = [accum copy];
                break;
            }

        }

        // One burst per C3 arm: the OV550 flushes its FIFO in one dense burst per VSYNC.
        // Return on: (a) dense→sparse transition, or (b) enough data for a full frame.
        BOOL thisBatchDense = (nonEmpty > 10);
        if (!result && accum.length >= 1900000) {
            [self _log:[NSString stringWithFormat:
                @"frame size reached: returning %zu bytes", accum.length]];
            result = [accum copy];
        }
        if (!result && prevBatchDense && !thisBatchDense && accum.length > 0) {
            [self _log:[NSString stringWithFormat:
                @"dense→sparse: burst complete, returning %zu bytes", accum.length]];
            result = [accum copy];
        }
        prevBatchDense = thisBatchDense;

        // Log batch summary: first 3, non-empty batches, and all batches once burst starts
        BOOL burstSeen = (accum.length > 100);
        if (nonEmpty > 0 || batchIndex < 3 || (burstSeen && batchIndex <= 40)) {
            NSString *firstFlags = @"";
            if (firstNonEmptyIdx != NSNotFound) {
                const uint8_t *p = batchBytes + firstNonEmptyIdx * kPktSize;
                uint32_t n = txList[firstNonEmptyIdx].completeCount;
                if (n >= 2) firstFlags = [NSString stringWithFormat:
                    @" hdr=%02X/%02X fid=%u eof=%u err=%u",
                    p[0], p[1], p[1] & 1, (p[1] >> 1) & 1, (p[1] >> 6) & 1];
            }
            [self _log:[NSString stringWithFormat:
                @"isoch batch[%zu]: ok=%d nonEmpty=%u/%zu firstAt=%zu accum=%zu%@",
                (size_t)batchIndex, ok, nonEmpty, (size_t)kBatch,
                firstNonEmptyIdx == NSNotFound ? 9999 : firstNonEmptyIdx,
                accum.length, firstFlags]];
        }
        // Hex dump first non-empty packet for first 10 data batches
        if (firstNonEmptyIdx != NSNotFound && dumpedBatches < 10) {
            dumpedBatches++;
            const uint8_t *p = batchBytes + firstNonEmptyIdx * kPktSize;
            uint32_t n = txList[firstNonEmptyIdx].completeCount;
            NSMutableString *hex = [NSMutableString string];
            for (uint32_t j = 0; j < n && j < 32; j++)
                [hex appendFormat:@"%02X ", p[j]];
            [self _log:[NSString stringWithFormat:@"  pkt[%zu] %u bytes: %@",
                firstNonEmptyIdx, n, hex]];
        }
        batchIndex++;
    }

    free(txList);
    [pipe abortWithError:nil];
    pipe = nil;

    if (!result && error) {
        *error = ovError(OVUSBErrorTimeout, @"Frame read timeout (isoch)");
    }
    return result;
}

- (nullable NSData *)readBulkData:(NSUInteger)length timeout:(NSTimeInterval)timeout error:(NSError **)error {
    // Bulk path not available (device has no bulk endpoint); kept for API compatibility
    if (error) *error = ovError(OVUSBErrorPipeFailed, @"No bulk IN pipe on this device");
    return nil;
}

// ─── Helper: raw USB control request ──────────────────────────────

- (nullable NSNumber *)_rawRead:(uint8_t)bReq reg:(uint16_t)reg {
    uint8_t buf = 0;
    IOUSBDevRequest request = {
        .bmRequestType = OV550_REQ_READ,
        .bRequest      = bReq,
        .wValue        = 0,
        .wIndex        = reg,
        .wLength       = 1,
        .pData         = &buf,
    };
    IOReturn ret = (*_device)->DeviceRequest(_device, &request);
    if (ret != kIOReturnSuccess) return nil;
    return @(buf);
}

- (BOOL)_rawWrite:(uint8_t)bReq reg:(uint16_t)reg value:(uint8_t)val {
    uint8_t buf = val;
    IOUSBDevRequest request = {
        .bmRequestType = OV550_REQ_WRITE,
        .bRequest      = bReq,
        .wValue        = 0,
        .wIndex        = reg,
        .wLength       = 1,
        .pData         = &buf,
    };
    IOReturn ret = (*_device)->DeviceRequest(_device, &request);
    return (ret == kIOReturnSuccess);
}

- (void)_log:(NSString *)msg {
    NSString *line = [NSString stringWithFormat:@"PROBE: %@\n", msg];
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/diascanner.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:url error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[line dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:NO];
    }
}

- (void)probeI2CBridge {
    if (!_device) { [self _log:@"probeI2CBridge: device not open"]; return; }

    // Key ASIC F-register state (F5=OPERATION trigger, F6=STATUS, F4=READ result)
    int keyRegs[] = {0x0A, 0x0B, 0x0F, 0xE5, 0xE7, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6};
    NSMutableString *dump = [NSMutableString string];
    for (int i = 0; i < 11; i++) {
        NSNumber *v = [self _rawRead:0x01 reg:keyRegs[i]];
        [dump appendFormat:@"%02X=%02X ", keyRegs[i], v ? v.unsignedCharValue : 0xEE];
    }
    [self _log:[NSString stringWithFormat:@"Key regs: %@", dump]];

    // Test SCCB write: select bank1 (FF=0x01) — WRITES ONLY (reads corrupt SCCB bus state)
    [self _rawWrite:0x01 reg:0xF2 value:0xFF];
    [self _rawWrite:0x01 reg:0xF3 value:0x01];
    [self _rawWrite:0x01 reg:0xF5 value:0x37];
    usleep(20000);
    NSNumber *f5bs = [self _rawRead:0x01 reg:0xF5];
    NSNumber *f6bs = [self _rawRead:0x01 reg:0xF6];
    [self _log:[NSString stringWithFormat:
        @"SCCB write test bank1(FF=01): F5=%02X F6=%02X (0x00=ok 0x04=NACK)",
        f5bs ? f5bs.unsignedCharValue : 0xFF,
        f6bs ? f6bs.unsignedCharValue : 0xFF]];

    // Restore DSP bank
    [self _rawWrite:0x01 reg:0xF2 value:0xFF];
    [self _rawWrite:0x01 reg:0xF3 value:0x00];
    [self _rawWrite:0x01 reg:0xF5 value:0x37];
    usleep(20000);
    NSNumber *f6dsp = [self _rawRead:0x01 reg:0xF6];
    [self _log:[NSString stringWithFormat:@"SCCB write test DSP(FF=00): F6=%02X",
                f6dsp ? f6dsp.unsignedCharValue : 0xFF]];

    [self _log:@"probeI2CBridge done"];
}

@end
