import Foundation
import Swifter
import AppKit

// MARK: - Browser Relay Server

/// Local HTTP+WebSocket server to relay video stream to browser using WebCodecs
public class BrowserRelayServer {
    
    // MARK: - Types
    
    public struct CodecConfig {
        public let codec: VideoCodecType
        public let avcDescription: Data  // avcC or hvcc box
        public let width: Int
        public let height: Int
        
        public init(codec: VideoCodecType, avcDescription: Data, width: Int, height: Int) {
            self.codec = codec
            self.avcDescription = avcDescription
            self.width = width
            self.height = height
        }
        
        func toJSON() -> String? {
            let dict: [String: Any] = [
                "type": "config",
                "codec": codec == .hevc ? "hevc" : "h264",
                "avcDescription": avcDescription.base64EncodedString(),
                "width": width,
                "height": height
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    
    public enum VideoCodecType {
        case h264
        case hevc
    }
    
    // MARK: - Properties
    
    private var server: HttpServer?
    private var webSocketSessions: [WebSocketSession] = []
    private let sessionsLock = NSLock()
    private var port: UInt16 = 8080
    private var isRunning = false
    private var cachedConfig: CodecConfig?
    
    public var activePort: UInt16 { port }
    public var url: String { "http://127.0.0.1:\(port)/" }
    
    // MARK: - Lifecycle
    
    public init() {}
    
    public func start(preferredPort: UInt16 = 8080) {
        guard !isRunning else { return }
        
        let httpServer = HttpServer()
        
        // Serve HTML page at root
        httpServer["/"] = { [weak self] _ in
            guard let self = self else { return .notFound }
            return .ok(.html(self.generateHTMLPage()))
        }
        
        // WebSocket endpoint
        httpServer["/ws"] = websocket(
            text: { [weak self] session, text in
                // Handle text messages (we don't expect any)
//                 print("[BrowserRelay] Received text: \(text)")
            },
            binary: { session, data in
                // Handle binary messages (we don't expect any)
//                 print("[BrowserRelay] Received binary: \(data.count) bytes")
            },
            pong: { session, data in
                // Pong received
            },
            connected: { [weak self] session in
//                 print("[BrowserRelay] WebSocket client connected")
                guard let self = self else { return }
                
                self.sessionsLock.lock()
                self.webSocketSessions.append(session)
                self.sessionsLock.unlock()
                
                // Send cached config if available
                if let config = self.cachedConfig, let json = config.toJSON() {
                    session.writeText(json)
                }
            },
            disconnected: { [weak self] session in
//                 print("[BrowserRelay] WebSocket client disconnected")
                guard let self = self else { return }
                
                self.sessionsLock.lock()
                self.webSocketSessions.removeAll { $0 === session }
//                 print("[BrowserRelay] Remaining clients: \(self.webSocketSessions.count)")
                self.sessionsLock.unlock()
            }
        )
        
        // Try ports starting from preferredPort
        for offset in 0..<100 {
            let tryPort = preferredPort + UInt16(offset)
            do {
                try httpServer.start(tryPort, forceIPv4: true)
                port = tryPort
                server = httpServer
                isRunning = true
//                 print("[BrowserRelay] Started on http://127.0.0.1:\(port)/")
                
                // Open browser
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.openBrowser()
                }
                return
            } catch SocketError.bindFailed(let msg) where msg.contains("Address already in use") {
//                 print("[BrowserRelay] Port \(tryPort) in use, trying next...")
                continue
            } catch {
//                 print("[BrowserRelay] Port \(tryPort) failed: \(error)")
                continue
            }
        }
        
//         print("[BrowserRelay] Failed to find available port")
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        server?.stop()
        server = nil
        
        sessionsLock.lock()
        webSocketSessions.removeAll()
        sessionsLock.unlock()
        
//         print("[BrowserRelay] Stopped")
    }
    
    private func openBrowser() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Broadcasting
    
    /// Broadcast codec configuration to all connected clients
    public func broadcastConfig(_ config: CodecConfig) {
        cachedConfig = config
        
        guard let json = config.toJSON() else { return }
        
        sessionsLock.lock()
        let sessions = webSocketSessions
        sessionsLock.unlock()
        
        for session in sessions {
            session.writeText(json)
        }
        
//         print("[BrowserRelay] Broadcast config: \(config.codec == .hevc ? "HEVC" : "H.264") \(config.width)x\(config.height)")
    }
    
    /// Broadcast a video frame to all connected clients
    /// Frame envelope: [1 byte flags][4 bytes timestamp ms][4 bytes payload length][NAL bytes...]
    /// Input is Annex-B format, output is AVCC format (length-prefixed)
    public func broadcastFrame(flags: UInt8, timestamp: UInt32, payload: Data) {
        sessionsLock.lock()
        let sessions = webSocketSessions
        let clientCount = sessions.count
        sessionsLock.unlock()
        
        // Only broadcast if we have clients
        guard clientCount > 0 else { return }
        
        // Convert Annex-B to AVCC format
        let avccPayload = convertAnnexBToAVCC(payload)
        
        // Build binary envelope
        var envelope = Data(capacity: 9 + avccPayload.count)
        envelope.append(flags)
        
        // Timestamp (big-endian)
        envelope.append(UInt8((timestamp >> 24) & 0xFF))
        envelope.append(UInt8((timestamp >> 16) & 0xFF))
        envelope.append(UInt8((timestamp >> 8) & 0xFF))
        envelope.append(UInt8(timestamp & 0xFF))
        
        // Payload length (big-endian)
        let len = UInt32(avccPayload.count)
        envelope.append(UInt8((len >> 24) & 0xFF))
        envelope.append(UInt8((len >> 16) & 0xFF))
        envelope.append(UInt8((len >> 8) & 0xFF))
        envelope.append(UInt8(len & 0xFF))
        
        envelope.append(avccPayload)
        
        let bytes = [UInt8](envelope)
        for session in sessions {
            session.writeBinary(bytes)
        }
    }
    
    /// Convert Annex-B format (start code delimited) to AVCC format (length prefixed)
    /// Annex-B uses 00 00 00 01 or 00 00 01 as NAL delimiters
    /// AVCC uses 4-byte big-endian length prefix for each NAL
    private func convertAnnexBToAVCC(_ annexB: Data) -> Data {
        var result = Data()
        var i = 0
        let bytes = [UInt8](annexB)
        let count = bytes.count
        
        while i < count {
            // Find start code (00 00 00 01 or 00 00 01)
            var startCodeLen = 0
            if i + 3 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeLen = 3
            } else {
                // No start code at current position, skip byte
                i += 1
                continue
            }
            
            // Move past start code
            let nalStart = i + startCodeLen
            i = nalStart
            
            // Find next start code or end of data
            var nalEnd = count
            while i < count - 2 {
                if bytes[i] == 0 && bytes[i+1] == 0 {
                    if i + 2 < count && bytes[i+2] == 1 {
                        nalEnd = i
                        break
                    } else if i + 3 < count && bytes[i+2] == 0 && bytes[i+3] == 1 {
                        nalEnd = i
                        break
                    }
                }
                i += 1
            }
            
            // Extract NAL unit
            let nalLength = nalEnd - nalStart
            if nalLength > 0 {
                // Write 4-byte length prefix (big-endian)
                result.append(UInt8((nalLength >> 24) & 0xFF))
                result.append(UInt8((nalLength >> 16) & 0xFF))
                result.append(UInt8((nalLength >> 8) & 0xFF))
                result.append(UInt8(nalLength & 0xFF))
                
                // Write NAL data
                result.append(contentsOf: bytes[nalStart..<nalEnd])
            }
            
            i = nalEnd
        }
        
        return result
    }
    
