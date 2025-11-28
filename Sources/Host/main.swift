import Cocoa
import Network
import AVFoundation
import CoreMediaIO

// Shared protocol for mouse/keyboard events
struct InputEvent: Codable {
    enum EventType: String, Codable {
        case mouseMove
        case mouseDown
        case mouseUp
        case mouseDrag
        case scroll
        case keyDown
        case keyUp
        case flagsChanged
    }
    
    let type: EventType
    let x: Double?
    let y: Double?
    let deltaX: Double?
    let deltaY: Double?
    let button: Int?
    let keyCode: UInt16?
    let flags: UInt64?
    
    init(type: EventType, x: Double? = nil, y: Double? = nil, deltaX: Double? = nil, deltaY: Double? = nil, button: Int? = nil, keyCode: UInt16? = nil, flags: UInt64? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.keyCode = keyCode
        self.flags = flags
    }
}

let PORT: UInt16 = 9876
let DEFAULT_CLIENT_IP = "192.168.1.8"

// Enable access to video capture devices
func enableCaptureDevices() {
    var property = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout.size(ofValue: allow)), &allow)
}

// MARK: - Video Preview Window

class VideoPreviewView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    func setSession(_ session: AVCaptureSession) {
        previewLayer?.removeFromSuperlayer()
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspect
        previewLayer?.frame = bounds
        layer?.addSublayer(previewLayer!)
    }
    
    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

class VideoWindow: NSWindow {
    init() {
        // Get main screen size for fullscreen
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .normal
        self.backgroundColor = .black
        self.isOpaque = true
        self.hasShadow = false
        self.collectionBehavior = [.fullScreenPrimary, .managed]
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class VideoCapture: NSObject {
    private var captureSession: AVCaptureSession?
    var window: VideoWindow?
    private var previewView: VideoPreviewView?
    
    override init() {
        super.init()
        enableCaptureDevices()
    }
    
    func start() {
        setupWindow()
        setupCapture()
    }
    
    func isWindowKey() -> Bool {
        return window?.isKeyWindow ?? false
    }
    
    private func setupWindow() {
        window = VideoWindow()
        previewView = VideoPreviewView(frame: window!.contentView!.bounds)
        previewView?.autoresizingMask = [.width, .height]
        window?.contentView?.addSubview(previewView!)
        window?.makeKeyAndOrderFront(nil)
        window?.toggleFullScreen(nil)
    }
    
    private func setupCapture() {
        captureSession = AVCaptureSession()
        
        // Find video capture card
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        print("[Video] Available devices:")
        for device in discoverySession.devices {
            print("  - \(device.localizedName) [\(device.uniqueID)]")
        }
        
        // Prefer external capture card
        guard let device = discoverySession.devices.first(where: { 
            $0.deviceType == .externalUnknown ||
            $0.localizedName.lowercased().contains("capture")
        }) ?? discoverySession.devices.first else {
            print("[Video] No capture device found!")
            return
        }
        
        print("[Video] Using device: \(device.localizedName)")
        
        // Find highest resolution and frame rate format
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRate: Float64 = 0
        var bestResolution: Int = 0
        
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let resolution = Int(dims.width) * Int(dims.height)
            
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
        
        do {
            try device.lockForConfiguration()
            
            if let format = bestFormat {
                device.activeFormat = format
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("[Video] Resolution: \(dims.width)x\(dims.height)")
                
                // Set highest frame rate
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate == bestFrameRate {
                        device.activeVideoMinFrameDuration = range.minFrameDuration
                        device.activeVideoMaxFrameDuration = range.minFrameDuration
                        print("[Video] Frame rate: \(bestFrameRate) fps")
                        break
                    }
                }
            }
            
            device.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession?.canAddInput(input) == true {
                captureSession?.addInput(input)
            }
            
            previewView?.setSession(captureSession!)
            captureSession?.startRunning()
            print("[Video] Capture started")
            
        } catch {
            print("[Video] Failed to setup capture: \(error)")
        }
    }
}

// MARK: - Input Controller

class InputController {
    private var connection: NWConnection?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isCapturing = false
    private var manualOverride = false  // When true, ignore auto-switching
    private let clientAddress: String
    weak var videoCapture: VideoCapture?
    
