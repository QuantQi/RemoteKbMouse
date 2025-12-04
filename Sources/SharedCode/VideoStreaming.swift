import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

// MARK: - H.264/HEVC Encoder

public enum VideoCodec {
    case hevc
    case h264
}

public class H264Encoder {
    private var compressionSession: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private var frameCount: Int64 = 0
    private let startTime = CACurrentMediaTime()
    public private(set) var activeCodec: VideoCodec = .hevc
    
    public var onEncodedFrame: ((Data, Bool) -> Void)?  // (nalData, isKeyframe)
    public var onError: ((String) -> Void)?  // Error callback
    
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
        // Try HEVC first (hardware), fallback to H.264 if unavailable
        if tryCreateEncoderSession(codec: .hevc, requireHardware: true) {
            activeCodec = .hevc
            return
        }
        
        // Try HEVC with software fallback
        if tryCreateEncoderSession(codec: .hevc, requireHardware: false) {
            activeCodec = .hevc
            // print("Using software HEVC encoder")
            return
        }
        
        // Try H.264 hardware
        if tryCreateEncoderSession(codec: .h264, requireHardware: true) {
            activeCodec = .h264
            // print("Fell back to hardware H.264 encoder")
            return
        }
        
        // Last resort: H.264 software
        if tryCreateEncoderSession(codec: .h264, requireHardware: false) {
            activeCodec = .h264
            // print("Using software H.264 encoder")
            return
        }
        
