import SwiftUI
import AVFoundation
import Network
import CoreGraphics
import SharedCode
import AppKit

@main
struct ClientApp: App {
    @StateObject private var kvmController = KVMController()
    
    init() {
        // Required for SwiftUI apps built with SPM and run from terminal
        // This ensures the app appears as a regular GUI application
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(kvmController)
                .onAppear {
                    // Enter fullscreen mode when the window appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let window = NSApplication.shared.windows.first {
                            window.toggleFullScreen(nil)
                        }
                    }
                }
        }
    }
}

class KVMController: ObservableObject {
    // To be implemented:
    // 1. Video Capture State
    // 2. Network Browser and Connection State
    // 3. Control State (isControllingRemote)
    // 4. Event Tap manager
    
    @Published var isControllingRemote: Bool = false {
        didSet {
            if isControllingRemote {
                startEventTap()
            } else {
                stopEventTap()
            }
        }
    }
    @Published var captureSession = AVCaptureSession()
    
    // Networking
    private var browser: NWBrowser?
    private var connection: NWConnection?
    
    // Event Tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let magicComboKey: CGKeyCode = 59 // Left Control
    private var lastMagicKeyPressTime: TimeInterval = 0
    
    // Cached permission state (checked once at launch)
    private var hasInputMonitoringPermission: Bool = false
    
    init() {
        print("KVMController initialized.")
        checkAndCachePermissions()
        setupVideoCapture()
        startBrowsing()
    }
    
    deinit {
        stop()
    }
    
    /// Check permissions once at launch and cache the result
    private func checkAndCachePermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        hasInputMonitoringPermission = AXIsProcessTrustedWithOptions(options)
        
