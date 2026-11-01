import CoreBluetooth
import Foundation

/// The host end of the Bluetooth side channel: finds nearby WiredPad iPads, subscribes to
/// their network state and reports every change.
final class NetworkHintWatcher: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Called on the main queue with an iPad's latest network state.
    var onHint: ((NetworkHint.State) -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        linkLog.info("Bluetooth state \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [NetworkHint.service], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        linkLog.info("Bluetooth found an iPad")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        linkLog.info("Bluetooth connected to an iPad")
        peripheral.discoverServices([NetworkHint.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        linkLog.error("Bluetooth connection failed: \(error?.localizedDescription ?? "", privacy: .public)")
        peripherals[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Reconnect whenever it comes back in range; the request does not time out.
        linkLog.info("Bluetooth disconnected: \(error?.localizedDescription ?? "", privacy: .public)")
        central.connect(peripheral)
    }

    /// The iPad app restarted and set up its service again while the Bluetooth link stayed up.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([NetworkHint.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == NetworkHint.service {
            peripheral.discoverCharacteristics([NetworkHint.state], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == NetworkHint.state {
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else {
            linkLog.error("Bluetooth read failed: \(error?.localizedDescription ?? "", privacy: .public)")
            return
        }
        linkLog.info("Bluetooth hint of \(value.count) bytes")
        guard let state = NetworkHint.State(value) else {
            // A notification can be cut to the link's packet size; read the whole value instead.
            peripheral.readValue(for: characteristic)
            return
        }
        onHint?(state)
    }
}
