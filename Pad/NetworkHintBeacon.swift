import CoreBluetooth
import Foundation
import Network

/// The iPad end of the Bluetooth side channel: advertises the WiredPad service and keeps a
/// readable, notifying characteristic with this iPad's network state.
final class NetworkHintBeacon: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private let characteristic = CBMutableCharacteristic(type: NetworkHint.state, properties: [.read, .notify],
                                                         value: nil, permissions: [.readable])
    private var state: NetworkHint.State
    private var pendingNotify = false

    init(deviceID: UUID) {
        state = NetworkHint.State(deviceID: deviceID, onWiFiNetwork: true)
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func update(onWiFiNetwork: Bool, port: UInt16?) {
        let address = onWiFiNetwork ? Self.wifiAddress() : nil
        let next = NetworkHint.State(deviceID: state.deviceID, onWiFiNetwork: onWiFiNetwork,
                                     address: address, port: address == nil ? nil : port)
        guard next != state else { return }
        state = next
        notify()
    }

    /// The IPv4 address of the Wi-Fi interface, en0 on iPad.
    private static func wifiAddress() -> IPv4Address? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) }
            }
            return IPv4Address(bytes)
        }
        return nil
    }

    private func notify() {
        guard let manager, manager.state == .poweredOn else { return }
        pendingNotify = !manager.updateValue(state.encoded, for: characteristic, onSubscribedCentrals: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let service = CBMutableService(type: NetworkHint.service, primary: true)
        service.characteristics = [characteristic]
        peripheral.removeAllServices()
        peripheral.add(service)
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [NetworkHint.service]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value = state.encoded
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if pendingNotify { notify() }
    }
}
