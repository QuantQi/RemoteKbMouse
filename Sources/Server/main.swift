import Foundation
import Network
import CoreGraphics
import ApplicationServices
import SharedCode
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Metal
import AppKit

// MARK: - Screen Capturer

@available(macOS 12.3, *)
class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var isStreaming = false
    private let metalDevice: MTLDevice?
    
    var onEncodedFrame: ((Data, Bool) -> Void)?  // (data, isKeyframe)
    
    override init() {
        // Get the default Metal device for GPU acceleration
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init()
        
        if let device = metalDevice {
            print("GPU: \(device.name) (Metal supported)")
        } else {
            print("Warning: Metal not available, using CPU fallback")
        }
    }
    
    func startCapture() async throws {
        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first else {
            print("No display found")
            return
        }
        
        // Use NATIVE resolution - no scaling, no limits
        let captureWidth = display.width
        let captureHeight = display.height
        print("Display native resolution: \(captureWidth)x\(captureHeight)")
        
        // Configure stream for MAXIMUM QUALITY + MINIMUM LATENCY
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60 fps
        
        // Use hardware-optimal pixel format for encoding
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        
        config.showsCursor = true
        config.queueDepth = 3  // Lower queue depth = lower latency (was 8)
        
        // High quality color space
        config.colorSpaceName = CGColorSpace.displayP3
        
        if #available(macOS 14.0, *) {
            config.captureResolution = .best  // Best quality
            config.presenterOverlayPrivacyAlertSetting = .never
        }
        
        if #available(macOS 14.2, *) {
            config.includeChildWindows = true
        }
        
        print("Capture config: \(captureWidth)x\(captureHeight) @ 60fps (NATIVE, GPU-accelerated, low-latency)")
        
        // Create encoder with GPU acceleration - native resolution, 100% quality
        encoder = H264Encoder(width: Int32(captureWidth), height: Int32(captureHeight), fps: 60)
        encoder?.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.onEncodedFrame?(data, isKeyframe)
        }
        
        // Create filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        // Use high-priority queue for capture
        let captureQueue = DispatchQueue(label: "screen.capture", qos: .userInteractive)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        
        try await stream?.startCapture()
        isStreaming = true
        print("Screen capture started (GPU-accelerated)")
    }
    
    func stopCapture() async {
        guard isStreaming else { return }
        try? await stream?.stopCapture()
        stream = nil
        encoder = nil
        isStreaming = false
        print("Screen capture stopped")
    }
    
    private var capturedFrameCount: UInt64 = 0
    private var noPixelBufferCount: UInt64 = 0
    
    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { 
            print("[CAPTURE] Ignoring non-screen sample buffer, type=\(type)")
            return 
        }
        
        // Check sample buffer validity
        let isValid = CMSampleBufferIsValid(sampleBuffer)
        let dataIsReady = CMSampleBufferDataIsReady(sampleBuffer)
        
        if !isValid || !dataIsReady {
            print("[CAPTURE] Sample buffer not ready: valid=\(isValid), dataReady=\(dataIsReady)")
            return
        }
        
        // Check for status attachments that indicate why there's no frame
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let attachments = attachmentsArray.first {
            
            // SCStreamFrameInfo.status key
            let statusKey = SCStreamFrameInfo.status.rawValue as CFString
            if let statusRawValue = attachments[statusKey] as? Int {
                let status = SCFrameStatus(rawValue: statusRawValue)
                switch status {
                case .complete:
                    break // Good, continue processing
                case .idle:
                    // No new frame, screen unchanged - this is normal, don't spam logs
                    return
                case .blank:
                    if noPixelBufferCount % 60 == 0 {
                        print("[CAPTURE] Blank frame (screen may be locked or display off)")
                    }
                    noPixelBufferCount += 1
                    return
                case .suspended:
                    print("[CAPTURE] Capture suspended")
                    return
                case .started:
                    print("[CAPTURE] Stream started notification")
                    return
                case .stopped:
                    print("[CAPTURE] Stream stopped notification")
                    return
                default:
                    print("[CAPTURE] Unknown frame status: \(statusRawValue)")
                    // Don't return - try to get pixel buffer anyway
                }
            }
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            noPixelBufferCount += 1
            if noPixelBufferCount <= 10 || noPixelBufferCount % 100 == 0 {
                print("[CAPTURE] WARNING: No pixel buffer in sample buffer #\(noPixelBufferCount)")
                // Debug: print what's in the sample buffer
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                    print("[CAPTURE] Format: mediaType=\(mediaType), subType=\(mediaSubType)")
                } else {
                    print("[CAPTURE] No format description")
                }
                // Print attachment keys for debugging
                if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                   let attachments = attachmentsArray.first {
                    print("[CAPTURE] Attachment keys: \(attachments.keys)")
                }
            }
            return
        }
        
        capturedFrameCount += 1
        if capturedFrameCount <= 5 || capturedFrameCount % 120 == 0 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("[CAPTURE] ✓ Frame #\(capturedFrameCount): \(w)x\(h)")
        }
        encoder?.encode(pixelBuffer: pixelBuffer)
    }
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
        isStreaming = false
    }
}