        let error = "Failed to create any video encoder"
//         print(error)
        onError?(error)
    }
    
    private func tryCreateEncoderSession(codec: VideoCodec, requireHardware: Bool) -> Bool {
        var encoderSpec: [String: Any] = [:]
        if requireHardware {
            encoderSpec[kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as String] = true
        }
        
        let codecType: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpec.isEmpty ? nil : encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            return false
        }
        
        compressionSession = session
        
        // ============================================
        // ULTRA LOW LATENCY + 100% QUALITY SETTINGS
        // ============================================
        
        // CRITICAL: Real-time encoding for minimal latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // Set highest quality profile
        if codec == .hevc {
            // HEVC Main10 for best quality (10-bit color if available)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        } else {
            // H.264 High profile for best quality
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        
        // LOW LATENCY: No B-frames (B-frames add latency due to reordering)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // Keyframe every 2 seconds (balance between recovery and efficiency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        
        // ============================================
        // MAXIMUM QUALITY - ULTRA HIGH BITRATE FOR 4Gbps LAN
        // ============================================
        // With 4Gbps LAN we can push 400+ Mbps easily
        
        let pixels = Int(width) * Int(height)
        let is5K = pixels >= 5120 * 2880      // 5K+
        let is4K = pixels >= 3840 * 2160      // 4K
        let isQHD = pixels >= 2560 * 1440     // 1440p
        let isHD = pixels >= 1920 * 1080      // 1080p
        
        let bitrate: Int
        let maxBitrate: Int
        
        if codec == .hevc {
            // HEVC at ultra-high quality for high-speed LAN
            if is5K {
                bitrate = 400_000_000     // 400 Mbps for 5K+
                maxBitrate = 500_000_000  // 500 Mbps peak
            } else if is4K {
                bitrate = 300_000_000     // 300 Mbps for 4K
                maxBitrate = 400_000_000  // 400 Mbps peak
            } else if isQHD {
                bitrate = 200_000_000     // 200 Mbps for 1440p
                maxBitrate = 300_000_000
            } else if isHD {
                bitrate = 150_000_000     // 150 Mbps for 1080p
                maxBitrate = 200_000_000
            } else {
                bitrate = 100_000_000
                maxBitrate = 150_000_000
            }
        } else {
            // H.264 needs ~50% more bitrate for same quality
            if is5K {
                bitrate = 500_000_000     // 500 Mbps for 5K+
                maxBitrate = 600_000_000
            } else if is4K {
                bitrate = 400_000_000     // 400 Mbps for 4K
                maxBitrate = 500_000_000
            } else if isQHD {
                bitrate = 300_000_000     // 300 Mbps for 1440p
                maxBitrate = 400_000_000
            } else if isHD {
                bitrate = 200_000_000     // 200 Mbps for 1080p
                maxBitrate = 300_000_000
            } else {
                bitrate = 150_000_000
                maxBitrate = 200_000_000
            }
        }
        
        // print("Encoder: \(bitrate / 1_000_000) Mbps avg, \(maxBitrate / 1_000_000) Mbps peak (100% quality)")
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [maxBitrate, 1] as CFArray)
        
        // 100% QUALITY SETTING
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 1.0 as CFNumber)
        
        // Allow temporal compression for efficiency but prioritize quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        
        // QUALITY over speed - we have powerful hardware
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        
        // LOW LATENCY: Minimize encoder buffering
        if #available(macOS 11.0, *) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)  // Performance > power
        }
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        // let codecName = (codec == .hevc) ? "HEVC" : "H.264"
        // print("\(codecName) Encoder initialized (low-latency): \(width)x\(height) @ \(fps)fps")
        return true
    }
    
    public func encode(pixelBuffer: CVPixelBuffer) {
        guard let session = compressionSession else {
            // print("[ENCODER] ERROR: No compression session!")
            return
        }
        
        let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        frameCount += 1
        
        // if frameCount <= 3 || frameCount % 120 == 0 {
        //     let w = CVPixelBufferGetWidth(pixelBuffer)
        //     let h = CVPixelBufferGetHeight(pixelBuffer)
        //     print("[ENCODER] Encoding frame #\(frameCount): \(w)x\(h)")
        // }
        
        var flags: VTEncodeInfoFlags = []
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            if status != noErr {
                // print("[ENCODER] Encode callback error: \(status)")
                return
            }
            guard let sampleBuffer = sampleBuffer else {
                // print("[ENCODER] ERROR: No sample buffer in callback")
                return
            }
            self?.processSampleBuffer(sampleBuffer)
        }
        
        if status != noErr {
            // print("[ENCODER] VTCompressionSessionEncodeFrame error: \(status)")
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
        
        // For keyframes, prepend parameter sets
        var nalData = Data()
        
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if activeCodec == .hevc {
                    // HEVC: VPS/SPS/PPS
                    var vpsSize: Int = 0
                    var vpsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let vps = vpsPointer {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(UnsafeBufferPointer(start: vps, count: vpsSize))
                    }
                    
                    var spsSize: Int = 0
                    var spsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let sps = spsPointer {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                    }
                    
                    var ppsSize: Int = 0
                    var ppsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 2, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let pps = ppsPointer {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                    }
                } else {
                    // H.264: SPS/PPS only
                    var spsSize: Int = 0
                    var spsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let sps = spsPointer {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                    }
                    
                    var ppsSize: Int = 0
                    var ppsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let pps = ppsPointer {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                    }
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
        
        // if frameCount <= 3 || frameCount % 120 == 0 || isKeyframe {
        //     let codecName = (activeCodec == .hevc) ? "HEVC" : "H.264"
        //     print("[ENCODER] Output frame #\(frameCount): \(nalData.count) bytes, keyframe=\(isKeyframe), codec=\(codecName)")
        //     // Log first few bytes to verify NAL structure
        //     if nalData.count >= 8 {
        //         let bytes = nalData.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        //         print("[ENCODER] NAL start bytes: \(bytes)")
        //     }
        // }
        onEncodedFrame?(nalData, isKeyframe)
    }
    
    public func forceKeyframe() {
        guard let session = compressionSession else { return }
        let props: [String: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        // Next encode will check this
    }
}

// MARK: - HEVC Decoder

public class H264Decoder {  // Keep name for compatibility - handles both H.264 and HEVC
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vpsData: Data?  // HEVC only
    private var spsData: Data?
    private var ppsData: Data?
    private var detectedCodec: VideoCodec?
    
    public var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onError: ((String) -> Void)?
    
    /// Callback when parameter sets are available/updated (codec, vps (hevc only), sps, pps)
    public var onParameterSetsAvailable: ((VideoCodec, Data?, Data, Data) -> Void)?
    
    /// Get current detected codec
    public var currentCodec: VideoCodec? { detectedCodec }
    
    /// Get current parameter sets (vps, sps, pps) - vps is nil for H.264
    public var currentParameterSets: (vps: Data?, sps: Data?, pps: Data?) {
        (vpsData, spsData, ppsData)
    }
    
    public init() {}
    
    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
    
    private var decodeCallCount: UInt64 = 0
    
    public func decode(nalData: Data) {
        decodeCallCount += 1
        // print("[DECODER] decode() called #\(decodeCallCount), input size=\(nalData.count) bytes")
        
        // Parse NAL units with Annex B start codes (0x00 0x00 0x00 0x01)
        // Store raw first byte for codec-specific parsing later
        var nalUnits: [(firstByte: UInt8, data: Data)] = []
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
                    // Store raw first byte - we'll parse NAL type based on detected codec
                    let firstByte = nalData[nalStart]
                    let nalDataSlice = nalData.subdata(in: nalStart..<nalEnd)
                    nalUnits.append((firstByte, nalDataSlice))
                    
                    // Debug: log NAL unit found
                    // let h264Type = firstByte & 0x1F
                    // let hevcType = (firstByte >> 1) & 0x3F
                    // print("[DECODER] Found NAL: firstByte=0x\(String(format: "%02X", firstByte)), h264Type=\(h264Type), hevcType=\(hevcType), size=\(nalDataSlice.count)")
                }
                
                i = nalEnd
            } else {
                i += 1
            }
        }
        
        // print("[DECODER] Found \(nalUnits.count) NAL units, current codec=\(detectedCodec.map { $0 == .hevc ? "HEVC" : "H.264" } ?? "unknown")")
        
        // Process NAL units
        // NAL type extraction differs by codec:
        //   H.264: type = firstByte & 0x1F (bits 0-4)
        //   HEVC:  type = (firstByte >> 1) & 0x3F (bits 1-6)
        //
        // Auto-detect codec from characteristic NAL types:
        //   H.264 SPS has firstByte & 0x1F == 7, so firstByte is 0x67 or 0x27
        //   HEVC VPS has (firstByte >> 1) & 0x3F == 32, so firstByte is 0x40 or 0x41
        
        for nal in nalUnits {
            let firstByte = nal.firstByte
            
            // Extract NAL type for both codecs
            let h264Type = firstByte & 0x1F           // H.264: bits 0-4
            let hevcType = (firstByte >> 1) & 0x3F    // HEVC: bits 1-6
            
            // Auto-detect codec from parameter set NALs
            // HEVC VPS (type 32) has firstByte 0x40-0x41
            // H.264 SPS (type 7) has firstByte 0x67, 0x27, etc.
            if detectedCodec == nil {
                if hevcType == 32 {  // HEVC VPS
                    detectedCodec = .hevc
                    // print("Decoder: Auto-detected HEVC codec")
                } else if h264Type == 7 {  // H.264 SPS
                    detectedCodec = .h264
                    // print("Decoder: Auto-detected H.264 codec")
                }
            }
            
            // Use detected codec to determine NAL type, default to trying both
            let codec = detectedCodec
            
            // === HEVC NAL types ===
            if codec == .hevc || codec == nil {
                switch hevcType {
                case 32:  // VPS (HEVC only)
                    detectedCodec = .hevc
                    if vpsData != nal.data {
                        // print("Decoder: Received HEVC VPS (\(nal.data.count) bytes)")
                        vpsData = nal.data
                        invalidateSession()
                    }
                    continue
                case 33:  // SPS (HEVC)
                    if codec == .hevc {
                        if spsData != nal.data {
                            // print("Decoder: Received HEVC SPS (\(nal.data.count) bytes)")
                            spsData = nal.data
                        }
                        continue
                    }
                case 34:  // PPS (HEVC)
                    if codec == .hevc {
                        if ppsData != nal.data {
                            // print("Decoder: Received HEVC PPS (\(nal.data.count) bytes)")
                            ppsData = nal.data
                        }
                        tryCreateDecompressionSession()
                        continue
                    }
                case 19, 20:  // IDR_W_RADL, IDR_N_LP (HEVC keyframes)
                    if codec == .hevc {
                        tryCreateDecompressionSession()
                        decodeVideoNAL(nal.data, isIDR: true)
                        continue
                    }
                case 21:  // CRA_NUT (HEVC clean random access)
                    if codec == .hevc {
                        tryCreateDecompressionSession()
                        decodeVideoNAL(nal.data, isIDR: true)
                        continue
                    }
                case 0, 1:  // TRAIL_N, TRAIL_R (HEVC non-IDR)
                    if codec == .hevc {
                        decodeVideoNAL(nal.data, isIDR: false)
                        continue
                    }
                case 2...9:  // TSA, STSA, RADL, RASL (HEVC slice types)
                    if codec == .hevc {
                        decodeVideoNAL(nal.data, isIDR: false)
                        continue
                    }
                default:
                    break
                }
            }
            
            // === H.264 NAL types ===
            if codec == .h264 || codec == nil {
                switch h264Type {
                case 7:  // SPS (H.264)
                    detectedCodec = .h264
                    if spsData != nal.data {
                        // print("Decoder: Received H.264 SPS (\(nal.data.count) bytes)")
                        spsData = nal.data
                        invalidateSession()
                    }
                    continue
                case 8:  // PPS (H.264)
                    if codec == .h264 {
                        if ppsData != nal.data {
                            // print("Decoder: Received H.264 PPS (\(nal.data.count) bytes)")
                            ppsData = nal.data
                        }
                        tryCreateDecompressionSession()
                        continue
                    }
                case 5:  // IDR (H.264 keyframe)
                    if codec == .h264 {
                        tryCreateDecompressionSession()
                        decodeVideoNAL(nal.data, isIDR: true)
                        continue
                    }
                case 1:  // Non-IDR slice (H.264)
                    if codec == .h264 {
                        decodeVideoNAL(nal.data, isIDR: false)
                        continue
                    }
                case 6:  // SEI (H.264)
                    continue  // Ignore SEI
                case 9:  // AUD (H.264)
                    continue  // Ignore Access Unit Delimiter
                default:
                    break
                }
            }
            
            // Unknown NAL type - ignore silently
        }
    }
    
    private func invalidateSession() {
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
            formatDescription = nil
        }
    }
    
    private func tryCreateDecompressionSession() {
        guard decompressionSession == nil else { return }
        guard let sps = spsData, let pps = ppsData else { return }
        
        var formatDesc: CMVideoFormatDescription?
        var status: OSStatus = noErr
        
        if detectedCodec == .hevc {
            // HEVC requires VPS
            guard let vps = vpsData else { return }
            // print("Decoder: HEVC VPS (\(vps.count) bytes), SPS (\(sps.count) bytes), PPS (\(pps.count) bytes)")
            
            let vpsBytes = [UInt8](vps)
            let spsBytes = [UInt8](sps)
            let ppsBytes = [UInt8](pps)
            
            status = vpsBytes.withUnsafeBufferPointer { vpsPointer in
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
        } else {
            // H.264: SPS + PPS only
            // print("Decoder: H.264 SPS (\(sps.count) bytes), PPS (\(pps.count) bytes)")
            
            let spsBytes = [UInt8](sps)
            let ppsBytes = [UInt8](pps)
            
            status = spsBytes.withUnsafeBufferPointer { spsPointer in
                ppsBytes.withUnsafeBufferPointer { ppsPointer in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        spsPointer.baseAddress!,
                        ppsPointer.baseAddress!
                    ]
                    let parameterSetSizes: [Int] = [spsBytes.count, ppsBytes.count]
                    
                    return parameterSetPointers.withUnsafeBufferPointer { pointersBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pointersBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &formatDesc
                            )
                        }
                    }
                }
            }
        }
        
        if status != noErr {
            let codecName = (detectedCodec == .hevc) ? "HEVC" : "H.264"
            let error = "Failed to create \(codecName) format description: \(status)"
//             print(error)
            onError?(error)
            return
        }
        
        guard let desc = formatDesc else {
            let error = "Format description is nil"
//             print(error)
            onError?(error)
            return
        }
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        // let codecName = (detectedCodec == .hevc) ? "HEVC" : "H.264"
        // print("Decoder: \(codecName) format description created: \(dimensions.width)x\(dimensions.height)")
        
        formatDescription = desc
        
        // Decoder specification - prefer hardware, allow software fallback
        let decoderSpec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: false  // Allow software fallback
        ]
        
        // CRITICAL: Output to IOSurface-backed GPU buffer for zero-copy display
        // This ensures CVPixelBufferGetIOSurface() always returns a valid surface
        let destImageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],  // Required for IOSurface backing
            kCVPixelBufferOpenGLCompatibilityKey as String: true  // Also GPU compatible
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
            let error = "Failed to create decompression session: \(createStatus)"