    // MARK: - HTML Page Generation
    
    private func generateHTMLPage() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>RemoteKbMouse Video</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                #c { width: 100%; height: 100%; object-fit: contain; }
                #status {
                    position: fixed;
                    top: 10px;
                    left: 10px;
                    color: #fff;
                    background: rgba(0,0,0,0.7);
                    padding: 8px 12px;
                    border-radius: 6px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 12px;
                    z-index: 1000;
                }
                #status.connected { background: rgba(0,128,0,0.7); }
                #status.error { background: rgba(128,0,0,0.7); }
            </style>
        </head>
        <body>
            <canvas id="c"></canvas>
            <div id="status">Connecting...</div>
            <script>
        const canvas = document.getElementById('c');
        const ctx = canvas.getContext('2d');
        const status = document.getElementById('status');
        let decoder;
        let ready = false;
        let isHEVC = false;
        let frameCount = 0;
        let lastFpsTime = performance.now();
        let fps = 0;

        function updateStatus(text, type = '') {
            status.textContent = text;
            status.className = type;
        }

        function makeVideoDecoderConfig(cfg) {
            // Decode base64 description
            const descBytes = Uint8Array.from(atob(cfg.avcDescription), c => c.charCodeAt(0));
            
            // Build codec string based on description
            let codecStr;
            if (cfg.codec === 'hevc') {
                // HEVC: use a generic string, description provides full config
                codecStr = 'hvc1.1.6.L93.B0';
            } else {
                // H.264: use profile from avcC if available
                if (descBytes.length >= 4) {
                    const profile = descBytes[1];
                    const constraints = descBytes[2];
                    const level = descBytes[3];
                    codecStr = `avc1.${profile.toString(16).padStart(2,'0')}${constraints.toString(16).padStart(2,'0')}${level.toString(16).padStart(2,'0')}`;
                } else {
                    codecStr = 'avc1.640028';
                }
            }
            
            return {
                codec: codecStr,
                description: descBytes,
                hardwareAcceleration: 'prefer-hardware',
                optimizeForLatency: true,
            };
        }