// MARK: - Server

class Server {
    private var listener: NWListener
    private let port: NWEndpoint.Port
    
    // Cached permission state (checked once at launch)
    private var hasAccessibilityPermission: Bool = false

    init(port: NWEndpoint.Port) {
        self.port = port
        let parameters = NWParameters.tcp
        
        do {
            listener = try NWListener(using: parameters, on: port)
            
            // Enable Bonjour advertising
            listener.service = NWListener.Service(name: "RemoteKVMServer", type: NetworkConstants.serviceType)
            
            listener.stateUpdateHandler = self.stateDidChange(to:)
            listener.newConnectionHandler = self.didAccept(nwConnection:)
        } catch {
            fatalError("Failed to create listener: \(error)")
        }
    }

    func start() {
        print("Server starting...")
        print("Process: \(ProcessInfo.processInfo.processName)")
        print("PID: \(ProcessInfo.processInfo.processIdentifier)")
        
        // Check for screen recording permission (required for ScreenCaptureKit)
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        print("\n--- SCREEN RECORDING PERMISSION CHECK ---")
        print("CGPreflightScreenCaptureAccess() = \(hasScreenRecording)")
        
        if !hasScreenRecording {
            print("Requesting screen recording permission...")
            let granted = CGRequestScreenCaptureAccess()
            print("CGRequestScreenCaptureAccess() = \(granted)")
            
            if !granted {
                print("")
                print("⚠️  Screen Recording permission is REQUIRED to stream the screen.")
                print("")
                print("Since you're running from Terminal, you need to grant permission to TERMINAL:")
                print("  1. Open System Settings > Privacy & Security > Screen Recording")
                print("  2. Find 'Terminal' (or your terminal app: iTerm, Warp, etc.)")
                print("  3. Toggle it ON")
                print("  4. RESTART Terminal completely (Cmd+Q, then reopen)")
                print("  5. Run the server again")
                print("")
                print("If Terminal is not listed, this request should have added it.")
                print("Check System Settings now and look for Terminal.")
                print("---------------------------------------------\n")
            } else {
                print("✓ Screen Recording permission granted.")
            }
        } else {
            print("✓ Screen Recording permission already granted.")
        }
        print("-----------------------------------------\n")
        
        // Check for accessibility permissions (required for keyboard events)
        if !hasAccessibilityPermission {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
            hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)

            if !hasAccessibilityPermission {
                print("\n--- ACCESSIBILITY PERMISSION REQUIRED ---")
                print("⚠️  This application needs Accessibility permissions to simulate keyboard events.")
                print("Please go to System Settings > Privacy & Security > Accessibility")
                print("and enable it for 'Server'.")
                print("-----------------------------------------\n")
            } else {
                print("✓ Accessibility permission granted.")
            }
        } else {
            print("✓ Accessibility permission already granted.")
        }
        
        listener.start(queue: .main)
    }
    
    /// Creates a new listener instance (required after cancel)
    private func rebuildListener() {
        let parameters = NWParameters.tcp
        
        do {
            listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(name: "RemoteKVMServer", type: NetworkConstants.serviceType)
            listener.stateUpdateHandler = self.stateDidChange(to:)
            listener.newConnectionHandler = self.didAccept(nwConnection:)
        } catch {
            print("Failed to rebuild listener: \(error). Exiting.")
            exit(1)
        }
    }

    private func stateDidChange(to newState: NWListener.State) {
        switch newState {
        case .ready:
            print("Server ready and advertising on port \(listener.port?.debugDescription ?? "?")")
        case .failed(let error):
            print("Server failed with error: \(error). Rebuilding listener...")
            listener.cancel()
            // After cancel, listener cannot be reused - must create a new one
            rebuildListener()
            start()
        default:
            break
        }
    }

    private func didAccept(nwConnection: NWConnection) {
        print("Accepted new connection from \(nwConnection.endpoint)")
        let connection = ServerConnection(nwConnection: nwConnection)
        connection.didStopCallback = {
            // Handle cleanup if needed when a connection closes
            print("Connection with \(nwConnection.endpoint) stopped.")
        }
        connection.start()
    }
}

