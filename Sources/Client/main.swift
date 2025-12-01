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
            return
        }
        
        // This will trigger the didSet observer
        isControllingRemote.toggle()
        print("Remote control toggled: \(isControllingRemote)")
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
        
        browser?.browseResultsChangedHandler = { results, changes in
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

    func send(event: RemoteKeyboardEvent) {
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
        }
        
        guard hasInputMonitoringPermission else {
            print("Input Monitoring permission not granted. Cannot start event tap.")
            DispatchQueue.main.async { self.isControllingRemote = false }
            return
        }

        // The C-style callback function needs a pointer to this class instance
        let selfAsPointer = Unmanaged.passUnretained(self).toOpaque()
        
        // Create the event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                // Get the KVMController instance
                let mySelf = Unmanaged<KVMController>.fromOpaque(refcon).takeUnretainedValue()
                return mySelf.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfAsPointer
        )

        guard let eventTap = eventTap else {
            print("Failed to create event tap.")
            DispatchQueue.main.async { self.isControllingRemote = false }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        guard let eventTap = eventTap else { return }
        print("Stopping event tap.")
        
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        self.runLoopSource = nil
        self.eventTap = nil
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Magic Combo check (double tap Left Control)
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
        
        // If we are controlling remote, create our custom event and send it
        if let remoteEvent = RemoteKeyboardEvent(event: event) {
            send(event: remoteEvent)
        }
        
        // And consume the event locally so it doesn't type on the client machine
        return nil
    }
    
    private func setupVideoCapture() {
        var device: AVCaptureDevice?

        // First, try to find an external device
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
        let view = NSView()
        view.wantsLayer = true
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        
        if #available(macOS 14.0, *) {
            previewLayer.connection?.videoRotationAngle = 0
        }
        
        view.layer = previewLayer
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}


struct ContentView: View {
    @EnvironmentObject var kvmController: KVMController
    
    var body: some View {
        ZStack {
            // Live video feed
            VideoView(session: kvmController.captureSession)
                .edgesIgnoringSafeArea(.all)

            VStack {
                Spacer()
                Button(action: {
                    kvmController.toggleRemoteControl()
                }) {
                    Text(kvmController.isControllingRemote ? "Release Control" : "Control MacBook")
                        .padding()
                        .background(kvmController.isControllingRemote ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }
        }
    }
}