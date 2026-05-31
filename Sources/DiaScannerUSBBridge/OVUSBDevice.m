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
    // F6 is pre-cleared by writeSensorRegister before the trigger, so 0x04 here is a real NACK.
    for (int i = 0; i < 5; i++) {
        usleep(20000);  // 20ms per poll — SCCB 3-phase write takes <1ms, so one poll is enough
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
    // Read F6 to acknowledge/clear any stale status from a prior operation or previous run.
    // The OV550 ignores new SCCB triggers while F6 holds an unacknowledged result (0x04 NACK).
    [self _rawRead:0x01 reg:0xF6];
    if (![self writeRegister:0xF2 value:reg   error:error]) return NO;  // SUBADDR
    if (![self writeRegister:0xF3 value:value error:error]) return NO;  // WRITE data
    if (![self writeRegister:0xF5 value:0x37  error:error]) return NO;  // OPERATION: 3-phase write
    if (![self _sccbWaitIdle]) {
        if (error) *error = ovError(OVUSBErrorTimeout, @"SCCB write timeout/NACK");
        return NO;
    }
    return YES;
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
    const NSUInteger kBatch = 256;

    NSMutableData *batchBuf = [NSMutableData dataWithLength:(size_t)kBatch * kPktSize];
    IOUSBHostIsochronousTransaction *txList =
        (IOUSBHostIsochronousTransaction *)calloc(kBatch, sizeof(IOUSBHostIsochronousTransaction));

    NSMutableData *accum = [NSMutableData dataWithCapacity:2000000];
    BOOL inFrame = NO;
    NSData *result = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSUInteger batchIndex = 0;

    while (!result && [[NSDate date] compare:deadline] == NSOrderedAscending) {
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
                             firstFrameNumber:0  // automatic scheduling on XHCI
                                      options:0
                                        error:&hostErr];

        // Log batch summary + first non-empty packet content
        uint32_t nonEmpty = 0;
        NSUInteger firstNonEmptyIdx = NSNotFound;
        IOReturn firstBadStatus = kIOReturnSuccess;
        for (NSUInteger i = 0; i < kBatch; i++) {
            if (txList[i].completeCount > 0 && firstNonEmptyIdx == NSNotFound)
                firstNonEmptyIdx = i;
            if (txList[i].completeCount > 0) nonEmpty++;
            if (txList[i].status != kIOReturnSuccess
                && firstBadStatus == kIOReturnSuccess) {
                firstBadStatus = txList[i].status;
            }
        }
        if (nonEmpty > 0 || batchIndex < 3) {
            [self _log:[NSString stringWithFormat:
                @"isoch batch[%zu]: ok=%d nonEmpty=%u/%zu firstAt=%zu bytes=%u",
                (size_t)batchIndex, ok, nonEmpty, (size_t)kBatch,
                firstNonEmptyIdx == NSNotFound ? 9999 : firstNonEmptyIdx,
                firstNonEmptyIdx != NSNotFound ? txList[firstNonEmptyIdx].completeCount : 0]];
        }
        // Dump bytes of first non-empty packet (only first 5 batches with data)
        static NSUInteger dumpCount = 0;
        if (firstNonEmptyIdx != NSNotFound && dumpCount < 5) {
            dumpCount++;
            const uint8_t *p = (const uint8_t *)batchBuf.bytes + firstNonEmptyIdx * kPktSize;
            uint32_t n = txList[firstNonEmptyIdx].completeCount;
            NSMutableString *hex = [NSMutableString string];
            for (uint32_t j = 0; j < n && j < 32; j++)
                [hex appendFormat:@"%02X ", p[j]];
            [self _log:[NSString stringWithFormat:@"  pkt[%zu] %u bytes: %@", firstNonEmptyIdx, n, hex]];
        }
        batchIndex++;

        if (!ok && hostErr) {
            IOReturn kr = (IOReturn)hostErr.code;
            if (kr != kIOReturnSuccess && kr != kIOReturnUnderrun) {
                [self _log:[NSString stringWithFormat:@"isoch batch fatal: %@", hostErr]];
                break;
            }
        }

        // Parse isochronous packets for OV550 frame sync bytes (0xFF = start, 0xFE = end)
        const uint8_t *batchBytes = (const uint8_t *)batchBuf.bytes;
        for (NSUInteger i = 0; i < kBatch; i++) {
            uint32_t actual = txList[i].completeCount;
            if (actual == 0) continue;

            const uint8_t *pkt  = batchBytes + (size_t)i * kPktSize;
            uint8_t        sync = pkt[0];

            if (sync == 0xFF) {
                [accum setLength:0];
                inFrame = YES;
                if (actual > 1) [accum appendBytes:pkt + 1 length:actual - 1];
            } else if (sync == 0xFE && inFrame) {
                if (actual > 1) [accum appendBytes:pkt + 1 length:actual - 1];
                result = [accum copy];
                break;
            } else if (inFrame) {
                [accum appendBytes:pkt length:actual];
            }
        }
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
