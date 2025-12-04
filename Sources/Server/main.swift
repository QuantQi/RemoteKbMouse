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

// MARK: - Virtual Display Manager (macOS 14+)
// Note: CGVirtualDisplay is a private API. This implementation uses dynamic loading
// to access it at runtime. If the API is not available, it falls back gracefully.

@available(macOS 14.0, *)
class VirtualDisplayManager {
    // Virtual display state (using Any to avoid compile-time type requirements)
    private var virtualDisplayObject: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var displayFrame: CGRect = .zero
    private(set) var displayMode: DesiredDisplayMode?
    
    var isActive: Bool { displayID != 0 }
    
    func createDisplay(mode: DesiredDisplayMode) -> Bool {
        // Clean up existing display first
        destroyDisplay()
        
        // Log system info
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
//         print("[VirtualDisplay] macOS version: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
//         print("[VirtualDisplay] Requesting: \(mode.width)x\(mode.height)@\(mode.refreshRate ?? 60)Hz")
        
        // Check if CGVirtualDisplay classes exist
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
//             print("[VirtualDisplay] ❌ CGVirtualDisplay API not available on this macOS version")
            return false
        }
        
//         print("[VirtualDisplay] ✅ All required classes found")
        
        do {
            // Create descriptor using KVC (safer than perform selectors)
            let descriptor = descriptorClass.init()
            descriptor.setValue("RemoteKVM Virtual Display", forKey: "name")
            descriptor.setValue(mode.width, forKey: "maxPixelsWide")
            descriptor.setValue(mode.height, forKey: "maxPixelsHigh")
            descriptor.setValue(CGSize(width: 600, height: 340), forKey: "sizeInMillimeters")
            descriptor.setValue(UInt32(0x1234), forKey: "productID")
            descriptor.setValue(UInt32(0x5678), forKey: "vendorID")
            descriptor.setValue(UInt32(0x0001), forKey: "serialNum")
//             print("[VirtualDisplay] Descriptor created")
            
            // Use objc_msgSend alternative - allocate and init via NSInvocation pattern
            // Actually, let's use a simpler approach with direct class method if available
            let allocSel = NSSelectorFromString("alloc")
            let initSel = NSSelectorFromString("initWithDescriptor:")
            
            guard displayClass.responds(to: allocSel) else {
//                 print("[VirtualDisplay] ❌ CGVirtualDisplay doesn't respond to alloc")
                return false
            }
            
            // Use safer memory management
            let allocated = (displayClass as AnyObject).perform(allocSel)?.takeRetainedValue()
            guard let allocatedObj = allocated as? NSObject else {
//                 print("[VirtualDisplay] ❌ Failed to allocate CGVirtualDisplay")
                return false
            }
            
            guard allocatedObj.responds(to: initSel) else {
//                 print("[VirtualDisplay] ❌ CGVirtualDisplay doesn't respond to initWithDescriptor:")
                return false
            }
            
            let initialized = allocatedObj.perform(initSel, with: descriptor)?.takeRetainedValue()
            guard let display = initialized as? NSObject else {
//                 print("[VirtualDisplay] ❌ Failed to init CGVirtualDisplay")
                return false
            }
            
//             print("[VirtualDisplay] ✅ CGVirtualDisplay instance created")
            
            // Get display ID using KVC
            guard let displayIDValue = display.value(forKey: "displayID") as? UInt32, displayIDValue != 0 else {
//                 print("[VirtualDisplay] ❌ Failed to get valid display ID")
                return false
            }
//             print("[VirtualDisplay] ✅ Display ID: \(displayIDValue)")
            
            // Create mode
            let refreshRate = mode.refreshRate ?? 60
            let modeObject = modeClass.init()
            modeObject.setValue(mode.width, forKey: "width")
            modeObject.setValue(mode.height, forKey: "height")
            modeObject.setValue(Double(refreshRate), forKey: "refreshRate")
            
            // Create settings
            let settings = settingsClass.init()
            settings.setValue(1, forKey: "hiDPI")
            settings.setValue([modeObject], forKey: "modes")
            
            // Apply settings
            let applySel = NSSelectorFromString("applySettings:")
            if display.responds(to: applySel) {
                _ = display.perform(applySel, with: settings)
//                 print("[VirtualDisplay] Settings applied")
            } else {
//                 print("[VirtualDisplay] ⚠️ applySettings: not available")
            }
            
            virtualDisplayObject = display
            displayID = displayIDValue
            displayMode = mode
            
            // Query the actual display frame
            displayFrame = CGDisplayBounds(displayIDValue)
            
            if displayFrame.isEmpty || displayFrame.width == 0 {
                let mainBounds = CGDisplayBounds(CGMainDisplayID())
                displayFrame = CGRect(
                    x: mainBounds.maxX,
                    y: mainBounds.minY,
                    width: CGFloat(mode.width),
                    height: CGFloat(mode.height)
                )
//                 print("[VirtualDisplay] ⚠️ Using estimated frame")
            }
            
//             print("[VirtualDisplay] ✅ Created: \(mode.width)x\(mode.height)@\(refreshRate)Hz, ID=\(displayID)")
            return true
            
        } catch {
//             print("[VirtualDisplay] ❌ Exception: \(error)")
            return false
        }
    }
    
    /// Refresh the display frame from CoreGraphics (call after display registers)
    func refreshDisplayFrame() {
        guard displayID != 0 else { return }
        let newFrame = CGDisplayBounds(displayID)
        if !newFrame.isEmpty && newFrame.width > 0 && newFrame.height > 0 {
            displayFrame = newFrame
//             print("[VirtualDisplay] Refreshed frame: \(displayFrame)")
        }
    }
    
    func destroyDisplay() {
        guard virtualDisplayObject != nil else { return }
        
//         print("[VirtualDisplay] Destroying display ID=\(displayID)")
        virtualDisplayObject = nil
        displayID = 0
        displayFrame = .zero
        displayMode = nil
    }
    
    deinit {
        destroyDisplay()
    }
}