// MARK: - Clipboard Sync Manager

class ClipboardSyncManager {
    private var pollingTimer: Timer?
    private var lastLocalChangeCount: Int = 0
    private var lastSentId: UInt64 = 0
    private var lastAppliedId: UInt64 = 0
    
    var sendPayload: ((ClipboardPayload) -> Void)?
    
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
            print("Clipboard payload too large, skipping (\(text.utf8.count) bytes)")
            return
        }
        
        sendPayload?(payload)
    }
    
    func apply(payload: ClipboardPayload) {
        // Ignore invalid or already-applied payloads
        guard payload.isValid else {
            print("Ignoring invalid clipboard payload")
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
        
        print("Applied clipboard payload #\(payload.id) (\(payload.text.count) chars)")
    }
}

class ServerConnection {
    private static let newline = "\n".data(using: .utf8)!

    private let nwConnection: NWConnection
    var didStopCallback: (() -> Void)? = nil
    
    // Video streaming (Any? to avoid availability issues with ScreenCapturer)
    private var screenCapturer: Any?
    private var frameCount: UInt32 = 0
    private let startTime = CACurrentMediaTime()
    
    // Clipboard sync
    private let clipboardSync = ClipboardSyncManager()
    
    // Edge detection state
    private var lastEdgeReleaseTime: TimeInterval = 0
    private var edgeMissLogCounter: Int = 0
    private var mouseEventCounter: Int = 0
    private var isReceivingRemoteInput: Bool = false
    private var warpCursorTime: TimeInterval = 0  // Time of last warp, skip edge checks briefly after
    private var isCursorHidden: Bool = false  // Track cursor visibility

    init(nwConnection: NWConnection) {
        self.nwConnection = nwConnection
    }
    
