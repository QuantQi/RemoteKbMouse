import Foundation
import Network
import AppKit
import CryptoKit

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
        
        func toJSON() -> Data? {
            let dict: [String: Any] = [
                "type": "config",
                "codec": codec == .hevc ? "hevc" : "h264",
                "avcDescription": avcDescription.base64EncodedString(),
                "width": width,
                "height": height
            ]
            return try? JSONSerialization.data(withJSONObject: dict)
        }
    }
    
    public enum VideoCodecType {
        case h264
        case hevc
    }
    
    // MARK: - WebSocket Client
    
    private class WebSocketClient {
        let connection: NWConnection
        var isWebSocketUpgraded = false
        var pendingHTTPData = Data()
        var sendQueue = DispatchQueue(label: "websocket.send")
        var pendingFrames = 0
        let maxPendingFrames = 30  // Drop frames if client is too slow
        
        init(connection: NWConnection) {
            self.connection = connection
        }
        
        func sendWebSocketFrame(_ data: Data, isText: Bool = false) {
            guard isWebSocketUpgraded else { return }
            
            // Check backpressure
            if pendingFrames > maxPendingFrames {
                // Drop frame for slow client
                return
            }
            
            sendQueue.async { [weak self] in
                guard let self = self else { return }
                
                let frame = self.encodeWebSocketFrame(data, isText: isText)
                self.pendingFrames += 1
                
                self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    self?.pendingFrames -= 1
                    if let error = error {
                        print("[WS] Send error: \(error)")
                    }
                })
            }
        }
        
        private func encodeWebSocketFrame(_ payload: Data, isText: Bool) -> Data {
            var frame = Data()
            
            // FIN + opcode (0x81 for text, 0x82 for binary)
            frame.append(isText ? 0x81 : 0x82)
            
            // Payload length (server frames are not masked)
            if payload.count <= 125 {
                frame.append(UInt8(payload.count))
            } else if payload.count <= 65535 {
                frame.append(126)
                frame.append(UInt8((payload.count >> 8) & 0xFF))
                frame.append(UInt8(payload.count & 0xFF))
            } else {
                frame.append(127)
                for i in (0..<8).reversed() {
                    frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
                }
            }
            
            frame.append(payload)
            return frame
        }
        
        func close() {
            connection.cancel()
        }
    }
    
    // MARK: - Properties
    
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: WebSocketClient] = [:]
    private let clientsLock = NSLock()
    private var port: UInt16 = 8080
    private var isRunning = false
    private var cachedConfig: CodecConfig?
    
    public var activePort: UInt16 { port }
    public var url: String { "http://127.0.0.1:\(port)/" }
    
    // MARK: - Lifecycle
    
    public init() {}
    
    public func start(preferredPort: UInt16 = 8080) {
        guard !isRunning else { return }
        
        // Try ports starting from preferredPort
        for offset in 0..<100 {
            let tryPort = preferredPort + UInt16(offset)
            if tryStartListener(on: tryPort) {
                port = tryPort
                isRunning = true
                print("[BrowserRelay] Started on http://127.0.0.1:\(port)/")
                // Delay browser open slightly to ensure listener is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.openBrowser()
                }
                return
            }
        }
        
        print("[BrowserRelay] Failed to find available port")
    }
    
    private func tryStartListener(on port: UInt16) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false  // Don't reuse - we want to know if it's taken
        
        guard let portNum = NWEndpoint.Port(rawValue: port) else { return false }
        
        do {
            let newListener = try NWListener(using: parameters, on: portNum)
            
            // Use a simple flag and polling approach since we're on main thread
            var listenerState: NWListener.State = .setup
            
            newListener.stateUpdateHandler = { state in
                listenerState = state
                if case .failed(let error) = state {
                    print("[BrowserRelay] Port \(port) failed: \(error)")
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.handleNewConnection(connection)
                }
            }
            
            // Start on main queue
            newListener.start(queue: .main)
            
            // Poll for state change (run loop will process events)
            let deadline = Date().addingTimeInterval(0.5)
            while listenerState == .setup && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            
            switch listenerState {
            case .ready:
                listener = newListener
                return true
            case .failed, .cancelled:
                newListener.cancel()
                return false
            default:
                // Still in setup or waiting - treat as success and hope for the best
                listener = newListener
                return true
            }
        } catch {
            print("[BrowserRelay] Port \(port) exception: \(error)")
            return false
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        listener?.cancel()
        listener = nil
        
        clientsLock.lock()
        for client in clients.values {
            client.close()
        }
        clients.removeAll()
        clientsLock.unlock()
        
        print("[BrowserRelay] Stopped")
    }
    
    private func openBrowser() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        let client = WebSocketClient(connection: connection)
        let clientId = ObjectIdentifier(connection)
        
        connection.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .ready:
                self?.startReceiving(client: client, clientId: clientId)
            case .failed, .cancelled:
                self?.removeClient(clientId)
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    private func startReceiving(client: WebSocketClient?, clientId: ObjectIdentifier) {
        guard let client = client else { return }
        
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak client] data, _, isComplete, error in
            guard let self = self, let client = client else { return }
            
            if let data = data {
                if client.isWebSocketUpgraded {
                    // Handle WebSocket frames (we don't really need to parse them, just keep connection alive)
                    self.handleWebSocketData(data, client: client)
                } else {
                    // HTTP request
                    client.pendingHTTPData.append(data)
                    self.handleHTTPRequest(client: client, clientId: clientId)
                }
            }
            
            if !isComplete && error == nil {
                self.startReceiving(client: client, clientId: clientId)
            } else if isComplete || error != nil {
                self.removeClient(clientId)
            }
        }
    }
    
    private func handleHTTPRequest(client: WebSocketClient, clientId: ObjectIdentifier) {
        guard let requestString = String(data: client.pendingHTTPData, encoding: .utf8),
              requestString.contains("\r\n\r\n") else {
            return  // Wait for complete headers
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1]
        
        print("[BrowserRelay] HTTP request: \(method) \(path)")
        
        // Check for WebSocket upgrade
        let isUpgrade = requestString.lowercased().contains("upgrade: websocket")
        let wsKeyLine = lines.first { $0.lowercased().hasPrefix("sec-websocket-key:") }
        
        if method == "GET" && path == "/ws" && isUpgrade, let keyLine = wsKeyLine {
            print("[BrowserRelay] WebSocket upgrade request")
            let key = keyLine.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            handleWebSocketUpgrade(client: client, clientId: clientId, key: key)
        } else if method == "GET" && (path == "/" || path.isEmpty) {
            print("[BrowserRelay] Serving HTML page")
            sendHTMLPage(client: client, clientId: clientId)
        } else {
            print("[BrowserRelay] 404 for path: \(path)")
            send404(client: client)
        }
        
        client.pendingHTTPData.removeAll()
    }
    
    private func handleWebSocketUpgrade(client: WebSocketClient, clientId: ObjectIdentifier, key: String) {
        // Compute accept key
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = Insecure.SHA1.hash(data: Data(combined.utf8))
        let acceptKey = Data(hash).base64EncodedString()
        
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r
        
        """
        
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak client] error in
            guard let self = self, let client = client, error == nil else { return }
            
            client.isWebSocketUpgraded = true
            
            self.clientsLock.lock()
            self.clients[clientId] = client
            self.clientsLock.unlock()
            
            print("[BrowserRelay] WebSocket client connected")
            
            // Send cached config if available
            if let config = self.cachedConfig, let json = config.toJSON() {
                client.sendWebSocketFrame(json, isText: true)
            }
        })
    }
    
    private func handleWebSocketData(_ data: Data, client: WebSocketClient) {
        // Parse WebSocket frame (simplified - just handle ping/close)
        guard data.count >= 2 else { return }
        
        let opcode = data[0] & 0x0F
        
        switch opcode {
        case 0x08:  // Close
            client.close()
        case 0x09:  // Ping - send pong
            var pong = Data([0x8A])  // Pong with no payload
            pong.append(0x00)
            client.connection.send(content: pong, completion: .idempotent)
        default:
            break  // Ignore other frames
        }
    }
    
    private func sendHTMLPage(client: WebSocketClient, clientId: ObjectIdentifier) {
        let html = generateHTMLPage()
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            // Close connection after sending HTML (HTTP/1.0 style)
            self?.removeClient(clientId)
        })
    }
    
    private func send404(client: WebSocketClient) {
        let response = """
        HTTP/1.1 404 Not Found\r
        Content-Length: 0\r
        Connection: close\r
        \r
        
        """
        
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            client.close()
        })
    }
    
    private func removeClient(_ clientId: ObjectIdentifier) {
        clientsLock.lock()
        if let client = clients.removeValue(forKey: clientId) {
            client.close()
            print("[BrowserRelay] Client disconnected, remaining: \(clients.count)")
        }
        clientsLock.unlock()
    }
    
    // MARK: - Broadcasting
    
    /// Broadcast codec configuration to all connected clients
    public func broadcastConfig(_ config: CodecConfig) {
        cachedConfig = config
        
        guard let json = config.toJSON() else { return }
        
        clientsLock.lock()
        let activeClients = clients.values.filter { $0.isWebSocketUpgraded }
        clientsLock.unlock()
        
        for client in activeClients {
            client.sendWebSocketFrame(json, isText: true)
        }
        
        print("[BrowserRelay] Broadcast config: \(config.codec == .hevc ? "HEVC" : "H.264") \(config.width)x\(config.height)")
    }
    
    /// Broadcast a video frame to all connected clients
    /// Frame envelope: [1 byte flags][4 bytes timestamp ms][4 bytes payload length][NAL bytes...]
    public func broadcastFrame(flags: UInt8, timestamp: UInt32, payload: Data) {
        clientsLock.lock()
        let activeClients = clients.values.filter { $0.isWebSocketUpgraded }
        let clientCount = activeClients.count
        clientsLock.unlock()
        
        // Only broadcast if we have clients
        guard clientCount > 0 else { return }
        
        // Build binary envelope
        var envelope = Data(capacity: 9 + payload.count)
        envelope.append(flags)
        
        // Timestamp (big-endian)
        envelope.append(UInt8((timestamp >> 24) & 0xFF))
        envelope.append(UInt8((timestamp >> 16) & 0xFF))
        envelope.append(UInt8((timestamp >> 8) & 0xFF))
        envelope.append(UInt8(timestamp & 0xFF))
        
        // Payload length (big-endian)
        let len = UInt32(payload.count)
        envelope.append(UInt8((len >> 24) & 0xFF))
        envelope.append(UInt8((len >> 16) & 0xFF))
        envelope.append(UInt8((len >> 8) & 0xFF))
        envelope.append(UInt8(len & 0xFF))
        
        envelope.append(payload)
        
        for client in activeClients {
            client.sendWebSocketFrame(envelope, isText: false)
        }
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
                console.log('Received message:', typeof ev.data, ev.data.byteLength || ev.data.length);
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
                    console.log('Not ready, dropping frame');
                    return;
                }
                
                const buf = new Uint8Array(ev.data);
                if (buf.length < 9) {
                    console.log('Frame too short:', buf.length);
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
                
                console.log(`Frame: ts=${ts}, len=${len}, isKey=${isKey}, actual=${nal.length}`);
                
                try {
                    const chunk = new EncodedVideoChunk({
                        type: isKey ? 'key' : 'delta',
                        timestamp: ts * 1000, // ms to µs
                        data: nal,
                    });
                    
                    if (decoder && decoder.state === 'configured') {
                        decoder.decode(chunk);
                    } else {
                        console.log('Decoder not configured, state:', decoder?.state);
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
    /// avcC structure:
    /// [0] = 1 (version)
    /// [1] = profile_idc
    /// [2] = profile_compat (constraint flags)
    /// [3] = level_idc
    /// [4] = 0xFF (reserved 6 bits + NAL length size - 1 = 3 -> 4 bytes)
    /// [5] = 0xE1 (reserved 3 bits + number of SPS = 1)
    /// [6-7] = SPS length (big-endian)
    /// [...] = SPS data
    /// [next] = number of PPS (1)
    /// [next 2] = PPS length (big-endian)
    /// [...] = PPS data
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
    /// Simplified hvcc structure for WebCodecs compatibility
    public static func buildHvcc(vps: Data, sps: Data, pps: Data) -> Data? {
        guard vps.count >= 2, sps.count >= 2, pps.count >= 2 else { return nil }
        
        var hvcc = Data()
        
        // configurationVersion = 1
        hvcc.append(1)
        
        // Parse SPS to get profile info (simplified - use defaults)
        // general_profile_space (2 bits) + general_tier_flag (1 bit) + general_profile_idc (5 bits)
        hvcc.append(0x01)  // Main profile
        
        // general_profile_compatibility_flags (32 bits)
        hvcc.append(contentsOf: [0x60, 0x00, 0x00, 0x00])
        
        // general_constraint_indicator_flags (48 bits)
        hvcc.append(contentsOf: [0xB0, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        // general_level_idc (typically 93 for 1080p@60, 120 for 4K@60)
        hvcc.append(93)
        
        // min_spatial_segmentation_idc (16 bits, reserved 4 bits + 12 bits)
        hvcc.append(0xF0)
        hvcc.append(0x00)
        
        // parallelismType (6 reserved bits + 2 bits)
        hvcc.append(0xFC)
        
        // chromaFormat (6 reserved bits + 2 bits) - typically 1 for 4:2:0
        hvcc.append(0xFD)
        
        // bitDepthLumaMinus8 (5 reserved bits + 3 bits)
        hvcc.append(0xF8)
        
        // bitDepthChromaMinus8 (5 reserved bits + 3 bits)
        hvcc.append(0xF8)
        
        // avgFrameRate (16 bits) - 0 means unspecified
        hvcc.append(0x00)
        hvcc.append(0x00)
        
        // constantFrameRate (2 bits) + numTemporalLayers (3 bits) + temporalIdNested (1 bit) + lengthSizeMinusOne (2 bits)
        // = 0 + 1 + 1 + 3 = 0x0F
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
