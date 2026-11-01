import Foundation

enum WireType: UInt8 {
    case frame = 1 // Legacy JPEG frame; protocol 2 does not send it.
    case touches = 2
    case hello = 3
    case videoFormat = 4
    case videoFrame = 5
    case telemetry = 6
    case diagnostics = 7
    case volumeStep = 8
    case pairingRequest = 9
    case pairingKey = 10
    /// Mac to iPad, one byte: 1 while the Mac wants the iPad reachable over AWDL.
    case peerToPeer = 11
    /// iPad to Mac, a `DisplaySize`: the area the video fills changed, after a rotation or
    /// a window resize.
    case displaySize = 12

    // Link layer: every connection starts with a hello/welcome exchange, then carries
    // numbered session data so a session can move between USB and Wi-Fi without loss.
    case linkHello = 20
    case linkWelcome = 21
    case data = 22
    case ack = 23
    case heartbeat = 24
    /// Per-link round-trip check: the receiver echoes the payload back as `linkPong`.
    case linkPing = 25
    case linkPong = 26
    /// Filler the receiver ignores. It keeps a standby link's radio and TCP connection
    /// busy enough to take over without a stall.
    case padding = 27

    // Wireless pairing by numeric comparison.
    case pairStart = 30
    case pairCommit = 31
    case pairNonce = 32
    case pairReveal = 33
    case pairSealedKey = 34
}

enum LinkKind: String, Codable {
    case usb
    case wifi
}

struct LinkHello: Codable {
    let sessionID: UUID
    let macID: String
    let macName: String
    let kind: LinkKind
    let received: UInt64
    /// True when this link should join an existing session rather than start one.
    let resume: Bool
}

struct LinkWelcome: Codable {
    let sessionID: UUID
    let iPadID: String
    let iPadName: String
    let received: UInt64
    let resumed: Bool
    /// How the iPad's end of this link is connected.
    var interface: InterfaceClass? = nil
}

/// How one end of a network link is attached.
enum InterfaceClass: String, Codable {
    case wired, wifi, peerToPeer, wifiAware, other
}

/// Network paths between the Mac and the iPad, best first. USB always comes before all of them.
enum NetworkPath: Int, Comparable, CaseIterable {
    case wiredLAN, peerToPeer, wifiAware, wifiLAN

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Preference among all links, lower is better. USB is 0.
    var rank: Int { rawValue + 1 }

    init?(rank: Int) { self.init(rawValue: rank - 1) }

    /// A path counts as wired only when neither end uses a radio.
    init(mac: InterfaceClass, iPad: InterfaceClass?) {
        if mac == .peerToPeer || iPad == .peerToPeer {
            self = .peerToPeer
        } else if mac == .wifiAware || iPad == .wifiAware {
            self = .wifiAware
        } else if mac == .wired && iPad == .wired {
            self = .wiredLAN
        } else {
            self = .wifiLAN
        }
    }
}

struct PairingKeyMessage: Codable {
    let iPadID: String
    let iPadName: String
    let key: Data
}

struct TouchPoint: Codable {
    let id: Int
    let x: Double
    let y: Double
    let down: Bool
}

struct TouchPacket: Codable {
    let points: [TouchPoint]
}

struct DisplayHello: Codable {
    let width: Int
    let height: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let protocolVersion: Int
    let hardwareDecoders: [String]
    let maximumFramesPerSecond: Int
    let pixelsPerInch: Int
}

/// The video area in pixels, as it is oriented on the iPad, and in points.
struct DisplaySize: Codable, Equatable {
    let width: Int
    let height: Int
    let logicalWidth: Int
    let logicalHeight: Int
}

struct VideoFormat: Codable, Equatable {
    let codec: String
    let width: Int
    let height: Int
    let parameterSets: [Data]
}

struct VideoTelemetry: Codable {
    let side: String
    let frames: Int
    let droppedFrames: Int
    let averageProcessingMS: Double
    let queuedBytes: Int
    let bitRate: Int
}

struct DiagnosticsControl: Codable {
    let visible: Bool
}

struct VolumeStep: Codable {
    let direction: Int
}

enum Wire {
    static let version = 4
    static let port: UInt16 = 41027
    static let sessionService = "_wiredpad._tcp"
    static let pairingService = "_wiredpad-pair._tcp"
    static let maxPayload = 12 * 1024 * 1024

    static func packet(_ type: WireType, _ payload: Data) -> Data {
        var result = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}