// MARK: - Screen Capturer

@available(macOS 12.3, *)
class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var isStreaming = false
    private let metalDevice: MTLDevice?
    
    // Target display configuration
    private var targetDisplayID: CGDirectDisplayID?
    private var targetWidth: Int?
    private var targetHeight: Int?
    
    var onEncodedFrame: ((Data, Bool) -> Void)?  // (data, isKeyframe)
    
    override init() {
        // Get the default Metal device for GPU acceleration
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init()
        
        if let device = metalDevice {
            // print("GPU: \(device.name) (Metal supported)")
        } else {
//             print("Warning: Metal not available, using CPU fallback")
        }
    }
    
    /// Configure capture target before starting
    func configure(displayID: CGDirectDisplayID?, width: Int? = nil, height: Int? = nil) {
        self.targetDisplayID = displayID
        self.targetWidth = width
        self.targetHeight = height
    }
    
    func startCapture() async throws {
        // Find target display with retry logic for virtual displays
        let display: SCDisplay
        var foundVirtualDisplay = false
        
        if let targetID = targetDisplayID {
            // For virtual displays, retry a few times as they may take a moment to register
            var attempts = 0
            let maxAttempts = 5
            var targetDisplay: SCDisplay?
            
            while attempts < maxAttempts {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                
                // Log all available displays for debugging
                if attempts == 0 {
//                     print("[ScreenCapturer] Available displays:")
                    for scDisplay in content.displays {
                        let bounds = CGDisplayBounds(scDisplay.displayID)
//                         print("  - ID=\(scDisplay.displayID): \(scDisplay.width)x\(scDisplay.height) at \(bounds.origin)")
                    }
                }
                
                targetDisplay = content.displays.first(where: { $0.displayID == targetID })
                if targetDisplay != nil {
                    break
                }
                
                attempts += 1
                if attempts < maxAttempts {
//                     print("[ScreenCapturer] Virtual display ID=\(targetID) not found, retry \(attempts)/\(maxAttempts)...")
                    try await Task.sleep(nanoseconds: 300_000_000) // 300ms
                }
            }
            
            if let found = targetDisplay {
                display = found
                foundVirtualDisplay = true
//                 print("[ScreenCapturer] Capturing virtual display ID=\(targetID) (\(display.width)x\(display.height))")
            } else {
//                 print("[ScreenCapturer] WARNING: Virtual display ID=\(targetID) not found after \(maxAttempts) attempts")
//                 print("[ScreenCapturer] Falling back to main display")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let mainDisplay = content.displays.first else {
//                     print("[ScreenCapturer] ERROR: No displays found")
                    return
                }
                display = mainDisplay
            }
        } else {
            // No target specified, use main display
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let mainDisplay = content.displays.first else {
//                 print("[ScreenCapturer] ERROR: No displays found")
                return
            }
            display = mainDisplay
//             print("[ScreenCapturer] Capturing main display")
        }
        
        // Use configured dimensions for virtual display, otherwise use display's native resolution
        let captureWidth: Int
        let captureHeight: Int
        if foundVirtualDisplay, let w = targetWidth, let h = targetHeight {
            captureWidth = w
            captureHeight = h
        } else {
            captureWidth = display.width
            captureHeight = display.height
        }