    // Key code for 'C' key
    private let cKeyCode: UInt16 = 8
    
    init(clientAddress: String) {
        self.clientAddress = clientAddress
        print("[Input] Target client: \(clientAddress):\(PORT)")
        print("[Input] Press Cmd+Option+Ctrl+C to toggle capture mode (manual override)")
        print("[Input] Auto-switch: Focus video window = client, focus other = host")
        setupHotkeyMonitor()
        setupWindowFocusMonitor()
    }
    
    private func setupWindowFocusMonitor() {
        // Monitor for window focus changes
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowFocusChange(notification)
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowFocusChange(notification)
        }
        
        // Also monitor app activation
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAutoSwitch()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // App lost focus, switch to local
            guard let self = self, !self.manualOverride else { return }
            if self.isCapturing {
                print("[Auto] App lost focus -> local mode")
                self.stopCapturing()
            }
        }
    }
    
    private func handleWindowFocusChange(_ notification: Notification) {
        checkAutoSwitch()
    }
    
    private func checkAutoSwitch() {
        guard !manualOverride else { return }
        
        let videoWindowIsKey = videoCapture?.isWindowKey() ?? false
        
        if videoWindowIsKey && !isCapturing {
            print("[Auto] Video window focused -> client mode")
            startCapturing()
        } else if !videoWindowIsKey && isCapturing {
            print("[Auto] Video window lost focus -> local mode")
            stopCapturing()
        }
    }
    
    private func setupHotkeyMonitor() {
        // Monitor for toggle hotkey even when not capturing
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let controller = Unmanaged<InputController>.fromOpaque(refcon!).takeUnretainedValue()
            return controller.handleHotkeyEvent(proxy: proxy, type: type, event: event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Input] Failed to create hotkey monitor. Grant Accessibility permission.")
            return
        }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleHotkeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            
            let hasCmd = (flags & UInt64(CGEventFlags.maskCommand.rawValue)) != 0
            let hasOpt = (flags & UInt64(CGEventFlags.maskAlternate.rawValue)) != 0
            let hasCtrl = (flags & UInt64(CGEventFlags.maskControl.rawValue)) != 0
            
            if keyCode == cKeyCode && hasCmd && hasOpt && hasCtrl {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Toggle manual override
                    self.manualOverride = !self.manualOverride
                    if self.manualOverride {
                        print("[Manual] Override ON - auto-switch disabled")
                        if self.isCapturing {
                            self.stopCapturing()
                        } else {
                            self.startCapturing()
                        }
                    } else {
                        print("[Manual] Override OFF - auto-switch enabled")
                        self.checkAutoSwitch()
                    }
                }
                return nil
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    func startCapturing() {
        guard !isCapturing else { return }
        
        // Connect to client
        connection?.cancel()
        connection = NWConnection(
            host: NWEndpoint.Host(clientAddress),
            port: NWEndpoint.Port(rawValue: PORT)!,
            using: .tcp
        )
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Input] Connected to client")
            case .failed(let error):
                print("[Input] Connection failed: \(error)")
                self?.stopCapturing()
            default:
                break
            }
        }
        
        connection?.start(queue: .main)
        
        // Create event tap for all input events
        var eventMask: CGEventMask = 0
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.keyUp.rawValue)
        eventMask |= (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let controller = Unmanaged<InputController>.fromOpaque(refcon!).takeUnretainedValue()
            return controller.handleCapturedEvent(proxy: proxy, type: type, event: event)
        }
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            print("[Input] Failed to create event tap")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isCapturing = true
        print("🔴 [Input] Capturing - events sent to client")
    }
    
    func stopCapturing() {
        guard isCapturing else { return }
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        connection?.cancel()
        connection = nil
        isCapturing = false
        print("🟢 [Input] Local mode - events stay on host")
    }
    
    private func handleCapturedEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Check for toggle hotkey
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            
            let hasCmd = (flags & UInt64(CGEventFlags.maskCommand.rawValue)) != 0
            let hasOpt = (flags & UInt64(CGEventFlags.maskAlternate.rawValue)) != 0
            let hasCtrl = (flags & UInt64(CGEventFlags.maskControl.rawValue)) != 0
            
            if keyCode == cKeyCode && hasCmd && hasOpt && hasCtrl {
                DispatchQueue.main.async { [weak self] in
                    self?.stopCapturing()
                }
                return nil
            }
        }
        
        // Re-enable tap if disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        var inputEvent: InputEvent?
        let location = event.location
        
        switch type {
        case .mouseMoved:
            print("[DEBUG] Host: mouseMoved at (\(location.x), \(location.y))")
            inputEvent = InputEvent(type: .mouseMove, x: location.x, y: location.y)
            
        case .leftMouseDown:
            print("[DEBUG] Host: leftMouseDown at (\(location.x), \(location.y))")
            inputEvent = InputEvent(type: .mouseDown, x: location.x, y: location.y, button: 0)
            
        case .leftMouseUp:
            print("[DEBUG] Host: leftMouseUp at (\(location.x), \(location.y))")
            inputEvent = InputEvent(type: .mouseUp, x: location.x, y: location.y, button: 0)
            
        case .rightMouseDown:
            print("[DEBUG] Host: rightMouseDown at (\(location.x), \(location.y))")
            inputEvent = InputEvent(type: .mouseDown, x: location.x, y: location.y, button: 1)
            
        case .rightMouseUp:
            print("[DEBUG] Host: rightMouseUp at (\(location.x), \(location.y))")
            inputEvent = InputEvent(type: .mouseUp, x: location.x, y: location.y, button: 1)
            
        case .leftMouseDragged, .rightMouseDragged:
            let button = type == .leftMouseDragged ? 0 : 1
            print("[DEBUG] Host: mouseDrag at (\(location.x), \(location.y)) button=\(button)")
            inputEvent = InputEvent(type: .mouseDrag, x: location.x, y: location.y, button: button)
            
        case .scrollWheel:
            let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            print("[DEBUG] Host: scroll deltaX=\(deltaX) deltaY=\(deltaY)")
            inputEvent = InputEvent(type: .scroll, deltaX: deltaX, deltaY: deltaY)
            
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            print("[DEBUG] Host: keyDown keyCode=\(keyCode) flags=\(event.flags.rawValue)")
            inputEvent = InputEvent(type: .keyDown, keyCode: keyCode, flags: event.flags.rawValue)
            
        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            print("[DEBUG] Host: keyUp keyCode=\(keyCode) flags=\(event.flags.rawValue)")
            inputEvent = InputEvent(type: .keyUp, keyCode: keyCode, flags: event.flags.rawValue)
            
        case .flagsChanged:
            print("[DEBUG] Host: flagsChanged flags=\(event.flags.rawValue)")
            inputEvent = InputEvent(type: .flagsChanged, flags: event.flags.rawValue)
            
        default:
            return Unmanaged.passRetained(event)
        }
        
        if let inputEvent = inputEvent {
            print("[DEBUG] Host: Sending event to client...")
            sendEvent(inputEvent)
            print("[DEBUG] Host: Event sent")
        }
        
        // Consume the event
        return nil
    }
    
    private func sendEvent(_ event: InputEvent) {
        guard let connection = connection else { return }
        
        if let data = try? JSONEncoder().encode(event) {
            var length = UInt32(data.count).bigEndian
            var frameData = Data(bytes: &length, count: 4)
            frameData.append(data)
            
            connection.send(content: frameData, completion: .contentProcessed { _ in })
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var videoCapture: VideoCapture?
    var inputController: InputController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let clientIP = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : DEFAULT_CLIENT_IP
        
        print("=== Remote Keyboard/Mouse Host ===")
        print("Client IP: \(clientIP)")
        print("")
        
        // Start video capture and display
        videoCapture = VideoCapture()
        videoCapture?.start()
        
        // Start input controller with reference to video capture
        inputController = InputController(clientAddress: clientIP)
        inputController?.videoCapture = videoCapture
        
        print("")
    }
}

// Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
