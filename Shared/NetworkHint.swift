import CoreBluetooth
import Foundation
import Network

/// A small Bluetooth LE side channel. The iPad advertises whether it is on a Wi-Fi network and
/// where it listens there, so the host learns at once when the iPad joins or leaves one and can
/// connect without waiting for a link to time out or for Bonjour to catch up. It only carries
/// hints: every link is still authenticated with the pairing key, so a forged hint can at most
/// make the host try a path.
enum NetworkHint {
    static let service = CBUUID(string: "6B1D5A40-2F7C-4C55-9C2E-57A1D0C9E3B1")
    static let state = CBUUID(string: "6B1D5A41-2F7C-4C55-9C2E-57A1D0C9E3B1")

    struct State: Equatable {
        let deviceID: UUID
        let onWiFiNetwork: Bool
        /// The iPad's IPv4 address on its Wi-Fi network and the port its Wi-Fi listener uses.
        var address: IPv4Address?
        var port: UInt16?

        /// 16 bytes of device ID, one byte of flags, then optionally 4 bytes of address and 2 of
        /// port: 23 bytes at most, well within a Bluetooth LE packet.
        var encoded: Data {
            var data = withUnsafeBytes(of: deviceID.uuid) { Data($0) }
            data.append(onWiFiNetwork ? 1 : 0)
            if let address, let port {
                data.append(address.rawValue)
                data.append(UInt8(port >> 8))
                data.append(UInt8(port & 0xff))
            }
            return data
        }

        init(deviceID: UUID, onWiFiNetwork: Bool, address: IPv4Address? = nil, port: UInt16? = nil) {
            self.deviceID = deviceID
            self.onWiFiNetwork = onWiFiNetwork
            self.address = address
            self.port = port
        }

        init?(_ data: Data) {
            guard data.count == 17 || data.count == 23 else { return nil }
            let bytes = Array(data)
            deviceID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            onWiFiNetwork = bytes[16] & 1 == 1
            if bytes.count == 23 {
                address = IPv4Address(Data(bytes[17..<21]))
                port = UInt16(bytes[21]) << 8 | UInt16(bytes[22])
            }
        }
    }
}