//         print("[ScreenCapturer] Capture resolution: \(captureWidth)x\(captureHeight)")
        
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
//         print("[ScreenCapturer] Screen capture started")
    }
    
    func stopCapture() async {
        guard isStreaming else { return }
        try? await stream?.stopCapture()
        stream = nil
        encoder = nil
        isStreaming = false
        // print("Screen capture stopped")
    }
    
    private var capturedFrameCount: UInt64 = 0
    private var noPixelBufferCount: UInt64 = 0
    
    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { 
            // print("[CAPTURE] Ignoring non-screen sample buffer, type=\(type)")
            return 
        }
        
        // Check sample buffer validity
        let isValid = CMSampleBufferIsValid(sampleBuffer)
        let dataIsReady = CMSampleBufferDataIsReady(sampleBuffer)
        
        if !isValid || !dataIsReady {
            // print("[CAPTURE] Sample buffer not ready: valid=\(isValid), dataReady=\(dataIsReady)")
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
                    // if noPixelBufferCount % 60 == 0 {
                    //     print("[CAPTURE] Blank frame (screen may be locked or display off)")
                    // }
                    noPixelBufferCount += 1
                    return
                case .suspended:
                    // print("[CAPTURE] Capture suspended")
                    return
                case .started:
                    // print("[CAPTURE] Stream started notification")
                    return
                case .stopped:
                    // print("[CAPTURE] Stream stopped notification")
                    return
                default:
                    // print("[CAPTURE] Unknown frame status: \(statusRawValue)")
                    // Don't return - try to get pixel buffer anyway
                    break
                }
            }
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            noPixelBufferCount += 1
            // if noPixelBufferCount <= 10 || noPixelBufferCount % 100 == 0 {
            //     print("[CAPTURE] WARNING: No pixel buffer in sample buffer #\(noPixelBufferCount)")
            //     // Debug: print what's in the sample buffer
            //     if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            //         let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
            //         let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
            //         print("[CAPTURE] Format: mediaType=\(mediaType), subType=\(mediaSubType)")
            //     } else {
            //         print("[CAPTURE] No format description")
            //     }
            //     // Print attachment keys for debugging
            //     if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            //        let attachments = attachmentsArray.first {
            //         print("[CAPTURE] Attachment keys: \(attachments.keys)")
            //     }
            // }
            return
        }
        
        capturedFrameCount += 1
        // if capturedFrameCount <= 5 || capturedFrameCount % 120 == 0 {
        //     let w = CVPixelBufferGetWidth(pixelBuffer)
        //     let h = CVPixelBufferGetHeight(pixelBuffer)
        //     print("[CAPTURE] ✓ Frame #\(capturedFrameCount): \(w)x\(h)")
        // }
        encoder?.encode(pixelBuffer: pixelBuffer)
    }
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // print("Stream stopped with error: \(error)")
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
//         print("Server starting...")
//         print("Process: \(ProcessInfo.processInfo.processName)")
//         print("PID: \(ProcessInfo.processInfo.processIdentifier)")
        
        // Check for screen recording permission (required for ScreenCaptureKit)
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
//         print("\n--- SCREEN RECORDING PERMISSION CHECK ---")
//         print("CGPreflightScreenCaptureAccess() = \(hasScreenRecording)")
        
        if !hasScreenRecording {
//             print("Requesting screen recording permission...")
            let granted = CGRequestScreenCaptureAccess()
//             print("CGRequestScreenCaptureAccess() = \(granted)")
            
            if !granted {
//                 print("")
//                 print("⚠️  Screen Recording permission is REQUIRED to stream the screen.")
//                 print("")
//                 print("Since you're running from Terminal, you need to grant permission to TERMINAL:")
//                 print("  1. Open System Settings > Privacy & Security > Screen Recording")
//                 print("  2. Find 'Terminal' (or your terminal app: iTerm, Warp, etc.)")
//                 print("  3. Toggle it ON")
//                 print("  4. RESTART Terminal completely (Cmd+Q, then reopen)")
//                 print("  5. Run the server again")
//                 print("")
//                 print("If Terminal is not listed, this request should have added it.")
//                 print("Check System Settings now and look for Terminal.")
//                 print("---------------------------------------------\n")
            } else {
//                 print("✓ Screen Recording permission granted.")
            }
        } else {
//             print("✓ Screen Recording permission already granted.")
        }