        if !hasInputMonitoringPermission {
            print("\n--- PERMISSION REQUIRED ---")
            print("This application needs Input Monitoring permissions to capture keyboard events.")
            print("Please go to System Settings > Privacy & Security > Input Monitoring and enable it for 'Client'.")
            print("---------------------------\n")
        }
    }
    
    /// Clean up all resources
    func stop() {
        stopEventTap()
        
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
        
        print("KVMController resources cleaned up.")
    }
    
    func toggleRemoteControl() {
        // Only allow controlling remote if we have a connection
        guard connection?.state == .ready else {
            print("Cannot control remote: No server connection.")
            fflush(stdout)
            return
        }
        
        // This will trigger the didSet observer
        isControllingRemote.toggle()
        print("Remote control toggled: \(isControllingRemote)")
        fflush(stdout)
    }
    
    // MARK: - Networking
    
    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: NetworkConstants.serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)
        
        browser?.stateUpdateHandler = { [weak self] newState in
            print("Browser state updated: \(newState)")
            switch newState {
            case .failed(let error):
                print("Browser failed with error: \(error). Restarting...")
                self?.browser?.cancel()
                self?.browser = nil
                // Restart browsing after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.startBrowsing()
                }
            case .cancelled:
                print("Browser cancelled.")
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
        
        print("Starting Bonjour browser...")
        browser?.start(queue: .main)
    }
    
    private func connect(to endpoint: NWEndpoint) {
        print("Connecting to server at \(endpoint)...")
        connection?.cancel()
        
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] newState in
            print("Connection state updated: \(newState)")
            switch newState {
            case .ready:
                print("Connection ready.")
            case .failed, .cancelled:
                print("Connection lost.")
                self?.connection = nil
                DispatchQueue.main.async { self?.isControllingRemote = false }
            default:
                break
            }
        }
        connection?.start(queue: .main)
    }

    func send(event: RemoteInputEvent) {
        guard connection?.state == .ready else { return }
        
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(event)
            let framedData = data + "\n".data(using: .utf8)!
            connection?.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("Send failed: \(error). Releasing control.")
                    DispatchQueue.main.async {
                        self?.isControllingRemote = false
                    }
                }
            })
        } catch {
            print("Failed to encode and send event: \(error)")
        }
    }
    
    // MARK: - Event Tap
    
    private func startEventTap() {
        guard eventTap == nil else { return }
        print("Starting event tap...")
        
        // Use cached permission state; re-check without prompting
        // (User was already prompted once at launch)
        if !hasInputMonitoringPermission {
            // Re-check silently in case user granted permission after launch
            hasInputMonitoringPermission = AXIsProcessTrusted()
            print("Re-checked permission: \(hasInputMonitoringPermission)")
        }
        
        guard hasInputMonitoringPermission else {
            print("Input Monitoring permission not granted. Cannot start event tap.")
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
            print("Failed to create event tap. Make sure Input Monitoring permission is granted.")
            fflush(stdout)
            DispatchQueue.main.async { self.isControllingRemote = false }
            return
        }
        
        print("Event tap created successfully")
        fflush(stdout)

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        
        // IMPORTANT: Add to MAIN run loop, not current (which might be different in SwiftUI)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        print("Event tap enabled and added to main run loop")
        fflush(stdout)
    }

    private func stopEventTap() {
        guard let eventTap = eventTap else { return }
        print("Stopping event tap.")
        
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.runLoopSource = nil
        self.eventTap = nil
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled event (system can disable taps if they take too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("Event tap was disabled, re-enabling...")
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Magic Combo check (double tap Left Control) - only for keyboard events
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == magicComboKey {
                let currentTime = ProcessInfo.processInfo.systemUptime
                if currentTime - lastMagicKeyPressTime < 0.3 { // Double tap interval
                    print("Magic combo detected! Releasing control.")
                    DispatchQueue.main.async { self.isControllingRemote = false }
                    lastMagicKeyPressTime = 0 // Reset timer
                    return nil // Consume the event
                }
                lastMagicKeyPressTime = currentTime
            }
        }
        
        // If we're not controlling remote, pass the event through unmodified
        guard isControllingRemote else {
            return Unmanaged.passUnretained(event)
        }
        
        // Determine if this is a keyboard or mouse event and send accordingly
        let isMouseEvent = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ].contains(type)
        
        if isMouseEvent {
            // Get screen size for coordinate normalization
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            
            if let remoteEvent = RemoteMouseEvent(event: event, screenSize: screenSize) {
                send(event: .mouse(remoteEvent))
                // Only log non-move events to reduce spam
                if type != .mouseMoved {
                    print("Sent mouse event: \(remoteEvent.eventType)")
                    fflush(stdout)
                }
            }
        } else {
            // Keyboard event
            if let remoteEvent = RemoteKeyboardEvent(event: event) {
                send(event: .keyboard(remoteEvent))
                print("Sent keyboard event: keyCode=\(remoteEvent.keyCode)")
                fflush(stdout)
            }
        }
        
        // Consume the event locally so it doesn't affect the client machine
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
            print("No video capture device found. Please connect a camera or capture card.")
            return
        }
        
        print("Using video device: \(finalDevice.localizedName)")
        
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
                print("Video configured: \(dims.width)x\(dims.height) @ \(bestFrameRate) fps")
            }
            
            finalDevice.unlockForConfiguration()
        } catch {
            print("Could not configure video device: \(error)")
        }

        do {
            // Make sure to remove any existing input before adding a new one
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            
            let input = try AVCaptureDeviceInput(device: finalDevice)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            if !captureSession.isRunning {
                // Start the session on a background thread
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.captureSession.startRunning()
                }
            }
            
        } catch {
            print("Failed to create video device input: \(error)")
        }
    }
}

struct VideoView: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> NSView {
        let view = VideoContainerView()
        view.wantsLayer = true
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill  // Fill the entire view
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
            // Ensure the layer fills the view
            previewLayer.frame = nsView.bounds
        }
    }
}

// Custom NSView that updates layer frame on resize
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
        ZStack {
            // Live video feed - fills entire screen
            VideoView(session: kvmController.captureSession)
                .ignoresSafeArea(.all)
                .onTapGesture {
                    // Toggle control visibility on tap
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
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
                        
                        Spacer()
                        
                        Text("Double-tap Left Control to release")
                            .font(.caption)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.gray)
                            .cornerRadius(8)
                            .opacity(kvmController.isControllingRemote ? 1 : 0)
                    }
                    .padding()
                    
                    Spacer()
                    
                    Button(action: {
                        kvmController.toggleRemoteControl()
                    }) {
                        Text(kvmController.isControllingRemote ? "Release Control (or double-tap Left Ctrl)" : "Control MacBook")
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
    }
}