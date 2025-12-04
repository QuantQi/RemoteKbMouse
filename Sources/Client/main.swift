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
        // Required for SwiftUI apps built with SPM and run from terminal
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(kvmController)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let window = NSApplication.shared.windows.first {
                            window.toggleFullScreen(nil)
                        }
                    }
                }
        }
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
            if isControllingRemote {
                hideCursorAndLock()
            } else {
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
    
    // Video display layer (for network stream mode)
    let videoLayer = CALayer()
    
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
    
    // Note: Magic Mouse swipes are scroll wheel events with phases, not .swipe events.
    // They are captured by the CGEvent tap and forwarded as RemoteMouseEvent with scrollPhase.
    // NSEvent gesture monitors (.swipe) only work for trackpad, not Magic Mouse.
    
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
            // print("Warning: Metal not available")
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
        // print("Video decoder initialized")
    }
    
    // NOTE: Magic Mouse swipes are NOT .swipe NSEvent events.
    // They are scroll wheel events with phase information (began/changed/ended).
    // The CGEvent tap already captures these and forwards them via RemoteMouseEvent.
    // NSEvent.addLocalMonitorForEvents(matching: .swipe) only works for trackpad gestures.
    
    private var displayedFrameCount: UInt64 = 0
    
    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        displayedFrameCount += 1
        // let width = CVPixelBufferGetWidth(pixelBuffer)
        // let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // print("[DISPLAY] handleDecodedFrame #\(displayedFrameCount): \(width)x\(height)")
        
        // Get IOSurface for zero-copy GPU display (decoder is configured to output IOSurface-backed buffers)
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else {
            // print("[DISPLAY] ERROR: CVPixelBufferGetIOSurface returned nil!")
            return
        }
        let surface = surfaceRef.takeUnretainedValue()
        // print("[DISPLAY] Got IOSurface: \(surface)")
        
        // Display directly on GPU - no CPU copy!
        // CALayer.contents accepts IOSurface and composites it directly on GPU
        DispatchQueue.main.async {
            // print("[DISPLAY] Main thread: setting videoLayer.contents...")
            // print("[DISPLAY] videoLayer frame: \(self.videoLayer.frame), bounds: \(self.videoLayer.bounds)")
            // print("[DISPLAY] videoLayer superlayer: \(String(describing: self.videoLayer.superlayer))")
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // No animation
            self.videoLayer.contents = surface
            CATransaction.commit()
            
            // print("[DISPLAY] Frame #\(self.displayedFrameCount) displayed: \(width)x\(height)")
        }
    }
    
    deinit {
        stop()
    }
    
    /// Check permissions once at launch and cache the result
    private func checkAndCachePermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        hasInputMonitoringPermission = AXIsProcessTrustedWithOptions(options)
        
        if !hasInputMonitoringPermission {
            // print("\n--- PERMISSION REQUIRED ---")
            // print("This application needs Input Monitoring permissions to capture keyboard events.")
            // print("Please go to System Settings > Privacy & Security > Input Monitoring and enable it for 'Client'.")
            // print("---------------------------\n")
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
            // print("Cannot control remote: No server connection.")
            // fflush(stdout)
            return
        }
        
        // This will trigger the didSet observer
        isControllingRemote.toggle()
        // print("Remote control toggled: \(isControllingRemote)")
        // fflush(stdout)
    }
    
    /// Enter remote control and warp server cursor to right edge
    private func enterRemoteControl() {
        guard connection?.state == .ready else {
            return
        }
        guard !isControllingRemote else {
            return
        }
        
        // Get current cursor position
        let currentPos = CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: NSScreen.main?.frame.midY ?? 500)
        
        // Use main screen for Y mapping since cursor is at edge (may not be "inside" any screen)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let clientScreenSize = screen.frame.size
        
        // Map Y position proportionally from client to server screen
        // Clamp Y to screen bounds for safety
        let clampedY = max(screen.frame.minY, min(currentPos.y, screen.frame.maxY))
        let yRatio = (clampedY - screen.frame.minY) / clientScreenSize.height
        let serverY = yRatio * serverScreenSize.height
        // Warp to 20 points inside the right edge
        // For virtual display, this is relative to 0,0 (server will translate to virtual display frame)
        let serverX = serverScreenSize.width - 20.0
        
        print("[Client] Sending warpCursor to server: (\(serverX), \(serverY)), virtual=\(isVirtualDisplayMode)")
        
        // Send warp cursor command to server
        let warpEvent = WarpCursorEvent(x: serverX, y: serverY)
        send(event: .warpCursor(warpEvent))
        
        // Enter remote control mode
        isControllingRemote = true
    }
    
    // MARK: - Networking
    
    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: NetworkConstants.serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)
        
        browser?.stateUpdateHandler = { [weak self] newState in
            // print("Browser state updated: \(newState)")
            switch newState {
            case .failed(let error):
                // print("Browser failed with error: \(error). Restarting...")
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
                // print("Connected to server.")
                self?.startReceiving() // Start receiving messages from server
                self?.clipboardSync.startPolling()
                // Note: We'll send desired display mode after receiving server capabilities
            case .failed, .cancelled:
                // print("Connection lost.")
                self?.connection = nil
                self?.clipboardSync.stopPolling()
                self?.serverCapabilities = nil
                self?.isVirtualDisplayMode = false
                DispatchQueue.main.async { 
                    self?.isControllingRemote = false
                    self?.displayModeInfo = "Disconnected"
                }
            default:
                break
            }
        }
        connection?.start(queue: .main)
    }
    
    /// Send desired display mode to server based on current window size
    private func sendDesiredDisplayMode() {
        guard connection?.state == .ready else { return }
        
        // Get the window size (or use default)
        let windowSize: CGSize
        if let window = NSApplication.shared.windows.first {
            windowSize = window.frame.size
        } else {
            // Default to main screen size
            windowSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        }
        
        let scale: Double = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        let mode = DesiredDisplayMode(
            width: Int(Double(windowSize.width) * scale),
            height: Int(Double(windowSize.height) * scale),
            scale: scale,
            refreshRate: 60
        )
        
        pendingDisplayMode = mode
        send(event: .clientDesiredDisplayMode(mode))
        print("[Client] Sent desired display mode: \(mode.width)x\(mode.height) scale=\(mode.scale)")
        
        DispatchQueue.main.async {
            self.displayModeInfo = "Requesting \(mode.width)x\(mode.height)..."
        }
    }
    
    /// Called when window resizes - request new display mode
    func handleWindowResize(newSize: CGSize) {
        guard connection?.state == .ready,
              serverCapabilities?.supportsVirtualDisplay == true else { return }
        
        let scale: Double = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        let mode = DesiredDisplayMode(
            width: Int(Double(newSize.width) * scale),
            height: Int(Double(newSize.height) * scale),
            scale: scale,
            refreshRate: 60
        )
        
        // Only send if significantly different from current mode
        if let pending = pendingDisplayMode,
           abs(pending.width - mode.width) < 100 && abs(pending.height - mode.height) < 100 {
            return
        }
        
        pendingDisplayMode = mode
        send(event: .clientDesiredDisplayMode(mode))
        print("[Client] Requested new display mode: \(mode.width)x\(mode.height)")
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
                // print("[RECV] Connection error: \(error)")
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
        
        // Decode the frame
        if videoSourceMode == .networkStream {
            // print("[FRAME] Sending \(frameData.count) bytes to decoder...")
            decoder?.decode(nalData: frameData)
            // print("[FRAME] Decoder returned")
        } else {
            // print("[FRAME] WARNING: Not in networkStream mode!")
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
            print("[Client] Server capabilities: virtualDisplay=\(capabilities.supportsVirtualDisplay), macOS=\(capabilities.macOSVersion)")
            
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
            
            print("[Client] Virtual display ready: \(ready.width)x\(ready.height), virtual=\(ready.isVirtual), displayID=\(ready.displayID)")
            
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
            print("[Client] Screen info: \(info.width)x\(info.height), virtual=\(info.isVirtual)")
            
            DispatchQueue.main.async {
                // Update video layer to match new screen size
                self.updateVideoLayerSize()
            }
            
        case .controlRelease:
            DispatchQueue.main.async {
                self.isControllingRemote = false
                
                // Warp local cursor to screen center
                if let screen = NSScreen.main {
                    let warpX = screen.frame.midX
                    let warpY = screen.frame.midY
                    CGWarpMouseCursorPosition(CGPoint(x: warpX, y: warpY))
                }
            }
            
        case .clipboard(let payload):
            clipboardSync.apply(payload: payload)
            
        case .keyboard, .mouse, .gesture, .warpCursor, .startVideoStream, .stopVideoStream, .clientDesiredDisplayMode:
            // These are client-to-server events, ignore
            break
        }
    }
    
    /// Called when server screen size changes to update video layer dimensions
    private func updateVideoLayerSize() {
        // Video layer uses autoresizingMask for automatic resizing
        // This method triggers a layout pass if needed
        videoLayer.setNeedsLayout()
    }

    func send(event: RemoteInputEvent) {
        guard connection?.state == .ready else { return }
        
        // Log what we're sending
        switch event {
        case .mouse(let m) where m.eventType == .scrollWheel:
            print("[CLIENT-SEND] ScrollWheel: dX=\(String(format: "%.2f", m.scrollDeltaX)) dY=\(String(format: "%.2f", m.scrollDeltaY)) phase=\(m.scrollPhase) momentum=\(m.momentumPhase)")
            fflush(stdout)
        case .gesture(let g):
            print("[CLIENT-SEND] Gesture: kind=\(g.kind) dir=\(g.direction) phase=\(g.phase)")
            fflush(stdout)
        default:
            break
        }
        
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
            // print("Failed to create event tap. Make sure Input Monitoring permission is granted.")
            // fflush(stdout)
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
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Toggle combo: Ctrl+Shift+Escape (toggle remote control)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isEscapeDown = (type == .keyDown && keyCode == Int64(toggleKeyCode))
        let hasCtrlShift = flags.contains(.maskControl) && flags.contains(.maskShift)
        
        if isEscapeDown && hasCtrlShift {
            if isControllingRemote {
                // Release control immediately
                DispatchQueue.main.async {
                    self.isControllingRemote = false
                    // Warp local cursor to screen center
                    if let screen = NSScreen.main {
                        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
                    }
                }
                return nil // Consume the event
            } else if connection?.state == .ready {
                // Enter remote control
                DispatchQueue.main.async {
                    self.enterRemoteControl()
                }
                return nil // Consume the event
            }
        }
        
        // If not controlling remote, pass through all events
        if !isControllingRemote {
            return Unmanaged.passUnretained(event)
        }
        
        // If we're controlling remote, forward events
        let isMouseEvent = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ].contains(type)
        
        if isMouseEvent {
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            
            // Log scroll wheel events with phase info
            if type == .scrollWheel {
                let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
                let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
                let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                print("[CLIENT-TAP] ScrollWheel captured: dX=\(String(format: "%.2f", deltaX)) dY=\(String(format: "%.2f", deltaY)) phase=\(scrollPhase) momentum=\(momentumPhase)")
                fflush(stdout)
            }
            
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
            // print("No video capture device found. Please connect a camera or capture card.")
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


struct ContentView: View {
    @EnvironmentObject var kvmController: KVMController
    @State private var showControls = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Video feed based on source mode
                Group {
                    if kvmController.videoSourceMode == .captureCard {
                        VideoView(session: kvmController.captureSession)
                    } else {
                        NetworkVideoView(videoLayer: kvmController.videoLayer)
                    }
                }
                .ignoresSafeArea(.all)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
                
                // Video error overlay
                if let error = kvmController.videoError {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text(error)
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 60)
                    }
                }

                // Overlay controls (can be hidden)
                if showControls {
                    VStack {
                        // Status bar at top
                        HStack {
                            Text(kvmController.isControllingRemote ? "🟢 Controlling Remote" : "⚪ Local Mode")
                                .font(.caption)
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            
                            // Display mode indicator
                            Text(kvmController.isVirtualDisplayMode ? "📺 Virtual" : "🪞 Mirror")
                                .font(.caption)
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(kvmController.isVirtualDisplayMode ? .green : .orange)
                                .cornerRadius(8)
                            
                            Spacer()
                            
                            Text(kvmController.displayModeInfo)
                                .font(.caption)
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.gray)
                                .cornerRadius(8)
                        }
                        .padding()
                        
                        Spacer()
                        
                        Button(action: {
                            kvmController.toggleRemoteControl()
                        }) {
                            Text(kvmController.isControllingRemote ? "Release Control" : "Control MacBook")
                                .font(.headline)
                                .padding()
                                .frame(minWidth: 250)
                                .background(kvmController.isControllingRemote ? Color.red : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 40)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
                // Request new display mode when window resizes
                if let window = NSApplication.shared.windows.first {
                    kvmController.handleWindowResize(newSize: window.frame.size)
                }
            }
        }
    }
}