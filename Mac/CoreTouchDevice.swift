import CoreGraphics
import CoreHID
import Foundation

/// A virtual HID device keeps its delegate for as long as it lives, and the device stays in
/// the system until it is freed. Handing it this instead of the owner breaks that cycle, so a
/// device dropped by its owner leaves the system.
final class WeakHIDDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    private weak var target: (AnyObject & HIDVirtualDeviceDelegate)?

    init(_ target: AnyObject & HIDVirtualDeviceDelegate) { self.target = target }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        try await target?.hidVirtualDevice(device, receivedSetReportRequestOfType: type, id: id, data: data)
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        try await target?.hidVirtualDevice(device, receivedGetReportRequestOfType: type, id: id,
                                           maxSize: maxSize) ?? Data()
    }
}

final class CoreTouchDevice: HIDVirtualDeviceDelegate, @unchecked Sendable {
    private let device: HIDVirtualDevice

    init?(displayID: UInt32) {
        let displayIdentifier = WiredPadCopyDisplayUUID(displayID).map { String(cString: $0) }
        NSLog("WiredPad display %u UUID %@", displayID, displayIdentifier ?? "unavailable")
        let properties = HIDVirtualDevice.Properties(
            descriptor: WiredPadTouchReportDescriptor() as Data,
            vendorID: 0x5750,
            productID: 1,
            product: "WiredPad 10-point Touchscreen",
            manufacturer: "WiredPad",
            serialNumber: displayIdentifier ?? "1",
            extraProperties: ["CGDirectDisplayID": NSNumber(value: displayID)]
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.device = device
    }

    func activate() async {
        await device.activate(delegate: WeakHIDDelegate(self))
    }

    func send(_ points: [TouchPoint]) async throws {
        var report = [UInt8](repeating: 0, count: 62)
        report[0] = 1
        for point in points where point.down && (0..<10).contains(point.id) {
            let offset = 1 + point.id * 6
            report[offset] = 3
            report[offset + 1] = UInt8(point.id)
            let x = UInt16((min(1, max(0, point.x)) * 32767).rounded())
            let y = UInt16((min(1, max(0, point.y)) * 32767).rounded())
            report[offset + 2] = UInt8(truncatingIfNeeded: x)
            report[offset + 3] = UInt8(truncatingIfNeeded: x >> 8)
            report[offset + 4] = UInt8(truncatingIfNeeded: y)
            report[offset + 5] = UInt8(truncatingIfNeeded: y >> 8)
            report[61] += 1
        }
        try await device.dispatchInputReport(data: Data(report), timestamp: SuspendingClock().now)
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        // Report 1's feature field advertises the maximum contact count.
        NSLog("WiredPad HID get report type=%@ id=%@ maxSize=%d", String(describing: type), String(describing: id), maxSize)
        guard type == .feature, maxSize >= 2 else { return Data() }
        return Data([1, 10])
    }
}

/// The Pencil, on a device of its own. The touch driver matches it too and hands WindowServer
/// tablet events with the Pencil's pressure and tilt.
final class CorePenDevice: HIDVirtualDeviceDelegate, @unchecked Sendable {
    private let device: HIDVirtualDevice

    init?() {
        let properties = HIDVirtualDevice.Properties(
            descriptor: WiredPadPenReportDescriptor() as Data,
            vendorID: 0x5750,
            productID: 3,
            product: "WiredPad Pencil",
            manufacturer: "WiredPad"
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.device = device
    }

    func activate() async {
        await device.activate(delegate: WeakHIDDelegate(self))
    }

    /// Report 2: the Pencil's position, pressure, and tilt. `screen` is the display's rectangle
    /// on the global display space, where the driver places the Pencil.
    func send(_ sample: PenSample, on screen: CGRect) async throws {
        func fixed(_ value: Double) -> [UInt8] {
            let raw = Int32(value * 65536)
            return (0..<4).map { UInt8(truncatingIfNeeded: raw >> ($0 * 8)) }
        }
        // Altitude and azimuth as tilt toward x and y, the way digitizers report it.
        let altitude = max(1, min(90, sample.altitude)) * .pi / 180
        let azimuth = sample.azimuth * .pi / 180
        func tilt(_ component: Double) -> UInt8 {
            UInt8(bitPattern: Int8(max(-90, min(90, (atan(component / tan(altitude)) * 180 / .pi).rounded()))))
        }
        let x = screen.minX + min(1, max(0, sample.x)) * screen.width
        let y = screen.minY + min(1, max(0, sample.y)) * screen.height
        let pressure = UInt16((min(1, max(0, sample.touching ? sample.pressure : 0)) * 32767).rounded())
        let flags: UInt8 = (sample.touching ? 1 : 0) | (sample.inRange ? 1 << 4 : 0)
        let report: [UInt8] = [2, flags] + fixed(x) + fixed(y) +
            [UInt8(truncatingIfNeeded: pressure), UInt8(truncatingIfNeeded: pressure >> 8),
             tilt(cos(azimuth)), tilt(sin(azimuth)), 0, 0]
        try await device.dispatchInputReport(data: Data(report), timestamp: SuspendingClock().now)
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        Data()
    }
}

final class CoreVolumeDevice: HIDVirtualDeviceDelegate, @unchecked Sendable {
    private let device: HIDVirtualDevice

    init?() {
        let descriptor = Data([
            0x05, 0x0C,       // Consumer usage page
            0x09, 0x01,       // Consumer Control
            0xA1, 0x01,       // Application collection
            0x85, 0x02,       // Report ID 2
            0x15, 0x00, 0x25, 0x01,
            0x09, 0xE9,       // Volume Increment
            0x09, 0xEA,       // Volume Decrement
            0x75, 0x01, 0x95, 0x02, 0x81, 0x02,
            0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
            0xC0
        ])
        let properties = HIDVirtualDevice.Properties(
            descriptor: descriptor,
            vendorID: 0x5750,
            productID: 2,
            product: "WiredPad Volume Keys",
            manufacturer: "WiredPad"
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.device = device
    }

    func activate() async {
        await device.activate(delegate: WeakHIDDelegate(self))
    }

    func send(_ direction: Int) async throws {
        guard direction == 1 || direction == -1 else { return }
        try await device.dispatchInputReport(
            data: Data([2, direction == 1 ? 1 : 2]), timestamp: SuspendingClock().now
        )
        try await device.dispatchInputReport(data: Data([2, 0]), timestamp: SuspendingClock().now)
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        Data()
    }
}