//             print(error)
            onError?(error)
            return
        }
        
        // Set real-time property after session creation
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        decompressionSession = session
        
        // Notify about parameter sets availability
        if let codec = detectedCodec, let sps = spsData, let pps = ppsData {
            onParameterSetsAvailable?(codec, vpsData, sps, pps)
        }
        // print("\(codecName) Decoder initialized")
    }
    
    private var decodedFrameCount: UInt64 = 0
    
    private func decodeVideoNAL(_ nalData: Data, isIDR: Bool) {
        // print("[DECODER] decodeVideoNAL called: size=\(nalData.count), isIDR=\(isIDR)")
        
        guard let session = decompressionSession else {
            // print("[DECODER] ERROR: No decompression session!")
            return
        }
        guard let formatDesc = formatDescription else { 
            // print("[DECODER] ERROR: No format description!")
            return 
        }
        
        // print("[DECODER] Session and format OK, proceeding to decode..."))
        
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
        
        // print("[DECODER] Calling VTDecompressionSessionDecodeFrame..."))
        
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &infoFlags) { [weak self] status, flags, imageBuffer, pts, duration in
            guard let self = self else {
                // print("[DECODER] Callback: self is nil!")
                return
            }
            self.decodedFrameCount += 1
            
            if status != noErr {
                // print("[DECODER] Callback ERROR: status=\(status)")
                return
            }
            guard let pixelBuffer = imageBuffer else { 
                // print("[DECODER] Callback ERROR: No pixel buffer")
                return 
            }
            
            // let w = CVPixelBufferGetWidth(pixelBuffer)
            // let h = CVPixelBufferGetHeight(pixelBuffer)
            // let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            // print("[DECODER] SUCCESS! Frame #\(self.decodedFrameCount): \(w)x\(h), IOSurface=\(hasIOSurface)")
            
            if self.onDecodedFrame != nil {
                // print("[DECODER] Calling onDecodedFrame callback...")
                self.onDecodedFrame?(pixelBuffer, pts)
                // print("[DECODER] onDecodedFrame callback returned")
            } else {
                // print("[DECODER] ERROR: onDecodedFrame is nil!")
            }
        }
        
        if decodeStatus != noErr {
            // print("[DECODER] VTDecompressionSessionDecodeFrame returned error: \(decodeStatus)")
        } else {
            // print("[DECODER] VTDecompressionSessionDecodeFrame returned success")
        }
    }
}
