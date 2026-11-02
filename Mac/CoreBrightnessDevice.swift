import CoreGraphics
import CoreHID
import Foundation
import os

private let brightnessLog = Logger(subsystem: "WiredPad", category: "brightness")

/// A separate virtual monitor control, so the touch driver's primary usage stays unchanged.
/// corebrightnessd drives a display's brightness through this HID when the display reports
/// Apple's legacy display IDs (see `VirtualDisplay.m`); it looks the HID up by Apple's USB
/// vendor ID, the display's product ID, the Monitor usage, and the display serial as eight
/// hex digits in the HID serial number, then reads these elements.
final class CoreBrightnessDevice: HIDVirtualDeviceDelegate, @unchecked Sendable {
    static let productID: UInt32 = 0x9227
    private static let brightnessReport: UInt8 = 1
    private static let macModeReport: UInt8 = 4
    /// corebrightnessd takes any input in this report as a brightness change made on the display.
    private static let brightnessChangeReport: UInt8 = 0x10
    /// corebrightnessd writes back what it was told within a step of the 0...maximum range.
    private static let writeBackTolerance = 0.005
    /// The iPad reports its brightness in steps of 0.05, so a closer value is its own rounding.
    private static let iPadRounding = 0.03
    /// The iPad answers a Mac change late and rounded; reports this soon after one are echoes.
    private static let echoWindow: Duration = .seconds(1)
    private static let maximum: UInt16 = 1023

    private let device: HIDVirtualDevice
    private let lock = NSLock()
    private var level: Double = 0.5
    private var lastMacChange: ContinuousClock.Instant?
    private var macMode: UInt8 = 0
    private let onSet: (Double) -> Void

    init?(displayID: UInt32, onSet: @escaping (Double) -> Void) {
        let displayUUID = WiredPadCopyDisplayUUID(displayID).map { String(cString: $0) }
        let descriptor = Data([
            0x05, 0x80, 0x09, 0x01, 0xA1, 0x01,
            0x85, Self.brightnessReport,
            0x06, 0x82, 0x00, 0x09, 0x10, 0x15, 0x00, 0x26, 0xFF, 0x03,
            0x75, 0x10, 0x95, 0x01, 0xB1, 0x02, // Brightness, 0...maximum
            // No ambient light control elements: the iPad cannot hand its auto-brightness
            // to an app, and their presence makes macOS offer an automatic brightness switch.
            0x06, 0x92, 0xFF,
            0x85, Self.macModeReport,
            0x09, 0xE1, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x08, 0xB1, 0x02, // Host-controlled ("Mac") mode
            0x06, 0x82, 0x00,
            0x85, Self.brightnessChangeReport,
            0x09, 0x10, 0x15, 0x00, 0x26, 0xFF, 0x03,
            0x75, 0x10, 0x81, 0x02, // Brightness changed on the iPad
            0xC0
        ])
        var extra: [String: AnyObject] = ["CGDirectDisplayID": NSNumber(value: displayID)]
        if let displayUUID {
            extra["DisplayIdentifier"] = displayUUID as NSString
            extra["kUSBContainerID"] = displayUUID as NSString
        }
        let properties = HIDVirtualDevice.Properties(
            descriptor: descriptor,
            vendorID: 0x05AC,
            productID: Self.productID,
            product: "WiredPad Brightness",
            manufacturer: "WiredPad",
            serialNumber: String(format: "%08lX", CGDisplaySerialNumber(displayID)),
            extraProperties: extra
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.device = device
        self.onSet = onSet
    }

    func activate() async {
        await device.activate(delegate: self)
    }

    /// Starts from the iPad's level without telling macOS.
    func updateFromIPad(_ value: Double) {
        guard value.isFinite else { return }
        lock.lock(); level = min(1, max(0, value)); lock.unlock()
    }

    /// Takes a level the iPad reported unless it is the iPad answering a Mac change.
    private func acceptIPadLevel(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let clamped = min(1, max(0, value))
        lock.lock(); defer { lock.unlock() }
        if let lastMacChange, ContinuousClock.now - lastMacChange < Self.echoWindow { return false }
        guard abs(clamped - level) >= Self.iPadRounding else { return false }
        level = clamped
        return true
    }

    /// Takes a level macOS wrote unless it is macOS repeating what the iPad reported.
    private func acceptMacLevel(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard abs(value - level) >= Self.writeBackTolerance else { return false }
        level = value
        lastMacChange = .now
        return true
    }

    /// Tells macOS about a change made on the iPad, so its slider follows.
    func reportFromIPad(_ value: Double) async {
        guard acceptIPadLevel(value) else { return }
        brightnessLog.info("iPad changed to \(value, format: .fixed(precision: 3))")
        let raw = UInt16((currentLevel() * Double(Self.maximum)).rounded())
        do {
            try await device.dispatchInputReport(
                data: Data([Self.brightnessChangeReport, UInt8(truncatingIfNeeded: raw),
                            UInt8(truncatingIfNeeded: raw >> 8)]),
                timestamp: SuspendingClock().now)
        } catch {
            brightnessLog.error("input report failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func currentLevel() -> Double {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    private func setMacMode(_ value: UInt8) {
        lock.lock(); macMode = value; lock.unlock()
    }

    private func currentMacMode() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        return macMode
    }

    /// Feature payloads may arrive with or without their leading report ID.
    private static func payload(_ data: Data, id: HIDReportID?, length: Int) -> (UInt8, [UInt8])? {
        let bytes = [UInt8](data)
        if bytes.count == length + 1 { return (bytes[0], Array(bytes.dropFirst())) }
        if bytes.count == length, let id { return (id.rawValue, bytes) }
        return nil
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        guard type == .feature else { return }
        if let (report, bytes) = Self.payload(data, id: id, length: 2), report == Self.brightnessReport {
            let raw = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            let value = min(1, Double(raw) / Double(Self.maximum))
            // macOS writes back what the iPad just reported; forwarding that would pin the
            // iPad to a fixed level and stop its own automatic brightness.
            guard acceptMacLevel(value) else {
                brightnessLog.info("SET raw=\(raw) matches the iPad, not forwarded")
                return
            }
            brightnessLog.info("SET raw=\(raw) normalized=\(value, format: .fixed(precision: 3))")
            onSet(value)
        } else if let (report, bytes) = Self.payload(data, id: id, length: 1), report == Self.macModeReport {
            setMacMode(bytes[0])
            brightnessLog.info("Mac mode=\(bytes[0])")
        } else {
            brightnessLog.info("ignored feature report id=\(String(describing: id), privacy: .public) bytes=\(data.count)")
        }
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        guard type == .feature, let report = id?.rawValue else { return Data() }
        switch report {
        case Self.brightnessReport:
            let raw = UInt16((currentLevel() * Double(Self.maximum)).rounded())
            brightnessLog.debug("GET raw=\(raw)")
            return Data([report, UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8)])
        case Self.macModeReport:
            return Data([report, currentMacMode()])
        default:
            return Data()
        }
    }
}