//         print("-----------------------------------------\n")
        
        // Check for accessibility permissions (required for keyboard events)
        if !hasAccessibilityPermission {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
            hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)

            if !hasAccessibilityPermission {
//                 print("\n--- ACCESSIBILITY PERMISSION REQUIRED ---")
//                 print("⚠️  This application needs Accessibility permissions to simulate keyboard events.")
//                 print("Please go to System Settings > Privacy & Security > Accessibility")
//                 print("and enable it for 'Server'.")
//                 print("-----------------------------------------\n")
            } else {
//                 print("✓ Accessibility permission granted.")
            }
        } else {
//             print("✓ Accessibility permission already granted.")
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
//             print("Failed to rebuild listener: \(error). Exiting.")
            exit(1)
        }
    }

    private func stateDidChange(to newState: NWListener.State) {
        switch newState {
        case .ready:
            // print("Server ready and advertising on port \(listener.port?.debugDescription ?? "?")")
            break
        case .failed(_):
            // print("Server failed with error: \(error). Rebuilding listener...")
            listener.cancel()
            // After cancel, listener cannot be reused - must create a new one
            rebuildListener()
            start()
        default:
            break
        }
    }

    private func didAccept(nwConnection: NWConnection) {
        // print("Accepted new connection from \(nwConnection.endpoint)")
        let connection = ServerConnection(nwConnection: nwConnection)
        connection.didStopCallback = {
            // Handle cleanup if needed when a connection closes
            // print("Connection with \(nwConnection.endpoint) stopped.")
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

class ServerConnection {
    private static let newline = "\n".data(using: .utf8)!

    private let nwConnection: NWConnection
    var didStopCallback: (() -> Void)? = nil
    
    // Video streaming (Any? to avoid availability issues with ScreenCapturer)
    private var screenCapturer: Any?
    private var frameCount: UInt32 = 0
    private let startTime = CACurrentMediaTime()
    
    // Virtual display (Any? to avoid availability issues)
    private var virtualDisplayManager: Any?
    private var virtualDisplayFrame: DisplayFrame?
    private var isVirtualDisplayMode: Bool = false
    
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
//             print("Connection failed with error: \(error)")
            self.stop(error: error)
        case .cancelled:
            self.stop(error: nil)
        case .ready:
            // print("Connection ready.")
            sendServerCapabilities()
            sendScreenInfo()
            // Auto-start video streaming
            startVideoStream()
            // Start clipboard sync
            startClipboardSync()
        default:
            break
        }
    }
    
    private func sendServerCapabilities() {
        let capabilities = ServerCapabilities.current()
        let event = RemoteInputEvent.serverCapabilities(capabilities)
        send(event: event)
//         print("[Server] Sent capabilities: virtualDisplay=\(capabilities.supportsVirtualDisplay), macOS=\(capabilities.macOSVersion)")
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
                // print("Sent initial clipboard state (\(text.count) chars)")
            }
        }
    }
    
    private func startVideoStream() {
        guard #available(macOS 12.3, *) else {
//             print("Video streaming requires macOS 12.3 or later")
            return
        }
        guard screenCapturer == nil else { return }
