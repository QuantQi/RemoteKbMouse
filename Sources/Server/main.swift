import Foundation
import Network
import CoreGraphics
import ApplicationServices
import SharedCode
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Metal

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
        
        print("Capturing display: \(display.width)x\(display.height)")
        
        // Configure stream for maximum GPU performance
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60 fps
        
        // Use hardware-optimal pixel format
        // 420YpCbCr8BiPlanarVideoRange is optimal for hardware video encoding
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        
        config.showsCursor = true
        config.queueDepth = 8  // Buffer for smooth streaming
        
        // GPU-specific optimizations
        config.colorSpaceName = CGColorSpace.displayP3  // Modern wide color
        
        if #available(macOS 14.0, *) {
            config.captureResolution = .nominal  // Native resolution
            config.presenterOverlayPrivacyAlertSetting = .never  // No presenter overlay
        }
        
        if #available(macOS 14.2, *) {
            config.includeChildWindows = true  // Capture child windows too
        }
        
        let captureWidth = Int32(config.width)
        let captureHeight = Int32(config.height)
        
        print("Capture config: \(captureWidth)x\(captureHeight) @ 60fps (GPU-accelerated)")
        
        // Create encoder with GPU acceleration
        encoder = H264Encoder(width: captureWidth, height: captureHeight, fps: 60)
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
    
    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[CAPTURE] ERROR: No pixel buffer in sample buffer")
            return
        }
        capturedFrameCount += 1
        if capturedFrameCount <= 3 || capturedFrameCount % 120 == 0 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("[CAPTURE] Frame #\(capturedFrameCount): \(w)x\(h)")
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
        
        // Check for screen recording permission (required for ScreenCaptureKit)
        if !CGPreflightScreenCaptureAccess() {
            print("\n--- SCREEN RECORDING PERMISSION REQUIRED ---")
            print("Requesting screen recording permission...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                print("⚠️  Screen Recording permission is required to stream the screen.")
                print("Please go to System Settings > Privacy & Security > Screen Recording")
                print("and enable it for 'Server', then restart the server.")
                print("---------------------------------------------\n")
            } else {
                print("✓ Screen Recording permission granted.")
            }
        } else {
            print("✓ Screen Recording permission already granted.")
        }
        
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

class ServerConnection {
    private static let newline = "\n".data(using: .utf8)!

    private let nwConnection: NWConnection
    var didStopCallback: (() -> Void)? = nil
    
    // Video streaming (Any? to avoid availability issues with ScreenCapturer)
    private var screenCapturer: Any?
    private var frameCount: UInt32 = 0
    private let startTime = CACurrentMediaTime()

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
        default:
            break
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
        print("Sent screen info: \(screenSize.width)x\(screenSize.height)")
    }
    
    private func sendControlRelease() {
        let event = RemoteInputEvent.controlRelease
        send(event: event)
        print("Sent control release (right edge hit)")
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
                if let cgEvent = keyboardEvent.toCGEvent() {
                    cgEvent.post(tap: .cgSessionEventTap)
                } else {
                    print("Failed to convert keyboard event to CGEvent")
                }
                
            case .mouse(let mouseEvent):
                let screenSize = getMainScreenSize()
                
                if let cgEvent = mouseEvent.toCGEvent(screenSize: screenSize) {
                    cgEvent.post(tap: .cgSessionEventTap)
                    checkRightEdge(screenSize: screenSize)
                } else {
                    print("Failed to convert mouse event to CGEvent")
                }
                
            case .warpCursor(let warpEvent):
                let point = CGPoint(x: warpEvent.x, y: warpEvent.y)
                CGWarpMouseCursorPosition(point)
                print("Warped cursor to \(point)")
                
            case .startVideoStream:
                startVideoStream()
                
            case .stopVideoStream:
                stopVideoStream()
                
            case .screenInfo, .controlRelease:
                // These are server-to-client events, ignore if received
                break
            }
        } catch {
            print("Failed to decode RemoteInputEvent: \(error)")
            print("Raw data: \(String(data: data, encoding: .utf8) ?? "non-utf8")")
        }
    }
    
    private func checkRightEdge(screenSize: CGSize) {
        // Get current cursor position
        guard let currentPos = CGEvent(source: nil)?.location else { return }
        
        // Check if cursor hit right edge
        if currentPos.x >= screenSize.width - 1 {
            sendControlRelease()
        }
    }
    
    private func getMainScreenSize() -> CGSize {
        let mainDisplayID = CGMainDisplayID()
        let width = CGDisplayPixelsWide(mainDisplayID)
        let height = CGDisplayPixelsHigh(mainDisplayID)
        return CGSize(width: width, height: height)
    }

    private func stop(error: Error?) {
        stopVideoStream()
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