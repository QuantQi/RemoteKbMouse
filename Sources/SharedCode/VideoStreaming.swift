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
            codecType: kCMVideoCodecType_HEVC,  // H.265/HEVC - better compression
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
        
        // Configure for ULTRA LOW LATENCY streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)  // No B-frames
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)  // Keyframe every 1 second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        
        // Lower bitrate - HEVC is ~50% more efficient than H.264
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (50_000_000) as CFNumber)  // 50 Mbps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [80_000_000, 1] as CFArray)  // Max 80 Mbps
        
        // Low latency tuning
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)  // Keep quality
        
        // Use hardware encoder explicitly
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("H264 Encoder initialized (low-latency): \(width)x\(height) @ \(fps)fps")
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
        
        // Check if keyframe - kCMSampleAttachmentKey_NotSync absent or false means it's a sync frame (keyframe)
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            // If NotSync key is missing or false, it's a keyframe
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyframe = !notSync
        } else {
            // No attachments means it's a keyframe (first frame)
            isKeyframe = true
        }
        
        // For keyframes, prepend VPS/SPS/PPS (HEVC has VPS unlike H.264)
        var nalData = Data()
        
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get VPS (index 0 for HEVC)
                var vpsSize: Int = 0
                var vpsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                
                if let vps = vpsPointer {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    nalData.append(UnsafeBufferPointer(start: vps, count: vpsSize))
                }
                
                // Get SPS (index 1 for HEVC)
                var spsSize: Int = 0
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                
                if let sps = spsPointer {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }
                
                // Get PPS (index 2 for HEVC)
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 2, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                
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

// MARK: - HEVC Decoder

public class H264Decoder {  // Keep name for compatibility
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vpsData: Data?
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
        // Parse NAL units with Annex B start codes (0x00 0x00 0x00 0x01)
        var nalUnits: [(type: UInt8, data: Data)] = []
        var i = 0
        
        while i < nalData.count {
            // Find start code (0x00 0x00 0x00 0x01)
            if i + 4 <= nalData.count &&
               nalData[i] == 0 && nalData[i + 1] == 0 && 
               nalData[i + 2] == 0 && nalData[i + 3] == 1 {
                
                let nalStart = i + 4  // After start code
                
                // Find next start code or end of data
                var nalEnd = nalData.count
                for j in nalStart..<(nalData.count - 3) {
                    if nalData[j] == 0 && nalData[j + 1] == 0 && 
                       nalData[j + 2] == 0 && nalData[j + 3] == 1 {
                        nalEnd = j
                        break
                    }
                }
                
                if nalStart < nalEnd {
                    // HEVC NAL type is in bits 1-6 of first byte (shifted right by 1)
                    let nalType = (nalData[nalStart] >> 1) & 0x3F
                    let nalDataSlice = nalData.subdata(in: nalStart..<nalEnd)
                    nalUnits.append((nalType, nalDataSlice))
                }
                
                i = nalEnd
            } else {
                i += 1
            }
        }
        