//         print("[Server] Starting video stream...")
        
        let capturer = ScreenCapturer()
        capturer.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.sendVideoFrame(data: data, isKeyframe: isKeyframe)
        }
        
        // Configure for virtual display if active
        if #available(macOS 14.0, *),
           let manager = virtualDisplayManager as? VirtualDisplayManager,
           manager.isActive,
           let mode = manager.displayMode {
            capturer.configure(
                displayID: manager.displayID,
                width: mode.width,
                height: mode.height
            )
//             print("[Server] Configured capturer for virtual display ID=\(manager.displayID)")
        }
        
        screenCapturer = capturer
        
        Task {
            do {
                try await capturer.startCapture()
            } catch {
//                 print("Failed to start screen capture: \(error)")
            }
        }
    }
    
    private func handleDesiredDisplayMode(_ mode: DesiredDisplayMode) {
//         print("[Server] Received desired display mode: \(mode.width)x\(mode.height) scale=\(mode.scale)")
        
        // Stop current video stream if running
        stopVideoStream()
        
        // Try to create virtual display if supported
        if #available(macOS 14.0, *) {
            let manager: VirtualDisplayManager
            if let existing = virtualDisplayManager as? VirtualDisplayManager {
                manager = existing
            } else {
                manager = VirtualDisplayManager()
                virtualDisplayManager = manager
            }
            
            if manager.createDisplay(mode: mode) {
                isVirtualDisplayMode = true
                virtualDisplayFrame = DisplayFrame(rect: manager.displayFrame)
                
                // Send virtual display ready
                let ready = VirtualDisplayReady(
                    width: mode.width,
                    height: mode.height,
                    scale: mode.scale,
                    displayID: manager.displayID,
                    isVirtual: true
                )
                send(event: .virtualDisplayReady(ready))
                
                // Update screen info to reflect virtual display
                let screenInfo = ScreenInfoEvent(
                    width: Double(mode.width),
                    height: Double(mode.height),
                    isVirtual: true,
                    displayID: manager.displayID
                )
                send(event: .screenInfo(screenInfo))
                
//                 print("[Server] Virtual display created, starting capture...")
                
                // Give the display time to register with macOS, then refresh frame and start capture
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self else { return }
                    
                    // Refresh the display frame from CoreGraphics now that it's registered
                    if #available(macOS 14.0, *) {
                        if let mgr = self.virtualDisplayManager as? VirtualDisplayManager {
                            mgr.refreshDisplayFrame()
                            self.virtualDisplayFrame = DisplayFrame(rect: mgr.displayFrame)
//                             print("[Server] Updated virtual display frame: \(mgr.displayFrame)")
                        }
                    }
                    
                    self.startVideoStream()
                }
                return
            } else {
//                 print("[Server] Failed to create virtual display, falling back to mirror mode")
            }
        } else {
//             print("[Server] Virtual display not supported (requires macOS 14+), using mirror mode")
        }
        
        // Fallback: mirror mode
        isVirtualDisplayMode = false
        virtualDisplayFrame = nil
        
        let screenSize = getMainScreenSize()
        let ready = VirtualDisplayReady(
            width: Int(screenSize.width),
            height: Int(screenSize.height),
            scale: 2.0,
            displayID: CGMainDisplayID(),
            isVirtual: false
        )
        send(event: .virtualDisplayReady(ready))
        
        // Send screen info for main display
        sendScreenInfo()
        
        // Restart video stream
        startVideoStream()
    }
    
    private func stopVideoStream() {
        guard #available(macOS 12.3, *) else { return }
        guard let capturer = screenCapturer as? ScreenCapturer else { return }
//         print("[Server] Stopping video stream...")
        screenCapturer = nil
        
        Task {
            await capturer.stopCapture()
        }
        
        // Clean up virtual display
        if #available(macOS 14.0, *) {
            if let manager = virtualDisplayManager as? VirtualDisplayManager {
                manager.destroyDisplay()
            }
        }
        virtualDisplayManager = nil
        virtualDisplayFrame = nil
        isVirtualDisplayMode = false
    }
    
    private func sendVideoFrame(data: Data, isKeyframe: Bool) {
        guard nwConnection.state == .ready else {
            // print("[SEND] ERROR: Connection not ready, state=\(nwConnection.state)")
            return
        }
        
        let timestamp = UInt32((CACurrentMediaTime() - startTime) * 1000)
        let header = VideoFrameHeader(frameSize: UInt32(data.count), timestamp: timestamp, isKeyframe: isKeyframe)
        
        var frameData = header.toData()
        frameData.append(data)
        
        frameCount += 1
        
        // if frameCount <= 5 || frameCount % 60 == 0 || isKeyframe {
        //     print("[SEND] Frame #\(frameCount): \(frameData.count) bytes (header=\(VideoFrameHeader.headerSize), payload=\(data.count)), keyframe=\(isKeyframe)")
        //     // Log header bytes
        //     let headerBytes = frameData.prefix(VideoFrameHeader.headerSize).map { String(format: "%02X", $0) }.joined(separator: " ")
        //     print("[SEND] Header bytes: \(headerBytes)")
        // }
        
        nwConnection.send(content: frameData, completion: .contentProcessed { error in
            if let error = error {
//                 print("[SEND] ERROR sending frame: \(error)")
            }
        })
    }
    
    private func sendScreenInfo() {
        let screenInfo: ScreenInfoEvent
        
        if #available(macOS 14.0, *),
           isVirtualDisplayMode,
           let manager = virtualDisplayManager as? VirtualDisplayManager,
           let mode = manager.displayMode {
            // Report virtual display info
            screenInfo = ScreenInfoEvent(
                width: Double(mode.width),
                height: Double(mode.height),
                isVirtual: true,
                displayID: manager.displayID
            )
//             print("[Server] Screen info (virtual): \(mode.width)x\(mode.height), displayID=\(manager.displayID)")
        } else {
            // Report main screen info
            let screenSize = getMainScreenSize()
            screenInfo = ScreenInfoEvent(
                width: Double(screenSize.width),
                height: Double(screenSize.height),
                isVirtual: false,
                displayID: CGMainDisplayID()
            )
//             print("[Server] Screen info (physical): \(screenSize.width)x\(screenSize.height)")
        }
        
        send(event: .screenInfo(screenInfo))
    }
    
    private func sendControlRelease() {
        // print("[EDGE-SERVER] Sending controlRelease to client")
        // fflush(stdout)
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
        // print("[EDGE-SERVER] Cursor hidden")
        // fflush(stdout)
    }
    
    private func showCursor() {
        guard isCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isCursorHidden = false
        // print("[EDGE-SERVER] Cursor shown")
        // fflush(stdout)
    }
    
    private func send(event: RemoteInputEvent) {
        guard nwConnection.state == .ready else { return }
        do {
            let data = try JSONEncoder().encode(event)
            let framedData = data + ServerConnection.newline
            nwConnection.send(content: framedData, completion: .idempotent)
        } catch {
            // print("Failed to encode event: \(error)")
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
                
                // Use virtual display frame if active, otherwise use screen size
                let displayFrame = getActiveDisplayFrame()
                
                if let cgEvent = mouseEvent.toCGEvent(displayFrame: displayFrame) {
                    cgEvent.post(tap: .cgSessionEventTap)
                    checkRightEdge(displayFrame: displayFrame, deltaX: mouseEvent.deltaX)
                }
                
            case .warpCursor(let warpEvent):
                // Adjust warp position for virtual display frame
                let displayFrame = getActiveDisplayFrame()
                let point = CGPoint(
                    x: displayFrame.minX + warpEvent.x,
                    y: displayFrame.minY + warpEvent.y
                )
                CGWarpMouseCursorPosition(point)
//                 print("[Server] Warp cursor to: \(point) (virtual frame: \(isVirtualDisplayMode))")
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
                
            case .clientDesiredDisplayMode(let mode):
                handleDesiredDisplayMode(mode)
                
            case .screenInfo, .controlRelease, .virtualDisplayReady, .serverCapabilities:
                // These are server-to-client events, ignore
                break
            }
        } catch {
            // print("[SERVER] ERROR: Failed to decode: \(error)")
        }
    }
    
    /// Get the active display frame for mouse clamping and edge detection
    private func getActiveDisplayFrame() -> DisplayFrame {
        if isVirtualDisplayMode {
            // Refresh frame from CoreGraphics to ensure we have current bounds
            if #available(macOS 14.0, *) {
                if let manager = virtualDisplayManager as? VirtualDisplayManager, manager.isActive {
                    let frame = CGDisplayBounds(manager.displayID)
                    if !frame.isEmpty && frame.width > 0 {
                        return DisplayFrame(rect: frame)
                    }
                }
            }
            // Use cached frame if available
            if let frame = virtualDisplayFrame {
                return frame
            }
        }
        
        // Fallback to main screen
        guard let currentPos = CGEvent(source: nil)?.location else {
            return DisplayFrame(origin: .zero, size: getMainScreenSize())
        }
        
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(currentPos) }) {
            return DisplayFrame(rect: screen.frame)
        }
        
        return DisplayFrame(origin: .zero, size: getMainScreenSize())
    }
    
    private func checkRightEdge(displayFrame: DisplayFrame, deltaX: Double = 0) {
        // Skip edge checks for 500ms after warp to let mouse events settle
        let now = CACurrentMediaTime()
        let timeSinceWarp = now - warpCursorTime
        if timeSinceWarp < 0.5 {
            edgeMissLogCounter += 1
            return
        }
        
        guard let currentPos = CGEvent(source: nil)?.location else {
            return
        }
        
        let timeSinceLastRelease = now - lastEdgeReleaseTime
        let cooldownPassed = timeSinceLastRelease >= EdgeDetectionConfig.cooldownSeconds
        
        // Use display frame for edge detection
        let isAtRightEdge = displayFrame.isAtRightEdge(currentPos.x)
        
        if isAtRightEdge && cooldownPassed {
            lastEdgeReleaseTime = now
//             print("[Server] Right edge hit at x=\(currentPos.x), releasing control")
            sendControlRelease()
        } else {
            edgeMissLogCounter += 1
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