        function ensureDecoder(cfg) {
            if (decoder) {
                try { decoder.close(); } catch(e) {}
            }
            
            const config = makeVideoDecoderConfig(cfg);
            console.log('Decoder config:', config);
            
            decoder = new VideoDecoder({
                output: frame => {
                    // Update canvas size if needed
                    if (canvas.width !== frame.codedWidth || canvas.height !== frame.codedHeight) {
                        canvas.width = frame.codedWidth;
                        canvas.height = frame.codedHeight;
                    }
                    
                    // Draw frame
                    ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
                    frame.close();
                    
                    // FPS counter
                    frameCount++;
                    const now = performance.now();
                    if (now - lastFpsTime >= 1000) {
                        fps = frameCount;
                        frameCount = 0;
                        lastFpsTime = now;
                        updateStatus(`${cfg.width}x${cfg.height} @ ${fps} fps | ${cfg.codec.toUpperCase()}`, 'connected');
                    }
                },
                error: e => {
                    console.error('Decoder error', e);
                    updateStatus('Decoder error: ' + e.message, 'error');
                },
            });
            
            decoder.configure(config);
            isHEVC = cfg.codec === 'hevc';
            ready = true;
            updateStatus(`Configured: ${cfg.width}x${cfg.height} ${cfg.codec.toUpperCase()}`, 'connected');
        }

        function connect() {
            updateStatus('Connecting...');
            console.log('Connecting to WebSocket...');
            const ws = new WebSocket(`ws://${location.host}/ws`);
            ws.binaryType = 'arraybuffer';

            ws.onopen = () => {
                console.log('WebSocket connected');
                updateStatus('Connected, waiting for config...', 'connected');
            };

            ws.onmessage = ev => {
                if (typeof ev.data === 'string') {
                    try {
                        const msg = JSON.parse(ev.data);
                        console.log('Received config:', msg);
                        if (msg.type === 'config') {
                            ensureDecoder(msg);
                        }
                    } catch(e) {
                        console.error('JSON parse error', e);
                    }
                    return;
                }
                
                if (!ready) {
                    return;
                }
                
                const buf = new Uint8Array(ev.data);
                if (buf.length < 9) {
                    return;
                }
                
                const flags = buf[0];
                const isKey = (flags & 0x01) !== 0;
                const codecIsHevc = (flags & 0x02) !== 0;
                
                if (codecIsHevc !== isHEVC) {
                    console.warn('Codec mismatch, waiting for config');
                    return;
                }
                
                const ts = (buf[1]<<24)|(buf[2]<<16)|(buf[3]<<8)|buf[4];
                const len = (buf[5]<<24)|(buf[6]<<16)|(buf[7]<<8)|buf[8];
                const nal = buf.slice(9, 9 + len);
                
                try {
                    const chunk = new EncodedVideoChunk({
                        type: isKey ? 'key' : 'delta',
                        timestamp: ts * 1000, // ms to µs
                        data: nal,
                    });
                    
                    if (decoder && decoder.state === 'configured') {
                        decoder.decode(chunk);
                    }
                } catch(e) {
                    console.error('Decode error', e);
                }
            };

            ws.onerror = (e) => {
                console.error('WebSocket error', e);
                updateStatus('Connection error', 'error');
            };

            ws.onclose = () => {
                console.log('WebSocket closed');
                ready = false;
                try { decoder?.close(); } catch(e) {}
                updateStatus('Disconnected, reconnecting...', 'error');
                setTimeout(connect, 500);
            };
        }

