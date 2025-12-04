import SwiftUI
import AVFoundation
import Network
import CoreGraphics
import SharedCode
import AppKit
import VideoToolbox
import CoreMedia
import IOSurface
import Metal

// MARK: - Video Source Mode

enum VideoSourceMode {
    case captureCard      // Hardware capture card (original)
    case networkStream    // H.264 stream from server
}

@main
struct ClientApp: App {
    @StateObject private var kvmController = KVMController()
    
    init() {
        // Make it an accessory app - no dock icon, menubar only
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Menubar icon with dropdown menu
        MenuBarExtra {
            MenuBarView()
                .environmentObject(kvmController)
        } label: {
            // Menubar icon changes based on connection state
            Image(systemName: kvmController.isControllingRemote ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @EnvironmentObject var kvmController: KVMController
    
    var body: some View {
        // Connection status
        if kvmController.browserRelayURL.isEmpty {
            Text("⚪ Waiting for connection...")
        } else {
            Text(kvmController.isControllingRemote ? "🟢 Controlling Remote" : "⚪ Connected")
        }
        
        Divider()
        
        // Display mode info
        if !kvmController.displayModeInfo.isEmpty {
            Text(kvmController.displayModeInfo)
                .font(.caption)
        }
        
        if kvmController.isVirtualDisplayMode {
            Text("📺 Virtual Display Mode")
        }
        
        Divider()
        
        // Browser URL
        if !kvmController.browserRelayURL.isEmpty {
            Button("Open Video in Browser") {
                if let url = URL(string: kvmController.browserRelayURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            
            Text(kvmController.browserRelayURL)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        
        Divider()
        
        // Control toggle
        Button(kvmController.isControllingRemote ? "Release Control (Esc)" : "Take Control") {
            kvmController.toggleRemoteControl()
        }
        .keyboardShortcut(.escape, modifiers: [])
        
        Divider()
        
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - Clipboard Sync Manager

class ClipboardSyncManager {
    private var pollingTimer: Timer?
    private var lastLocalChangeCount: Int = 0
    private var lastSentId: UInt64 = 0
    private var lastAppliedId: UInt64 = 0
    
    var sendPayload: ((ClipboardPayload) -> Void)?
    var shouldSend: (() -> Bool)?
    
    func startPolling() {
        lastLocalChangeCount = NSPasteboard.general.changeCount
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }
    
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    private func poll() {
        // Check if we should send (only when controlling remote)
        guard shouldSend?() == true else { return }
        
        let currentChangeCount = NSPasteboard.general.changeCount
        
        // Check if pasteboard changed
        guard currentChangeCount != lastLocalChangeCount else { return }
        lastLocalChangeCount = currentChangeCount
        
        // Get text from pasteboard
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        
        // Create payload
        lastSentId += 1
        let payload = ClipboardPayload(
            id: lastSentId,
            kind: .text,
            text: text,
            timestamp: Date().timeIntervalSince1970
        )
        
        guard payload.isValid else {
            // print("Clipboard payload too large, skipping (\(text.utf8.count) bytes)")
            return
        }
        
        sendPayload?(payload)
    }
    
    func apply(payload: ClipboardPayload) {
        // Ignore invalid or already-applied payloads
        guard payload.isValid else {
            // print("Ignoring invalid clipboard payload")
            return
        }
        
        guard payload.id != lastAppliedId else {
            // Already applied this payload
            return
        }
        
        lastAppliedId = payload.id
        
        // Set pasteboard text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.text, forType: .string)
        
        // Update local change count to avoid feedback loop
        lastLocalChangeCount = NSPasteboard.general.changeCount
        
        // print("Applied clipboard payload #\(payload.id) (\(payload.text.count) chars)")
    }
}

class KVMController: ObservableObject {
    @Published var isControllingRemote: Bool = false {
        didSet {
            // Log state change to console
            if isControllingRemote {
//                 print("[Control] ✅ Now controlling remote - press Esc to release")
                hideCursorAndLock()
            } else {
//                 print("[Control] ⏹️  Released remote control")
                showCursorAndUnlock()
            }
        }
    }
    @Published var captureSession = AVCaptureSession()
    @Published var videoSourceMode: VideoSourceMode = .networkStream
    @Published var currentFrame: CGImage?  // Simple CGImage for display
    @Published var videoError: String?  // Error message for video issues
    @Published var isVirtualDisplayMode: Bool = false  // True if server is in virtual display mode
    @Published var displayModeInfo: String = "Connecting..."  // Status info for UI
    @Published var browserRelayURL: String = ""  // URL where video is streaming
    
    // Video display layer (for network stream mode) - kept but not used in UI
    let videoLayer = CALayer()
    
    // Browser relay server
    private let browserRelay = BrowserRelayServer()
    private var cachedCodecConfig: BrowserRelayServer.CodecConfig?
    
    // GPU acceleration
    private let metalDevice: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    
    // Networking
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var serverScreenSize: CGSize = CGSize(width: 1920, height: 1080)
    private var serverCapabilities: ServerCapabilities?
    private var pendingDisplayMode: DesiredDisplayMode?
    private var currentVirtualDisplayID: UInt32?
    
    // Video decoding
    private var decoder: H264Decoder?
    private var videoFrameBuffer = Data()
    private var expectedFrameSize: UInt32 = 0
    private var frameHeader: VideoFrameHeader?
    private var consecutiveParseErrors: Int = 0
    private let maxParseErrorsBeforeResync = 3
    
    // Event Tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let toggleKeyCode: CGKeyCode = 53 // Escape key
    
    // Cursor lock position (center of screen)
    private var cursorLockPosition: CGPoint = .zero
    private var cursorLockTimer: Timer?
    
    // Cached permission state
    private var hasInputMonitoringPermission: Bool = false
    
    // Clipboard sync
    private let clipboardSync = ClipboardSyncManager()
    
    // Edge detection state
    private var lastEdgeCrossingTime: TimeInterval = 0
    private var edgeMissLogCounter: Int = 0
    private var mouseEventCounter: Int = 0
    private var lastLoggedState: Bool? = nil
    
    init() {
        // Initialize GPU resources
        metalDevice = MTLCreateSystemDefaultDevice()
        if let device = metalDevice {
            // Create texture cache for zero-copy CVPixelBuffer -> Metal texture
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
            // print("GPU: \(device.name) (Metal zero-copy enabled)")
        } else {
//             print("Warning: Metal not available")
        }
        
        // print("KVMController initialized.")
        checkAndCachePermissions()
        
        // Configure video layer
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        
        if videoSourceMode == .captureCard {
            setupVideoCapture()
        } else {
            setupVideoDecoder()
        }
        
        // Configure clipboard sync
        clipboardSync.sendPayload = { [weak self] payload in
            self?.send(event: .clipboard(payload))
        }
        clipboardSync.shouldSend = { [weak self] in
            self?.isControllingRemote == true
        }
        
        // Start browser relay immediately (so we can test independently)
        browserRelay.start()
        browserRelayURL = browserRelay.url
//         print("[Client] Browser relay URL: \(browserRelayURL)")
        
        startBrowsing()
        startEventTap()
    }
    
    private func setupVideoDecoder() {
        decoder = H264Decoder()
        decoder?.onDecodedFrame = { [weak self] pixelBuffer, pts in
            self?.handleDecodedFrame(pixelBuffer)
        }
        decoder?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.videoError = error
            }
        }
        // Hook up parameter set callback for browser relay
        decoder?.onParameterSetsAvailable = { [weak self] codec, vps, sps, pps in
            self?.handleParameterSetsAvailable(codec: codec, vps: vps, sps: sps, pps: pps)
        }
        // print("Video decoder initialized")
    }
    
    /// Handle parameter sets becoming available - build codec description and send to browser
    private func handleParameterSetsAvailable(codec: VideoCodec, vps: Data?, sps: Data, pps: Data) {
//         print("[RELAY] Parameter sets available: codec=\(codec == .hevc ? "HEVC" : "H.264"), vps=\(vps?.count ?? 0), sps=\(sps.count), pps=\(pps.count)")
        
        // Build avcC or hvcc description
        let description: Data?
        let codecType: BrowserRelayServer.VideoCodecType
        
        if codec == .hevc {
            guard let vpsData = vps else { 
//                 print("[RELAY] ERROR: HEVC but no VPS")
                return 
            }
            description = CodecDescriptionBuilder.buildHvcc(vps: vpsData, sps: sps, pps: pps)
            codecType = .hevc
        } else {
            description = CodecDescriptionBuilder.buildAvcC(sps: sps, pps: pps)
            codecType = .h264
        }
        
        guard let avcDescription = description else {
//             print("[RELAY] Failed to build codec description")
            return
        }
        
//         print("[RELAY] Built codec description: \(avcDescription.count) bytes")
        
        let config = BrowserRelayServer.CodecConfig(
            codec: codecType,
            avcDescription: avcDescription,
            width: Int(serverScreenSize.width),
            height: Int(serverScreenSize.height)
        )
        
        // Only broadcast if config changed
        if cachedCodecConfig == nil || 
           cachedCodecConfig?.codec != config.codec ||
           cachedCodecConfig?.width != config.width ||
           cachedCodecConfig?.height != config.height ||
           cachedCodecConfig?.avcDescription != config.avcDescription {
            cachedCodecConfig = config
//             print("[RELAY] Broadcasting config: \(config.width)x\(config.height) \(codecType == .hevc ? "HEVC" : "H.264")")
            browserRelay.broadcastConfig(config)
        }
    }
    
    /// Update video layer sizing based on server screen size
    /// For virtual display mode, we want 1:1 pixel rendering when possible
    private func updateVideoLayerSize() {
        // The videoLayer.contentsGravity is already set to .resizeAspect
        // This will maintain aspect ratio and fit within the view bounds
        // For true 1:1 rendering, the window should match the virtual display size
        
//         print("[Client] Video layer target size: \(serverScreenSize.width)x\(serverScreenSize.height), virtual=\(isVirtualDisplayMode)")
        
        // If in virtual display mode, we could resize the window to match
        // For now, just log the expected size - the layer will auto-scale
        if isVirtualDisplayMode {
            // Notify that video content size changed (could be used for window auto-resize)
            NotificationCenter.default.post(
                name: NSNotification.Name("VideoContentSizeChanged"),
                object: nil,
                userInfo: ["width": serverScreenSize.width, "height": serverScreenSize.height]
            )
        }
    }
    
    private var displayedFrameCount: UInt64 = 0
    
    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        displayedFrameCount += 1
        // Video display is now handled by browser - do nothing here
        // We still decode to detect codec and extract parameter sets
    }
    
    deinit {
        stop()
    }
    
    /// Check permissions once at launch and cache the result
    private func checkAndCachePermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        hasInputMonitoringPermission = AXIsProcessTrustedWithOptions(options)
        
        if !hasInputMonitoringPermission {
//             print("\n--- PERMISSION REQUIRED ---")
//             print("This application needs Input Monitoring permissions to capture keyboard events.")
//             print("Please go to System Settings > Privacy & Security > Input Monitoring and enable it for 'Client'.")
//             print("---------------------------\n")
        }
    }
    
    /// Clean up all resources
    func stop() {
        stopEventTap()
        
        // Stop cursor lock timer
        cursorLockTimer?.invalidate()
        cursorLockTimer = nil
        
        // Stop clipboard sync
        clipboardSync.stopPolling()
        
        // Stop browser relay
        browserRelay.stop()
        
        // Stop browsing
        browser?.cancel()
        browser = nil
        
        // Cancel connection
        connection?.cancel()
        connection = nil
        
        // Stop capture session
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        // print("KVMController resources cleaned up.")
    }
    
    func toggleRemoteControl() {
        // Only allow controlling remote if we have a connection
        guard connection?.state == .ready else {
//             print("Cannot control remote: No server connection.")
            fflush(stdout)
            return
        }
        
        // This will trigger the didSet observer
        isControllingRemote.toggle()
        // print("Remote control toggled: \(isControllingRemote)")
        // fflush(stdout)
    }
    
    /// Enter remote control and warp server cursor to right edge
    private func enterRemoteControl() {
        // print("[EDGE-CLIENT] enterRemoteControl() called")
        // fflush(stdout)
        
        guard connection?.state == .ready else {
            // print("[EDGE-CLIENT] ERROR: Connection not ready")
            // fflush(stdout)
            return
        }
        guard !isControllingRemote else {
            // print("[EDGE-CLIENT] WARNING: Already controlling remote")
            // fflush(stdout)
            return
        }
        
        // Get current cursor position
        let currentPos = CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: NSScreen.main?.frame.midY ?? 500)
        // print("[EDGE-CLIENT] Current cursor: \(currentPos)")
        
        // Use main screen for Y mapping since cursor is at edge (may not be "inside" any screen)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let clientScreenSize = screen.frame.size
        
        // print("[EDGE-CLIENT] Client screen: \(screen.frame)")
        // print("[EDGE-CLIENT] Server screen size: \(serverScreenSize)")
        // print("[EDGE-CLIENT] Virtual display mode: \(isVirtualDisplayMode)")
        
        // Map Y position proportionally from client to server screen
        // Clamp Y to screen bounds for safety
        let clampedY = max(screen.frame.minY, min(currentPos.y, screen.frame.maxY))
        let yRatio = (clampedY - screen.frame.minY) / clientScreenSize.height
        let serverY = yRatio * serverScreenSize.height
        // Warp to 20 points inside the right edge to avoid immediate edge trigger
        // For virtual display, this is relative to 0,0 (server will translate to virtual display frame)
        let serverX = serverScreenSize.width - 20.0
        
//         print("[Client] Sending warpCursor to server: (\(serverX), \(serverY)), virtual=\(isVirtualDisplayMode)")
        
        // Send warp cursor command to server
        let warpEvent = WarpCursorEvent(x: serverX, y: serverY)
        send(event: .warpCursor(warpEvent))
        
        // Enter remote control mode
        isControllingRemote = true
        // print("[EDGE-CLIENT] ===== ENTERED REMOTE MODE =====")
        // fflush(stdout)
    }
    
    // MARK: - Networking
    
    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: NetworkConstants.serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)
        
        browser?.stateUpdateHandler = { [weak self] newState in
            // print("Browser state updated: \(newState)")
            switch newState {
            case .failed(let error):
//                 print("Browser failed with error: \(error). Restarting...")
                self?.browser?.cancel()
                self?.browser = nil
                // Restart browsing after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.startBrowsing()
                }
            case .cancelled:
                // print("Browser cancelled.")
                break
            default:
                break
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            guard let result = results.first else {
                self.connection?.cancel()
                self.connection = nil
                DispatchQueue.main.async { self.isControllingRemote = false }
                return
            }
            
            if self.connection == nil || self.connection?.endpoint != result.endpoint {
                self.connect(to: result.endpoint)
            }
        }
        
        // print("Starting Bonjour browser...")
        browser?.start(queue: .main)
    }
    
    private func connect(to endpoint: NWEndpoint) {
        // print("Connecting to server at \(endpoint)...")
        connection?.cancel()
        
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] newState in
            // print("Connection state updated: \(newState)")
            switch newState {
            case .ready:
//                 print("Connected to server.")
                self?.startReceiving() // Start receiving messages from server
                self?.clipboardSync.startPolling()
                // Browser relay already started in init, just log it
                let relayURL = self?.browserRelay.url ?? ""
//                 print("[Client] Browser relay available at: \(relayURL)")
                // Note: We'll send desired display mode after receiving server capabilities
            case .failed, .cancelled:
//                 print("Connection lost.")
                self?.connection = nil
                self?.clipboardSync.stopPolling()
                self?.browserRelay.stop()
                self?.serverCapabilities = nil
                self?.isVirtualDisplayMode = false
                DispatchQueue.main.async { 
                    self?.isControllingRemote = false
                    self?.displayModeInfo = "Disconnected"
                    self?.browserRelayURL = ""
                }
            default:
                break
            }
        }
        connection?.start(queue: .main)
    }
    
    /// Send desired display mode to server - always request 4K@60Hz
    private func sendDesiredDisplayMode() {
        guard connection?.state == .ready else { return }
        
        // Fixed 4K@60Hz for maximum quality over high-speed LAN
        let mode = DesiredDisplayMode(
            width: 3840,
            height: 2160,
            scale: 2.0,
            refreshRate: 60
        )
        
        pendingDisplayMode = mode
        send(event: .clientDesiredDisplayMode(mode))
//         print("[Client] Sent desired display mode: \(mode.width)x\(mode.height)@\(mode.refreshRate)Hz")
        
        DispatchQueue.main.async {
            self.displayModeInfo = "4K@60Hz"
        }
    }
    
    /// Called when window resizes - no longer used (menubar app with fixed 4K)
    func handleWindowResize(newSize: CGSize) {
        // No-op: we always use fixed 4K@60Hz now
    }
    
    // MARK: - Receive from Server
    
    private var receiveBuffer = Data()
    private static let newline = Data([0x0A])
    
    private func startReceiving() {
        receiveData()
    }
    
    private var totalBytesReceived: UInt64 = 0
    
    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.totalBytesReceived += UInt64(data.count)
                // if self.totalBytesReceived <= 10000 || self.videoFrameCount % 60 == 0 {
                //     print("[RECV] Got \(data.count) bytes, total=\(self.totalBytesReceived), buffer=\(self.receiveBuffer.count)")
                // }
                self.processReceivedData(data)
                self.receiveData() // Continue receiving
            }
            
            if isComplete {
                // print("[RECV] Connection complete")
            }
            if let error = error {
//                 print("[RECV] Connection error: \(error)")
            }
        }
    }
    
    private func processReceivedData(_ data: Data) {
        receiveBuffer.append(data)
        
        // Process messages - need to distinguish JSON from binary video frames
        // JSON messages start with '{' and end with '\n'
        // Video frames have a 9-byte header starting with binary size data
        while !receiveBuffer.isEmpty {
            // Check first byte to determine message type
            let firstByte = receiveBuffer[0]
            
            if firstByte == 0x7B { // '{' - JSON message
                // Find the newline
                guard let range = receiveBuffer.range(of: Self.newline) else { break }
                let messageData = receiveBuffer.subdata(in: 0..<range.lowerBound)
                receiveBuffer.removeSubrange(0..<range.upperBound)
                if !messageData.isEmpty {
                    handleServerMessage(messageData)
                }
            } else {
                // Binary video frame
                if !processVideoFrame() {
                    break // Need more data
                }
            }
        }
    }
    
    private var videoFrameCount: UInt64 = 0
    
    private func processVideoFrame() -> Bool {
        // Need at least header size
        guard receiveBuffer.count >= VideoFrameHeader.headerSize else { return false }
        
        // Parse header if we don't have one yet
        if frameHeader == nil {
            let headerData = receiveBuffer.subdata(in: 0..<VideoFrameHeader.headerSize)
            frameHeader = VideoFrameHeader.fromData(headerData)
            
            guard let header = frameHeader else { 
                // Invalid header - try to resync
                tryResyncStream()
                return false 
            }
            
            expectedFrameSize = header.frameSize
            
            // Sanity check: frame size should be reasonable (max 10MB for 4K keyframe)
            if expectedFrameSize == 0 || expectedFrameSize > 10_000_000 {
                // print("Warning: Invalid frame size \(expectedFrameSize), attempting resync")
                tryResyncStream()
                return false
            }
        }
        
        // Check if we have the complete frame
        let totalNeeded = VideoFrameHeader.headerSize + Int(expectedFrameSize)
        guard receiveBuffer.count >= totalNeeded else { return false }
        
        // Extract frame data
        let frameData = receiveBuffer.subdata(in: VideoFrameHeader.headerSize..<totalNeeded)
        receiveBuffer.removeSubrange(0..<totalNeeded)
        
        // Reset parse error counter on successful parse
        consecutiveParseErrors = 0
        
        videoFrameCount += 1
        let isKeyframe = frameHeader?.isKeyframe ?? false
        let timestamp = frameHeader?.timestamp ?? 0
        
        // Always log first 10 frames, then every 60th, plus all keyframes
        // if videoFrameCount <= 10 || videoFrameCount % 60 == 0 || isKeyframe {
        //     print("[FRAME] #\(videoFrameCount): \(frameData.count) bytes, keyframe=\(isKeyframe)")
        //     // Log first few bytes to see NAL structure
        //     if frameData.count >= 12 {
        //         let bytes = frameData.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        //         print("[FRAME] First 12 bytes: \(bytes)")
        //     }
        // }
        
        // Clear error on successful frame
        if videoError != nil {
            DispatchQueue.main.async { self.videoError = nil }
        }
        
        // Forward frame to browser relay BEFORE decoding
        // Build flags: bit0 = keyframe, bit1 = HEVC
        let detectedCodec = decoder?.currentCodec
        var flags: UInt8 = isKeyframe ? 0x01 : 0x00
        if detectedCodec == .hevc {
            flags |= 0x02
        }
        
        // Debug: log frame broadcast
        if videoFrameCount <= 5 || videoFrameCount % 60 == 0 || isKeyframe {
//             print("[RELAY] Frame #\(videoFrameCount): \(frameData.count) bytes, keyframe=\(isKeyframe), codec=\(detectedCodec == .hevc ? "HEVC" : "H.264")")
        }
        
        browserRelay.broadcastFrame(flags: flags, timestamp: timestamp, payload: frameData)
        
        // Decode the frame (still needed to detect codec and extract parameter sets)
        // But don't display - video goes to browser now
        if videoSourceMode == .networkStream {
            decoder?.decode(nalData: frameData)
        }
        
        // Reset for next frame
        frameHeader = nil
        expectedFrameSize = 0
        
        return true
    }
    
    private func tryResyncStream() {
        consecutiveParseErrors += 1
        
        if consecutiveParseErrors >= maxParseErrorsBeforeResync {
            // print("Too many parse errors, discarding buffer and waiting for next keyframe")
            receiveBuffer.removeAll()
            frameHeader = nil
            expectedFrameSize = 0
            consecutiveParseErrors = 0
            return
        }
        
        // Try to find next valid JSON message or start code pattern
        // Look for '{' (JSON) or 0x00 0x00 0x00 0x01 (NAL start code in raw data - shouldn't appear)
        frameHeader = nil
        expectedFrameSize = 0
        
        // Skip one byte and try again
        if !receiveBuffer.isEmpty {
            receiveBuffer.removeFirst()
        }
    }
    
    private func handleServerMessage(_ data: Data) {
        guard let event = try? JSONDecoder().decode(RemoteInputEvent.self, from: data) else {
            // Not a JSON message, might be partial video data that got misinterpreted
            return
        }
        
        switch event {
        case .serverCapabilities(let capabilities):
            serverCapabilities = capabilities
//             print("[Client] Server capabilities: virtualDisplay=\(capabilities.supportsVirtualDisplay), macOS=\(capabilities.macOSVersion)")
            
            // Now that we know server capabilities, send desired display mode
            if capabilities.supportsVirtualDisplay {
                sendDesiredDisplayMode()
            } else {
                DispatchQueue.main.async {
                    self.displayModeInfo = "Mirror mode (server macOS \(capabilities.macOSVersion))"
                    self.isVirtualDisplayMode = false
                }
            }
            
        case .virtualDisplayReady(let ready):
            currentVirtualDisplayID = ready.displayID
            isVirtualDisplayMode = ready.isVirtual
            serverScreenSize = CGSize(width: ready.width, height: ready.height)
            
//             print("[Client] Virtual display ready: \(ready.width)x\(ready.height), virtual=\(ready.isVirtual), displayID=\(ready.displayID)")
            
            DispatchQueue.main.async {
                if ready.isVirtual {
                    self.displayModeInfo = "Virtual display \(ready.width)x\(ready.height)"
                } else {
                    self.displayModeInfo = "Mirror mode \(ready.width)x\(ready.height)"
                }
                // Update video layer to match virtual display resolution for 1:1 rendering
                self.updateVideoLayerSize()
            }
            
        case .screenInfo(let info):
            serverScreenSize = CGSize(width: info.width, height: info.height)
            if let displayID = info.displayID {
                currentVirtualDisplayID = displayID
            }
            isVirtualDisplayMode = info.isVirtual
//             print("[Client] Screen info: \(info.width)x\(info.height), virtual=\(info.isVirtual)")
            
            DispatchQueue.main.async {
                // Update video layer to match new screen size
                self.updateVideoLayerSize()
            }
            
        case .controlRelease:
            // print("[EDGE-CLIENT] ===== RECEIVED CONTROL RELEASE =====")
            // fflush(stdout)
            DispatchQueue.main.async {
                self.isControllingRemote = false
                
                // Warp local cursor slightly inside the left edge
                let leftmostScreen = NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
                if let screen = leftmostScreen {
                    let warpX = screen.frame.minX + EdgeDetectionConfig.edgeInset + 2
                    let warpY = screen.frame.midY
                    CGWarpMouseCursorPosition(CGPoint(x: warpX, y: warpY))
                    // print("[EDGE-CLIENT] Warped local cursor to: (\(warpX), \(warpY))")
                }
                
                self.lastEdgeCrossingTime = CACurrentMediaTime()
                // print("[EDGE-CLIENT] ===== EXITED REMOTE MODE =====")
                // fflush(stdout)
            }
            
        case .clipboard(let payload):
            clipboardSync.apply(payload: payload)
            
        case .keyboard, .mouse, .warpCursor, .startVideoStream, .stopVideoStream, .clientDesiredDisplayMode:
            // These are client-to-server events, ignore
            break
        }
    }

    func send(event: RemoteInputEvent) {
        guard connection?.state == .ready else { return }
        
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(event)
            let framedData = data + "\n".data(using: .utf8)!
            connection?.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    // print("Send failed: \(error). Releasing control.")
                    DispatchQueue.main.async {
                        self?.isControllingRemote = false
                    }
                }
            })
        } catch {
            // print("Failed to encode and send event: \(error)")
        }
    }
    
    // MARK: - Event Tap
    
    private func startEventTap() {
        guard eventTap == nil else { return }
        // print("Starting event tap...")
        
        // Use cached permission state; re-check without prompting
        // (User was already prompted once at launch)
        if !hasInputMonitoringPermission {
            // Re-check silently in case user granted permission after launch
            hasInputMonitoringPermission = AXIsProcessTrusted()
            // print("Re-checked permission: \(hasInputMonitoringPermission)")
        }
        
        guard hasInputMonitoringPermission else {
            // print("Input Monitoring permission not granted. Cannot start event tap.")
            DispatchQueue.main.async { self.isControllingRemote = false }
            return
        }

        // The C-style callback function needs a pointer to this class instance
        let selfAsPointer = Unmanaged.passUnretained(self).toOpaque()
        
        // Create the event tap - capture keyboard AND mouse events
        // Build masks separately to avoid compiler complexity issues
        var eventMask: CGEventMask = 0
        
        // Keyboard events
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.keyUp.rawValue)
        eventMask |= (1 << CGEventType.flagsChanged.rawValue)
        
        // Mouse movement and clicks
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDragged.rawValue)
        
        // Scroll wheel (Magic Mouse gestures generate these)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                // Get the KVMController instance
                let mySelf = Unmanaged<KVMController>.fromOpaque(refcon).takeUnretainedValue()
                return mySelf.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfAsPointer
        )

        guard let eventTap = eventTap else {
//             print("Failed to create event tap. Make sure Input Monitoring permission is granted.")
            fflush(stdout)
            DispatchQueue.main.async { self.isControllingRemote = false }
            return
        }
        
        // print("Event tap created successfully")
        // fflush(stdout)

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        
        // IMPORTANT: Add to MAIN run loop, not current (which might be different in SwiftUI)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        // print("Event tap enabled and added to main run loop")
        // fflush(stdout)
    }

    private func stopEventTap() {
        guard let eventTap = eventTap else { return }
        // print("Stopping event tap.")
        
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.runLoopSource = nil
        self.eventTap = nil
    }
    
    // MARK: - Cursor Lock/Hide
    
    private func hideCursorAndLock() {
        // Get screen center for cursor lock position
        if let screen = NSScreen.main {
            cursorLockPosition = CGPoint(
                x: screen.frame.midX,
                y: screen.frame.midY
            )
        }
        
        // Hide the cursor
        CGDisplayHideCursor(CGMainDisplayID())
        
        // Move cursor to center
        CGWarpMouseCursorPosition(cursorLockPosition)
        
        // Disassociate mouse movement from cursor position
        // This prevents the cursor from moving even with mouse input
        CGAssociateMouseAndMouseCursorPosition(0)
        
        // Start a timer to continuously enforce cursor lock
        // This ensures cursor stays locked even when app loses focus
        cursorLockTimer?.invalidate()
        cursorLockTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self, self.isControllingRemote else { return }
            CGWarpMouseCursorPosition(self.cursorLockPosition)
        }
        
        // print("Cursor hidden and locked at \(cursorLockPosition)")
        // fflush(stdout)
    }
    
    private func showCursorAndUnlock() {
        // Stop the cursor lock timer
        cursorLockTimer?.invalidate()
        cursorLockTimer = nil
        
        // Re-associate mouse and cursor
        CGAssociateMouseAndMouseCursorPosition(1)
        
        // Show the cursor
        CGDisplayShowCursor(CGMainDisplayID())
        
        // print("Cursor shown and unlocked")
        // fflush(stdout)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled event (system can disable taps if they take too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // print("Event tap was disabled, re-enabling...")
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // TEMPORARILY DISABLED for edge detection testing
        // Toggle combo: Ctrl+Shift+Escape (fallback, works both ways)
        // let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // let flags = event.flags
        // let isEscapeDown = (type == .keyDown && keyCode == toggleKeyCode)
        // let hasCtrlShift = flags.contains(.maskControl) && flags.contains(.maskShift)
        // 
        // if isEscapeDown && hasCtrlShift {
        //     // Check connection before entering remote control
        //     if !isControllingRemote && connection?.state != .ready {
        //         print("Cannot enter remote control: No server connection.")
        //         fflush(stdout)
        //         return Unmanaged.passUnretained(event)
        //     }
        //     
        //     print("Toggle combo detected! Switching control.")
        //     fflush(stdout)
        //     DispatchQueue.main.async { 
        //         if !self.isControllingRemote {
        //             self.enterRemoteControl()
        //         } else {
        //             self.isControllingRemote = false
        //         }
        //     }
        //     return nil // Consume the event
        // }
        
        // Left edge detection: enter remote control when cursor hits left edge
        if !isControllingRemote {
            // // Log state change
            // if lastLoggedState != false {
            //     print("[CLIENT] State: LOCAL MODE (not controlling remote)")
            //     print("[CLIENT] Available screens: \(NSScreen.screens.map { "\($0.frame)" }.joined(separator: ", "))")
            //     fflush(stdout)
            //     lastLoggedState = false
            // }
            
            let isMouseMoveEvent = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
            if isMouseMoveEvent {
                mouseEventCounter += 1
                
                // Check connection state
                let connState = connection?.state
                guard connState == .ready else {
                    return Unmanaged.passUnretained(event)
                }
                
                let now = CACurrentMediaTime()
                let timeSinceLastCrossing = now - lastEdgeCrossingTime
                let cooldownPassed = timeSinceLastCrossing >= EdgeDetectionConfig.cooldownSeconds
                
                let location = event.location
                let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
                
                // Find the display - simplified: just check X range
                let display = NSScreen.screens.first { screen in
                    let frame = screen.frame
                    return location.x >= frame.minX && location.x <= frame.maxX
                } ?? NSScreen.main
                
                guard let currentScreen = display else {
                    return Unmanaged.passUnretained(event)
                }
                
                let screenFrame = currentScreen.frame
                let leftEdgeThreshold = screenFrame.minX + EdgeDetectionConfig.edgeInset
                let isAtLeftEdge = location.x <= leftEdgeThreshold
                
                // Log when within 30 points of left edge
                // if location.x <= screenFrame.minX + 30 {
                //     print("[EDGE-CLIENT] Near left: x=\(String(format: "%.1f", location.x)) threshold=\(leftEdgeThreshold) dX=\(deltaX) cooldown=\(cooldownPassed)")
                //     fflush(stdout)
                // }
                
                // Trigger on left edge
                if isAtLeftEdge && deltaX <= 0 && cooldownPassed {
                    lastEdgeCrossingTime = now
                    // print("[EDGE-CLIENT] ===== LEFT EDGE HIT =====")
                    // print("[EDGE-CLIENT] location: \(location), deltaX: \(deltaX)")
                    // print("[EDGE-CLIENT] screen: \(screenFrame)")
                    // fflush(stdout)
                    DispatchQueue.main.async { self.enterRemoteControl() }
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }
        
        // // Log state change to remote mode
        // if lastLoggedState != true {
        //     print("[CLIENT] State: REMOTE MODE (controlling remote, forwarding events)")
        //     fflush(stdout)
        //     lastLoggedState = true
        // }
        
        // If we're controlling remote, forward events
        let isMouseEvent = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ].contains(type)
        
        if isMouseEvent {
            mouseEventCounter += 1
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            
            if let remoteEvent = RemoteMouseEvent(event: event, screenSize: screenSize) {
                send(event: .mouse(remoteEvent))
            }
        } else {
            if let remoteEvent = RemoteKeyboardEvent(event: event) {
                send(event: .keyboard(remoteEvent))
            }
        }
        
        return nil
    }
    
    private func setupVideoCapture() {
        var device: AVCaptureDevice?

        // First, try to find an external device (capture card)
        let externalDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        
        if let externalDevice = externalDiscoverySession.devices.first {
            device = externalDevice
        } else {
            // If no external device, fall back to a built-in one
            let internalDiscoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            device = internalDiscoverySession.devices.first
        }
        
        guard let finalDevice = device else {
//             print("No video capture device found. Please connect a camera or capture card.")
            return
        }
        
        // print("Using video device: \(finalDevice.localizedName)")
        
        // Configure for highest quality
        captureSession.sessionPreset = .high
        
        // Try to select the best format (highest resolution and frame rate)
        do {
            try finalDevice.lockForConfiguration()
            
            // Find the best format - prefer highest resolution with highest frame rate
            let formats = finalDevice.formats
            var bestFormat: AVCaptureDevice.Format?
            var bestFrameRate: Float64 = 0
            var bestResolution: Int32 = 0
            
            for format in formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let resolution = dimensions.width * dimensions.height
                
                for range in format.videoSupportedFrameRateRanges {
                    let frameRate = range.maxFrameRate
                    // Prefer higher resolution, then higher frame rate
                    if resolution > bestResolution || (resolution == bestResolution && frameRate > bestFrameRate) {
                        bestFormat = format
                        bestFrameRate = frameRate
                        bestResolution = resolution
                    }
                }
            }
            
            if let bestFormat = bestFormat {
                finalDevice.activeFormat = bestFormat
                
                // Set to max frame rate
                for range in bestFormat.videoSupportedFrameRateRanges {
                    if range.maxFrameRate == bestFrameRate {
                        finalDevice.activeVideoMinFrameDuration = range.minFrameDuration
                        finalDevice.activeVideoMaxFrameDuration = range.minFrameDuration
                        break
                    }
                }
                
                let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                // print("Video configured: \(dims.width)x\(dims.height) @ \(bestFrameRate) fps")
            }
            
            finalDevice.unlockForConfiguration()
        } catch {
            // print("Could not configure video device: \(error)")
        }

        do {
            // Make sure to remove any existing input before adding a new one
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            
            let input = try AVCaptureDeviceInput(device: finalDevice)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            if !captureSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.captureSession.startRunning()
                }
            }
            
        } catch {
            // print("Failed to create video device input: \(error)")
        }
    }
}

