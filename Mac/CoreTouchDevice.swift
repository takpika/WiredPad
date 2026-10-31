import CoreHID
import Foundation

final class CoreTouchDevice: HIDVirtualDeviceDelegate {
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
        await device.activate(delegate: self)
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

final class CoreVolumeDevice: HIDVirtualDeviceDelegate {
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
        await device.activate(delegate: self)
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
