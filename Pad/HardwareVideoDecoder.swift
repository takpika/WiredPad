import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

enum HardwareVideoDecoderError: Error, LocalizedError {
    case operation(String, OSStatus)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case let .operation(name, status): return L10n.tr("ipad.error.decode.operation", L10n.tr(name), status)
        case .invalidFormat: return L10n.tr("ipad.error.decode.format")
        }
    }
}

final class HardwareVideoDecoder {
    private var session: VTDecompressionSession?
    private var description: CMVideoFormatDescription?
    private var currentFormat: VideoFormat?
    private var frameNumber: Int64 = 0
    private let onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    deinit { reset() }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        description = nil
        currentFormat = nil
        frameNumber = 0
    }

    func configure(_ format: VideoFormat) throws {
        guard ["hevc", "h264"].contains(format.codec),
              format.parameterSets.count == (format.codec == "hevc" ? 3 : 2),
              format.width > 0, format.height > 0 else { throw HardwareVideoDecoderError.invalidFormat }
        if format == currentFormat { return }
        reset()

        let sets = format.parameterSets.map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map(\.length)
        var createdDescription: CMVideoFormatDescription?
        let formatStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                guard let parameterPointers = pointerBuffer.baseAddress,
                      let parameterSizes = sizeBuffer.baseAddress else { return OSStatus(-1) }
                if format.codec == "hevc" {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: parameterPointers, parameterSetSizes: parameterSizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &createdDescription
                    )
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: parameterPointers, parameterSetSizes: parameterSizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &createdDescription
                )
            }
        }
        guard formatStatus == noErr, let createdDescription else {
            throw HardwareVideoDecoderError.operation("decode.stage.format", formatStatus)
        }

        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: hardwareDecodeOutput,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var createdSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: createdDescription,
            decoderSpecification: specification, imageBufferAttributes: nil,
            outputCallback: &callback, decompressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw HardwareVideoDecoderError.operation("decode.stage.session", status)
        }
        session = createdSession
        description = createdDescription
        currentFormat = format
        let realTime = VTSessionSetProperty(createdSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard realTime == noErr else { throw HardwareVideoDecoderError.operation("decode.stage.realtime", realTime) }
    }

    func decode(_ packet: Data) throws {
        guard let session, let description, packet.count > 1 else { throw HardwareVideoDecoderError.invalidFormat }
        let compressed = packet.dropFirst()
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: compressed.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: compressed.count, flags: 0, blockBufferOut: &block
        )
        guard created == noErr, let block else { throw HardwareVideoDecoderError.operation("decode.stage.buffer", created) }
        let copied = compressed.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: compressed.count)
        }
        guard copied == noErr else { throw HardwareVideoDecoderError.operation("decode.stage.copy", copied) }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: frameNumber, timescale: 30),
                                        decodeTimeStamp: .invalid)
        frameNumber += 1
        var sampleSize = compressed.count
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { throw HardwareVideoDecoderError.operation("decode.stage.sample", sampleStatus) }
        var info = VTDecodeInfoFlags()
        let decoded = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &info
        )
        guard decoded == noErr else { throw HardwareVideoDecoderError.operation("decode.stage.frame", decoded) }
    }

    fileprivate func output(_ image: CVPixelBuffer) { onFrame(image) }
}

private let hardwareDecodeOutput: VTDecompressionOutputCallback = { refcon, _, status, _, image, _, _ in
    guard status == noErr, let refcon, let image else { return }
    Unmanaged<HardwareVideoDecoder>.fromOpaque(refcon).takeUnretainedValue().output(image)
}
