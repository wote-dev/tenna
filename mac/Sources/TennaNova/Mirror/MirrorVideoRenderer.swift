import AVFoundation
import CoreMedia
import QuartzCore

/// Decodes H.264 access units through VideoToolbox and presents them without adding a
/// playback clock. Mirroring is live UI, so an old frame is always worse than no frame.
final class MirrorVideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    var onRecoveryNeeded: ((String) -> Void)?

    private var format: CMVideoFormatDescription?
    private var generation: Int?
    private var sessionId: String?
    private var parameterSets: (sps: Data, pps: Data)?
    private var droppingUntilKeyframe = false

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.04, alpha: 1)
    }

    func configure(_ config: MirrorConfig) {
        precondition(Thread.isMainThread)
        if generation != config.generation || parameterSets?.sps != config.sps ||
            parameterSets?.pps != config.pps {
            layer.sampleBufferRenderer.flush()
        }
        guard let description = Self.makeFormat(sps: config.sps, pps: config.pps) else {
            recover(sessionId: config.sessionId)
            return
        }
        format = description
        generation = config.generation
        sessionId = config.sessionId
        parameterSets = (config.sps, config.pps)
        droppingUntilKeyframe = true
    }

    func enqueue(_ packet: MirrorVideoPacket) {
        precondition(Thread.isMainThread)
        guard packet.generation == generation, let format else { return }
        if layer.status == .failed {
            recover(sessionId: sessionId)
            return
        }
        if !layer.sampleBufferRenderer.isReadyForMoreMediaData {
            if !droppingUntilKeyframe {
                droppingUntilKeyframe = true
                onRecoveryNeeded?(sessionId ?? "")
            }
            return
        }
        if droppingUntilKeyframe {
            guard packet.keyframe else { return }
            layer.sampleBufferRenderer.flush()
            droppingUntilKeyframe = false
        }
        guard let sample = Self.makeSample(packet, format: format) else {
            recover(sessionId: sessionId)
            return
        }
        layer.sampleBufferRenderer.enqueue(sample)
    }

    func reset() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { self.reset() }
            return
        }
        layer.sampleBufferRenderer.flush()
        format = nil
        generation = nil
        sessionId = nil
        parameterSets = nil
        droppingUntilKeyframe = false
    }

    private func recover(sessionId: String?) {
        layer.sampleBufferRenderer.flush()
        droppingUntilKeyframe = true
        if let sessionId, !sessionId.isEmpty { onRecoveryNeeded?(sessionId) }
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { rawSPS in
            pps.withUnsafeBytes { rawPPS in
                guard let spsBase = rawSPS.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = rawPPS.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    private static func makeSample(
        _ packet: MirrorVideoPacket,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        guard let bytes = H264AnnexB.avcc(packet.accessUnit) else { return nil }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(packet.presentationTimeUs),
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !packet.keyframe {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sample
    }
}
