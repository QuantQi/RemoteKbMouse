import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

// MARK: - H.264 Encoder

public class H264Encoder {
    private var compressionSession: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private var frameCount: Int64 = 0
    private let startTime = CACurrentMediaTime()
    
    public var onEncodedFrame: ((Data, Bool) -> Void)?  // (nalData, isKeyframe)
    
    public init(width: Int32, height: Int32, fps: Int32 = 60) {
        self.width = width
        self.height = height
        self.fps = fps
        setupEncoder()
    }
    
    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }
    
    private func setupEncoder() {
        let encoderSpecification: [String: Any] = [
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as String: true
        ]
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("Failed to create compression session: \(status)")
            return
        }
        
        compressionSession = session
        
        // Configure for low latency streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps * 2 as CFNumber)  // Keyframe every 2 seconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (50_000_000) as CFNumber)  // 50 Mbps for 4K
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [75_000_000, 1] as CFArray)  // Max 75 Mbps
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("H264 Encoder initialized: \(width)x\(height) @ \(fps)fps")
    }
    
    public func encode(pixelBuffer: CVPixelBuffer) {
        guard let session = compressionSession else { return }
        
        let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        frameCount += 1
        
        var flags: VTEncodeInfoFlags = []
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }
            self?.processSampleBuffer(sampleBuffer)
        }
        
        if status != noErr {
            print("Encode error: \(status)")
        }
    }
    
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let pointer = dataPointer else { return }
        
        // Check if keyframe
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? true)
        }
        
        // For keyframes, prepend SPS/PPS
        var nalData = Data()
        
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get SPS
                var spsSize: Int = 0
                var spsCount: Int = 0
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
                
                if let sps = spsPointer {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }
                
                // Get PPS
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                
                if let pps = ppsPointer {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                }
            }
        }
        
        // Convert AVCC to Annex B format (length-prefixed to start-code prefixed)
        var offset = 0
        while offset < length - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
            nalData.append(Data(bytes: pointer.advanced(by: offset + 4), count: Int(nalLength)))
            
            offset += 4 + Int(nalLength)
        }
        
        onEncodedFrame?(nalData, isKeyframe)
    }
    
    public func forceKeyframe() {
        guard let session = compressionSession else { return }
        let props: [String: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        // Next encode will check this
    }
}

// MARK: - H.264 Decoder

public class H264Decoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    
    public var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    
    public init() {}
    
    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
    
    public func decode(nalData: Data) {
        // Parse NAL units
        var offset = 0
        var nalUnits: [(type: UInt8, data: Data)] = []
        
        while offset < nalData.count - 4 {
            // Find start code
            if nalData[offset] == 0 && nalData[offset + 1] == 0 && nalData[offset + 2] == 0 && nalData[offset + 3] == 1 {
                // Find next start code or end
                var nextStart = offset + 4
                while nextStart < nalData.count - 3 {
                    if nalData[nextStart] == 0 && nalData[nextStart + 1] == 0 && nalData[nextStart + 2] == 0 && nalData[nextStart + 3] == 1 {
                        break
                    }
                    nextStart += 1
                }
                
                let nalType = nalData[offset + 4] & 0x1F
                let nalDataSlice = nalData.subdata(in: (offset + 4)..<nextStart)
                nalUnits.append((nalType, nalDataSlice))
                offset = nextStart
            } else {
                offset += 1
            }
        }
        
        for nal in nalUnits {
            switch nal.type {
            case 7:  // SPS
                spsData = nal.data
                tryCreateDecompressionSession()
            case 8:  // PPS
                ppsData = nal.data
                tryCreateDecompressionSession()
            case 5, 1:  // IDR or non-IDR slice
                decodeVideoNAL(nal.data)
            default:
                break
            }
        }
    }
    
    private func tryCreateDecompressionSession() {
        guard let sps = spsData, let pps = ppsData else { return }
        guard decompressionSession == nil else { return }
        
        let parameterSets: [UnsafePointer<UInt8>] = [
            sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
            pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        ]
        let sizes = [sps.count, pps.count]
        
        var formatDesc: CMVideoFormatDescription?
        let status = parameterSets.withUnsafeBufferPointer { paramPointer in
            sizes.withUnsafeBufferPointer { sizesPointer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramPointer.baseAddress!,
                    parameterSetSizes: sizesPointer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        guard status == noErr, let desc = formatDesc else {
            print("Failed to create format description: \(status)")
            return
        }
        
        formatDescription = desc
        
        let decoderParams: [String: Any] = [
            kVTDecompressionPropertyKey_RealTime as String: true
        ]
        
        let destImageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: decoderParams as CFDictionary,
            imageBufferAttributes: destImageBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        
        guard createStatus == noErr, let session = session else {
            print("Failed to create decompression session: \(createStatus)")
            return
        }
        
        decompressionSession = session
        print("H264 Decoder initialized")
    }
    
    private func decodeVideoNAL(_ nalData: Data) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { return }
        
        // Convert to AVCC format (length-prefixed)
        var lengthPrefixedData = Data()
        var length = UInt32(nalData.count).bigEndian
        lengthPrefixedData.append(Data(bytes: &length, count: 4))
        lengthPrefixedData.append(nalData)
        
        var blockBuffer: CMBlockBuffer?
        lengthPrefixedData.withUnsafeBytes { pointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: pointer.baseAddress!),
                blockLength: lengthPrefixedData.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: lengthPrefixedData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard let buffer = blockBuffer else { return }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = lengthPrefixedData.count
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        guard let sample = sampleBuffer else { return }
        
        var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags: VTDecodeInfoFlags = []
        
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &infoFlags) { [weak self] status, flags, imageBuffer, pts, duration in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            self?.onDecodedFrame?(pixelBuffer, pts)
        }
    }
}