    func start() {
        nwConnection.stateUpdateHandler = self.stateDidChange(to:)
        nwConnection.start(queue: .main)
        receive()
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .failed(let error):
            print("Connection failed with error: \(error)")
            self.stop(error: error)
        case .cancelled:
            self.stop(error: nil)
        case .ready:
            print("Connection ready.")
            sendScreenInfo()
            // Auto-start video streaming
            startVideoStream()
            // Start clipboard sync
            startClipboardSync()
        default:
            break
        }
    }
    
    private func startClipboardSync() {
        clipboardSync.sendPayload = { [weak self] payload in
            self?.send(event: .clipboard(payload))
        }
        clipboardSync.startPolling()
        
        // Optionally send initial clipboard state
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            let payload = ClipboardPayload(
                id: 0,
                kind: .text,
                text: text,
                timestamp: Date().timeIntervalSince1970
            )
            if payload.isValid {
                send(event: .clipboard(payload))
                print("Sent initial clipboard state (\(text.count) chars)")
            }
        }
    }
    
    private func startVideoStream() {
        guard #available(macOS 12.3, *) else {
            print("Video streaming requires macOS 12.3 or later")
            return
        }
        guard screenCapturer == nil else { return }
        print("Starting video stream...")
        
        let capturer = ScreenCapturer()
        capturer.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.sendVideoFrame(data: data, isKeyframe: isKeyframe)
        }
        screenCapturer = capturer
        
        Task {
            do {
                try await capturer.startCapture()
            } catch {
                print("Failed to start screen capture: \(error)")
            }
        }
    }
    
    private func stopVideoStream() {
        guard #available(macOS 12.3, *) else { return }
        guard let capturer = screenCapturer as? ScreenCapturer else { return }
        print("Stopping video stream...")
        screenCapturer = nil
        
        Task {
            await capturer.stopCapture()
        }
    }
    
    private func sendVideoFrame(data: Data, isKeyframe: Bool) {
        guard nwConnection.state == .ready else {
            print("[SEND] ERROR: Connection not ready, state=\(nwConnection.state)")
            return
        }
        
        let timestamp = UInt32((CACurrentMediaTime() - startTime) * 1000)
        let header = VideoFrameHeader(frameSize: UInt32(data.count), timestamp: timestamp, isKeyframe: isKeyframe)
        
        var frameData = header.toData()
        frameData.append(data)
        
        frameCount += 1
        
        if frameCount <= 5 || frameCount % 60 == 0 || isKeyframe {
            print("[SEND] Frame #\(frameCount): \(frameData.count) bytes (header=\(VideoFrameHeader.headerSize), payload=\(data.count)), keyframe=\(isKeyframe)")
            // Log header bytes
            let headerBytes = frameData.prefix(VideoFrameHeader.headerSize).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("[SEND] Header bytes: \(headerBytes)")
        }
        
        nwConnection.send(content: frameData, completion: .contentProcessed { error in
            if let error = error {
                print("[SEND] ERROR sending frame: \(error)")
            }
        })
    }
    
    private func sendScreenInfo() {
        let screenSize = getMainScreenSize()
        let screenInfo = ScreenInfoEvent(width: Double(screenSize.width), height: Double(screenSize.height))
        let event = RemoteInputEvent.screenInfo(screenInfo)
        send(event: event)
        
        print("[EDGE-SERVER] Screen info sent: \(screenSize.width)x\(screenSize.height)")
        print("[EDGE-SERVER] EdgeInset=\(EdgeDetectionConfig.edgeInset), Cooldown=\(EdgeDetectionConfig.cooldownSeconds)s")
        for (i, screen) in NSScreen.screens.enumerated() {
            print("[EDGE-SERVER] Screen[\(i)]: \(screen.frame) \(screen == NSScreen.main ? "(main)" : "")")
        }
        fflush(stdout)
    }
    
    private func sendControlRelease() {
        print("[EDGE-SERVER] Sending controlRelease to client")
        fflush(stdout)
        let event = RemoteInputEvent.controlRelease
        send(event: event)
        // Hide cursor - client now has control
        hideCursor()
    }
    
    // MARK: - Cursor Visibility
    
    private func hideCursor() {
        guard !isCursorHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        isCursorHidden = true
        print("[EDGE-SERVER] Cursor hidden")
        fflush(stdout)
    }
    
    private func showCursor() {
        guard isCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isCursorHidden = false
        print("[EDGE-SERVER] Cursor shown")
        fflush(stdout)
    }
    
    private func send(event: RemoteInputEvent) {
        guard nwConnection.state == .ready else { return }
        do {
            let data = try JSONEncoder().encode(event)
            let framedData = data + ServerConnection.newline
            nwConnection.send(content: framedData, completion: .idempotent)
        } catch {
            print("Failed to encode event: \(error)")
        }
    }
    
    private func receive() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data, _, isComplete, error) in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                // This is the core of the newline-delimited stream processing
                self.processData(data)
                // Continue waiting for more data
                self.receive()
            }
            
            if isComplete {
                self.stop(error: nil)
            } else if let error = error {
                self.stop(error: error)
            }
        }
    }
    
    // Buffer to hold incoming data until a newline is found
    private var buffer = Data()

    private func processData(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: ServerConnection.newline) {
            let messageData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            
            if !messageData.isEmpty {
                handleMessage(messageData)
            }
        }
    }
    
    private func handleMessage(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            let inputEvent = try decoder.decode(RemoteInputEvent.self, from: data)
            
            switch inputEvent {
            case .keyboard(let keyboardEvent):
                // print("[SERVER] Received keyboard: keyCode=\(keyboardEvent.keyCode)")
                if let cgEvent = keyboardEvent.toCGEvent() {
                    cgEvent.post(tap: .cgSessionEventTap)
                }
                
            case .mouse(let mouseEvent):
                mouseEventCounter += 1
                isReceivingRemoteInput = true
                
                let screenSize = getActiveScreenSize()
                
                if let cgEvent = mouseEvent.toCGEvent(screenSize: screenSize) {
                    cgEvent.post(tap: .cgSessionEventTap)
                    checkRightEdge(screenSize: screenSize, deltaX: mouseEvent.deltaX)
                }
                
            case .warpCursor(let warpEvent):
                let point = CGPoint(x: warpEvent.x, y: warpEvent.y)
                let beforePos = CGEvent(source: nil)?.location ?? .zero
                CGWarpMouseCursorPosition(point)
                let afterPos = CGEvent(source: nil)?.location ?? .zero
                print("[EDGE-SERVER] ===== WARP CURSOR RECEIVED =====")
                print("[EDGE-SERVER] Requested: \(point)")
                print("[EDGE-SERVER] Before: \(beforePos) -> After: \(afterPos)")
                print("[EDGE-SERVER] Screen size: \(getMainScreenSize())")
                fflush(stdout)
                // Skip edge checks for 500ms after warp to let mouse events settle
                warpCursorTime = CACurrentMediaTime()
                // Show cursor - server now has control
                showCursor()
                
            case .startVideoStream:
                startVideoStream()
                
            case .stopVideoStream:
                stopVideoStream()
                
            case .clipboard(let payload):
                clipboardSync.apply(payload: payload)
                
            case .screenInfo, .controlRelease:
                break
            }
        } catch {
            print("[SERVER] ERROR: Failed to decode: \(error)")
        }
    }
    
    private func checkRightEdge(screenSize: CGSize, deltaX: Double = 0) {
        // Skip edge checks for 500ms after warp to let mouse events settle
        let now = CACurrentMediaTime()
        let timeSinceWarp = now - warpCursorTime
        if timeSinceWarp < 0.5 {
            // Only log occasionally to avoid spam
            if edgeMissLogCounter % 30 == 0 {
                print("[EDGE-SERVER] Skipping edge check (\(String(format: "%.0f", timeSinceWarp * 1000))ms since warp)")
                fflush(stdout)
            }
            edgeMissLogCounter += 1
            return
        }
        
        guard let currentPos = CGEvent(source: nil)?.location else {
            return
        }
        
        let timeSinceLastRelease = now - lastEdgeReleaseTime
        let cooldownPassed = timeSinceLastRelease >= EdgeDetectionConfig.cooldownSeconds
        
        // Find screen containing cursor
        let currentScreen = NSScreen.screens.first { screen in
            let frame = screen.frame
            return currentPos.x >= frame.minX && currentPos.x <= frame.maxX &&
                   currentPos.y >= frame.minY && currentPos.y <= frame.maxY
        } ?? NSScreen.main
        
        guard let screen = currentScreen else {
            return
        }
        
        let screenFrame = screen.frame
        let rightEdgeThreshold = screenFrame.maxX - EdgeDetectionConfig.edgeInset
        let isAtRightEdge = currentPos.x >= rightEdgeThreshold
        
        // Log when near right edge (within 30 points)
        if currentPos.x >= screenFrame.maxX - 30 {
            print("[EDGE-SERVER] Near right: x=\(String(format: "%.1f", currentPos.x)) threshold=\(rightEdgeThreshold) cooldown=\(cooldownPassed)")
            fflush(stdout)
        }
        
        if isAtRightEdge && cooldownPassed {
            lastEdgeReleaseTime = now
            print("[EDGE-SERVER] ===== RIGHT EDGE HIT =====")
            print("[EDGE-SERVER] cursor: \(currentPos), screen: \(screenFrame)")
            fflush(stdout)
            sendControlRelease()
        } else {
            edgeMissLogCounter += 1
        }
    }
    
    /// Get screen size for the display containing the cursor, or main display as fallback
    private func getActiveScreenSize() -> CGSize {
        guard let currentPos = CGEvent(source: nil)?.location else {
            return getMainScreenSize()
        }
        
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(currentPos) }) {
            return screen.frame.size
        }
        
        return getMainScreenSize()
    }
    
    private func getMainScreenSize() -> CGSize {
        let mainDisplayID = CGMainDisplayID()
        let width = CGDisplayPixelsWide(mainDisplayID)
        let height = CGDisplayPixelsHigh(mainDisplayID)
        return CGSize(width: width, height: height)
    }

    private func stop(error: Error?) {
        stopVideoStream()
        clipboardSync.stopPolling()
        // Make sure cursor is visible when connection ends
        if isCursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            isCursorHidden = false
        }
        self.nwConnection.stateUpdateHandler = nil
        self.nwConnection.cancel()
        if let didStopCallback = self.didStopCallback {
            didStopCallback()
        }
    }
}

// Main entry point
let server = Server(port: .any)
server.start()

// Keep the server running
RunLoop.main.run()