        connect();
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - avcC/hvcc Builder

/// Builds avcC (H.264) or hvcc (HEVC) decoder configuration record from parameter sets
public class CodecDescriptionBuilder {
    
    /// Build avcC box from H.264 SPS and PPS
    public static func buildAvcC(sps: Data, pps: Data) -> Data? {
        guard sps.count >= 4 else { return nil }
        
        var avcC = Data()
        
        // Version
        avcC.append(1)
        
        // Profile, constraints, level from SPS (bytes 1, 2, 3 of SPS NAL)
        avcC.append(sps[1])  // profile_idc
        avcC.append(sps[2])  // constraint flags
        avcC.append(sps[3])  // level_idc
        
        // Length size minus one (0xFF = 4-byte lengths)
        avcC.append(0xFF)
        
        // Number of SPS (0xE1 = 1 SPS)
        avcC.append(0xE1)
        
        // SPS length (big-endian 16-bit)
        avcC.append(UInt8((sps.count >> 8) & 0xFF))
        avcC.append(UInt8(sps.count & 0xFF))
        
        // SPS data
        avcC.append(sps)
        
        // Number of PPS
        avcC.append(1)
        
        // PPS length (big-endian 16-bit)
        avcC.append(UInt8((pps.count >> 8) & 0xFF))
        avcC.append(UInt8(pps.count & 0xFF))
        
        // PPS data
        avcC.append(pps)
        
        return avcC
    }
    
    /// Build hvcc (HEVCDecoderConfigurationRecord) from VPS, SPS, PPS
    public static func buildHvcc(vps: Data, sps: Data, pps: Data) -> Data? {
        guard vps.count >= 2, sps.count >= 2, pps.count >= 2 else { return nil }
        
        var hvcc = Data()
        
        // configurationVersion = 1
        hvcc.append(1)
        
        // general_profile_space (2 bits) + general_tier_flag (1 bit) + general_profile_idc (5 bits)
        hvcc.append(0x01)  // Main profile
        
        // general_profile_compatibility_flags (32 bits)
        hvcc.append(contentsOf: [0x60, 0x00, 0x00, 0x00])
        
        // general_constraint_indicator_flags (48 bits)
        hvcc.append(contentsOf: [0xB0, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        // general_level_idc
        hvcc.append(93)
        
        // min_spatial_segmentation_idc (16 bits)
        hvcc.append(0xF0)
        hvcc.append(0x00)
        
        // parallelismType
        hvcc.append(0xFC)
        
        // chromaFormat
        hvcc.append(0xFD)
        
        // bitDepthLumaMinus8
        hvcc.append(0xF8)
        
        // bitDepthChromaMinus8
        hvcc.append(0xF8)
        
        // avgFrameRate
        hvcc.append(0x00)
        hvcc.append(0x00)
        
        // constantFrameRate + numTemporalLayers + temporalIdNested + lengthSizeMinusOne
        hvcc.append(0x0F)
        
        // numOfArrays
        hvcc.append(3)  // VPS, SPS, PPS
        
        // Array 1: VPS
        hvcc.append(0xA0 | 32)  // array_completeness=1, NAL unit type = 32 (VPS)
        hvcc.append(0x00)  // numNalus high byte
        hvcc.append(0x01)  // numNalus low byte = 1
        hvcc.append(UInt8((vps.count >> 8) & 0xFF))
        hvcc.append(UInt8(vps.count & 0xFF))
        hvcc.append(vps)
        
        // Array 2: SPS
        hvcc.append(0xA0 | 33)  // array_completeness=1, NAL unit type = 33 (SPS)
        hvcc.append(0x00)
        hvcc.append(0x01)
        hvcc.append(UInt8((sps.count >> 8) & 0xFF))
        hvcc.append(UInt8(sps.count & 0xFF))
        hvcc.append(sps)
        
        // Array 3: PPS
        hvcc.append(0xA0 | 34)  // array_completeness=1, NAL unit type = 34 (PPS)
        hvcc.append(0x00)
        hvcc.append(0x01)
        hvcc.append(UInt8((pps.count >> 8) & 0xFF))
        hvcc.append(UInt8(pps.count & 0xFF))
        hvcc.append(pps)
        
        return hvcc
    }
}
