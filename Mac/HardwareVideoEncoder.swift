import CoreMedia
import Foundation
import VideoToolbox

enum HardwareVideoEncoderError: Error, LocalizedError {
    case operation(String, OSStatus)
    var errorDescription: String? {
        if case let .operation(name, status) = self {
            return L10n.tr("mac.error.encode.operation", L10n.tr(name), status)
        }
        return nil
    }
}

final class HardwareVideoEncoder {
    let codec: String
    let width: Int
    let height: Int
    private(set) var frameRate: Int
    private(set) var bitRate: Int

    private var session: VTCompressionSession?
    private let onPacket: (WireType, Data) -> Void
    private var lastFormat: VideoFormat?
    private let statsLock = NSLock()
    private var completedFrames = 0
    private var failedFrames = 0
    private var totalEncodeMS = 0.0

    init(codec: String, width: Int, height: Int, frameRate: Int,
         onPacket: @escaping (WireType, Data) -> Void) throws {
        guard codec == "hevc" || codec == "h264" else {
            throw HardwareVideoEncoderError.operation("encode.stage.codec", -1)
        }
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = min(36_000_000, max(8_000_000, width * height * frameRate / 10))
        self.onPacket = onPacket

        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: codec == "hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: hardwareEncodeOutput,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw HardwareVideoEncoderError.operation("encode.stage.create", status)
        }
        session = created
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel,
                codec == "hevc" ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        try set(kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (frameRate * 2) as CFNumber)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepared == noErr else { throw HardwareVideoEncoderError.operation("encode.stage.prepare", prepared) }
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw HardwareVideoEncoderError.operation("encode.stage.setting", status) }
    }

    func encode(_ sample: CMSampleBuffer) throws {
        guard let session, let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        let refcon = Unmanaged.passRetained(NSNumber(value: ProcessInfo.processInfo.systemUptime)).toOpaque()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixel,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: .invalid, frameProperties: nil, sourceFrameRefcon: refcon, infoFlagsOut: nil
        )
        if status != noErr { Unmanaged<NSNumber>.fromOpaque(refcon).release() }
        guard status == noErr else { throw HardwareVideoEncoderError.operation("encode.stage.frame", status) }
    }

    func setBitRate(_ value: Int) {
        guard let session else { return }
        let adjusted = min(36_000_000, max(4_000_000, value))
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                value: adjusted as CFNumber) == noErr {
            bitRate = adjusted
        }
    }

    func setFrameRate(_ value: Int) {
        guard let session else { return }
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                value: value as CFNumber) == noErr {
            frameRate = value
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: (value * 2) as CFNumber)
        }
    }

    func takeTelemetry(queuedBytes: Int) -> VideoTelemetry {
        statsLock.lock()
        defer { statsLock.unlock() }
        let report = VideoTelemetry(side: "mac", frames: completedFrames, droppedFrames: failedFrames,
                                    averageProcessingMS: completedFrames > 0 ? totalEncodeMS / Double(completedFrames) : 0,
                                    queuedBytes: queuedBytes, bitRate: bitRate)
        completedFrames = 0
        failedFrames = 0
        totalEncodeMS = 0
        return report
    }

    fileprivate func finishFrame(start: Double, status: OSStatus, sample: CMSampleBuffer?) {
        statsLock.lock()
        if status == noErr, sample != nil {
            completedFrames += 1
            totalEncodeMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
        } else { failedFrames += 1 }
        statsLock.unlock()
        if let sample, status == noErr { receive(sample) }
    }

    fileprivate func receive(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sample) {
            var sets: [Data] = []
            for index in 0..<(codec == "hevc" ? 3 : 2) {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let result = codec == "hevc"
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard result == noErr, let pointer else { return }
                sets.append(Data(bytes: pointer, count: size))
            }
            let format = VideoFormat(codec: codec, width: width, height: height, parameterSets: sets)
            if format != lastFormat {
                lastFormat = format
                if let encoded = try? JSONEncoder().encode(format) { onPacket(.videoFormat, encoded) }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var frame = Data(count: length + 1)
        frame[0] = isKeyframe ? 1 : 0
        let copied = frame.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base.advanced(by: 1))
        }
        if copied == noErr { onPacket(.videoFrame, frame) }
    }
}

private let hardwareEncodeOutput: VTCompressionOutputCallback = { refcon, frameRefcon, status, _, sample in
    guard let refcon else { return }
    let start = frameRefcon.map { Unmanaged<NSNumber>.fromOpaque($0).takeRetainedValue().doubleValue } ?? ProcessInfo.processInfo.systemUptime
    Unmanaged<HardwareVideoEncoder>.fromOpaque(refcon).takeUnretainedValue().finishFrame(start: start, status: status, sample: sample)
}
