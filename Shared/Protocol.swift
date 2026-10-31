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
    static let version = 3
    static let port: UInt16 = 41027
    static let maxPayload = 12 * 1024 * 1024

    static func packet(_ type: WireType, _ payload: Data) -> Data {
        var result = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}
