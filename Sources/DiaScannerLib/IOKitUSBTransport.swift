import Foundation
import DiaScannerUSBBridge

/// Bridges USBTransport to the Objective-C OVUSBDevice IOKit layer.
public final class IOKitUSBTransport: USBTransport {

    let device: OVUSBDevice

    public init(device: OVUSBDevice) {
        self.device = device
    }

    public func writeRegister(_ reg: UInt16, value: UInt8) throws {
        try device.writeRegister(reg, value: value)
    }

    public func readRegister(_ reg: UInt16) throws -> UInt8 {
        let n = try device.readRegister(reg)
        return n.uint8Value
    }

    public func writeSensorRegister(_ reg: UInt8, value: UInt8) throws {
        try device.writeSensorRegister(reg, value: value)
    }

    public func readSensorRegister(_ reg: UInt8) throws -> UInt8 {
        let n = try device.readSensorRegister(reg)
        return n.uint8Value
    }
}