// MARK: - Video Views

struct VideoView: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> NSView {
        let view = VideoContainerView()
        view.wantsLayer = true
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        if #available(macOS 14.0, *) {
            previewLayer.connection?.videoRotationAngle = 0
        }
        
        view.layer = previewLayer
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let previewLayer = nsView.layer as? AVCaptureVideoPreviewLayer {
            previewLayer.session = session
            previewLayer.frame = nsView.bounds
        }
    }
}

struct NetworkVideoView: NSViewRepresentable {
    let videoLayer: CALayer
    
    func makeNSView(context: Context) -> NetworkVideoContainerView {
        let view = NetworkVideoContainerView(videoLayer: videoLayer)
        return view
    }
    
    func updateNSView(_ nsView: NetworkVideoContainerView, context: Context) {
        // Force layout update
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }
}

class NetworkVideoContainerView: NSView {
    let videoLayer: CALayer
    
    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor(gray: 0.1, alpha: 1)  // Slightly lighter to see if layer is visible
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        
        // print("[VIEW] NetworkVideoContainerView created")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Update videoLayer frame to match view bounds
        videoLayer.frame = bounds
        
        CATransaction.commit()
        
        // print("[VIEW] Layout: view.bounds=\(bounds), videoLayer.frame=\(videoLayer.frame)")
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // print("[VIEW] Moved to window: \(String(describing: window)), bounds=\(bounds)")
        
        // Trigger initial layout
        needsLayout = true
    }
}

class VideoContainerView: NSView {
    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}