        // Process NAL units in order (HEVC NAL types)
        for nal in nalUnits {
            switch nal.type {
            case 32:  // VPS
                if vpsData != nal.data {
                    print("Decoder: Received VPS (\(nal.data.count) bytes)")
                    vpsData = nal.data
                    // Invalidate existing session if VPS changes
                    if decompressionSession != nil {
                        VTDecompressionSessionInvalidate(decompressionSession!)
                        decompressionSession = nil
                        formatDescription = nil
                    }
                }
            case 33:  // SPS
                if spsData != nal.data {
                    print("Decoder: Received SPS (\(nal.data.count) bytes)")
                    spsData = nal.data
                }
            case 34:  // PPS
                if ppsData != nal.data {
                    print("Decoder: Received PPS (\(nal.data.count) bytes)")
                    ppsData = nal.data
                }
                // Try to create session after receiving PPS (need VPS, SPS, PPS)
                tryCreateDecompressionSession()
            case 19, 20:  // IDR_W_RADL, IDR_N_LP (keyframes)
                tryCreateDecompressionSession()  // Ensure session exists
                decodeVideoNAL(nal.data, isIDR: true)
            case 1, 0:  // TRAIL_R, TRAIL_N (non-IDR slices)
                decodeVideoNAL(nal.data, isIDR: false)
            default:
                // Other NAL types (SEI, etc.) - ignore for now
                break
            }
        }
    }
    
    private func tryCreateDecompressionSession() {
        guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return }
        guard decompressionSession == nil else { return }
        
        // Debug: print VPS/SPS/PPS info
        print("Decoder: VPS (\(vps.count) bytes), SPS (\(sps.count) bytes), PPS (\(pps.count) bytes)")
        
        // Convert Data to [UInt8] arrays to get stable pointers
        let vpsBytes = [UInt8](vps)
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        
        var formatDesc: CMVideoFormatDescription?
        let status = vpsBytes.withUnsafeBufferPointer { vpsPointer in
            spsBytes.withUnsafeBufferPointer { spsPointer in
                ppsBytes.withUnsafeBufferPointer { ppsPointer in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        vpsPointer.baseAddress!,
                        spsPointer.baseAddress!,
                        ppsPointer.baseAddress!
                    ]
                    let parameterSetSizes: [Int] = [vpsBytes.count, spsBytes.count, ppsBytes.count]
                    
                    return parameterSetPointers.withUnsafeBufferPointer { pointersBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointersBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &formatDesc
                            )
                        }
                    }
                }
            }
        }
        
        if status != noErr {
            print("Failed to create HEVC format description: \(status)")
            return
        }
        
        guard let desc = formatDesc else {
            print("Format description is nil")
            return
        }
        
        // Debug: print dimensions from format description
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        print("Decoder: HEVC format description created: \(dimensions.width)x\(dimensions.height)")
        
        formatDescription = desc
        
        // Decoder specification - prefer hardware but don't require it
        let decoderSpec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        
        // Output directly to GPU-compatible buffer for Metal/CALayer display
        let destImageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destImageBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        
        guard createStatus == noErr, let session = session else {
            print("Failed to create decompression session: \(createStatus)")
            return
        }
        
        // Set real-time property after session creation
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        decompressionSession = session
        print("H264 Decoder initialized")
    }
    
    private func decodeVideoNAL(_ nalData: Data, isIDR: Bool) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { 
            if isIDR {
                print("Decoder: Cannot decode IDR - no session")
            }
            return 
        }
        
        // Convert to AVCC format (length-prefixed)
        var length = UInt32(nalData.count).bigEndian
        var lengthPrefixedData = Data(bytes: &length, count: 4)
        lengthPrefixedData.append(nalData)
        
        // Create block buffer with a copy of the data (not a reference)
        var blockBuffer: CMBlockBuffer?
        let dataCount = lengthPrefixedData.count
        
        let status = lengthPrefixedData.withUnsafeBytes { pointer -> OSStatus in
            // First create an empty block buffer
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,  // Let it allocate
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            
            guard status == noErr, let buffer = blockBuffer else { return status }
            
            // Copy data into the block buffer
            status = CMBlockBufferReplaceDataBytes(
                with: pointer.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataCount
            )
            
            return status
        }
        
        guard status == noErr, let buffer = blockBuffer else { return }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataCount
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
        
        let flags: VTDecodeFrameFlags = []  // Synchronous decode
        var infoFlags: VTDecodeInfoFlags = []
        
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &infoFlags) { [weak self] status, flags, imageBuffer, pts, duration in
            if status != noErr {
                print("Decoder: Frame decode callback error: \(status)")
                return
            }
            guard let pixelBuffer = imageBuffer else { 
                print("Decoder: No pixel buffer in callback")
                return 
            }
            // Debug: log successful decode
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("Decoder: Decoded frame \(w)x\(h)")
            self?.onDecodedFrame?(pixelBuffer, pts)
        }
        
        if decodeStatus != noErr {
            print("Decoder: VTDecompressionSessionDecodeFrame error: \(decodeStatus)")
        }
    }
}
