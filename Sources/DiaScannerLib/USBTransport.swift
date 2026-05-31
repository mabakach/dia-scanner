import Foundation

/// Abstraction over USB hardware access — enables mocking in tests.
public protocol USBTransport: AnyObject {
    func writeRegister(_ reg: UInt16, value: UInt8) throws
    func readRegister(_ reg: UInt16) throws -> UInt8
    func writeSensorRegister(_ reg: UInt8, value: UInt8) throws
    func readSensorRegister(_ reg: UInt8) throws -> UInt8
}

public enum ScannerError: Error, LocalizedError {
    case deviceNotFound
    case communicationFailed(String)
    case i2cTimeout
    case frameTimeout
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:              return "PX-2130 scanner not found. Make sure it is connected via USB."
        case .communicationFailed(let m):  return "USB communication error: \(m)"
        case .i2cTimeout:                  return "I2C sensor communication timeout"
        case .frameTimeout:                return "No frame received within timeout"
        case .invalidData(let m):          return "Invalid data: \(m)"
        }
    }
}
