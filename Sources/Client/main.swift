import Cocoa
import Network
import ApplicationServices

// MARK: - Use separate thread for event posting with CGEvent
// The trace trap appears to be related to CGEvent usage from certain contexts
// We'll use a dedicated background thread with its own run loop for all event posting

class EventPoster {
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let eventQueue = DispatchQueue(label: "event.poster", qos: .userInteractive)
    private var eventSource: CGEventSource?
    private var isReady = false
    
    func start() {
        thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread?.name = "EventPosterThread"
        thread?.qualityOfService = .userInteractive
        thread?.start()
        
        // Wait for thread to be ready
        while !isReady {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    
    private func threadMain() {
        // Create event source on this thread
        eventSource = CGEventSource(stateID: .combinedSessionState)
        runLoop = CFRunLoopGetCurrent()
        isReady = true
        
        // Run the loop forever
        CFRunLoopRun()
    }
    
    func postMouseMove(x: Double, y: Double) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            let point = CGPoint(x: x, y: y)
            
            // Try CGEvent first for proper event generation
            if let event = CGEvent(mouseEventSource: self.eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
            
            // Also use CGWarpMouseCursorPosition as backup
            CGWarpMouseCursorPosition(point)
        }
        CFRunLoopWakeUp(runLoop)
    }
    
    func postMouseButton(x: Double, y: Double, button: Int, isDown: Bool) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            let point = CGPoint(x: x, y: y)
            CGWarpMouseCursorPosition(point)
            
            let mouseType: CGEventType
            let mouseButton: CGMouseButton
            
            if button == 0 {
                mouseType = isDown ? .leftMouseDown : .leftMouseUp
                mouseButton = .left
            } else {
                mouseType = isDown ? .rightMouseDown : .rightMouseUp
                mouseButton = .right
            }
            
            if let event = CGEvent(mouseEventSource: self.eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) {
                event.post(tap: .cghidEventTap)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    
    func postMouseDrag(x: Double, y: Double, button: Int) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            let point = CGPoint(x: x, y: y)
            CGWarpMouseCursorPosition(point)
            
            let mouseType: CGEventType = button == 0 ? .leftMouseDragged : .rightMouseDragged
            let mouseButton: CGMouseButton = button == 0 ? .left : .right
            
            if let event = CGEvent(mouseEventSource: self.eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) {
                event.post(tap: .cghidEventTap)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    
    func postScroll(deltaX: Double, deltaY: Double) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            if let event = CGEvent(scrollWheelEvent2Source: self.eventSource, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 3), wheel2: Int32(deltaX * 3), wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    
    func postKey(keyCode: UInt16, flags: UInt64, isDown: Bool) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            if let event = CGEvent(keyboardEventSource: self.eventSource, virtualKey: keyCode, keyDown: isDown) {
                event.flags = CGEventFlags(rawValue: flags)
                event.post(tap: .cghidEventTap)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    
    func postFlagsChanged(flags: UInt64) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self = self else { return }
            
            if let event = CGEvent(keyboardEventSource: self.eventSource, virtualKey: 0, keyDown: false) {
                event.type = .flagsChanged
                event.flags = CGEventFlags(rawValue: flags)
                event.post(tap: .cghidEventTap)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
}

// Global event poster
let eventPoster = EventPoster()

// Check accessibility permissions
func checkAccessibility() -> Bool {
    let trusted = AXIsProcessTrusted()
    if !trusted {
        print("⚠️  Accessibility permission required!")
        print("   Go to: System Settings → Privacy & Security → Accessibility")
        print("   Add this app to the list and enable it.")
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    return trusted
}

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
}

// Status message from Client to Host
struct StatusMessage: Codable {
    let message: String
}

let INPUT_PORT: UInt16 = 9876
let STATUS_PORT: UInt16 = 9877

class InputReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var statusConnection: NWConnection?
    private var hostIP: String?
    
    func start() {
        listener?.cancel()
        listener = nil
        
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: INPUT_PORT)!)
            listener?.stateUpdateHandler = { state in
                if case .ready = state {
                    print("[Input] Server listening on port \(INPUT_PORT)")
                } else if case .failed(let error) = state {
                    print("[Input] Server failed: \(error)")
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                print("[Input] Host connected!")
                self?.connection?.cancel()
                self?.buffer = Data()
                self?.connection = conn
                
                // Extract host IP for status connection
                if case .hostPort(let host, _) = conn.endpoint {
                    self?.hostIP = "\(host)"
                    self?.connectStatusChannel()
                }
                
                conn.start(queue: .main)
                self?.receiveData()
            }
            listener?.start(queue: .main)
        } catch {
            print("[Input] Failed to start server: \(error)")
        }
    }
    
    private func connectStatusChannel() {
        guard let hostIP = hostIP else { return }
        
        statusConnection?.cancel()
        statusConnection = NWConnection(
            host: NWEndpoint.Host(hostIP),
            port: NWEndpoint.Port(rawValue: STATUS_PORT)!,
            using: .tcp
        )
        statusConnection?.start(queue: .main)
        sendStatus("Client ready - event poster thread running")
    }
    
    private func sendStatus(_ message: String) {
        guard let conn = statusConnection else { return }
        
        if let data = try? JSONEncoder().encode(StatusMessage(message: message)) {
            var length = UInt32(data.count).bigEndian
            var frameData = Data(bytes: &length, count: 4)
            frameData.append(data)
            conn.send(content: frameData, completion: .contentProcessed { _ in })
        }
    }
    
    private func receiveData() {
        guard let conn = connection else { return }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[Input] Receive error: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            
            if isComplete {
                print("[Input] Connection closed")
                return
            }
            
            self.receiveData()
        }
    }
    
    private func processBuffer() {
        while buffer.count >= 4 {
            // Read length safely without assuming alignment
            let lengthBytes = buffer.prefix(4)
            let length = UInt32(bigEndian: UInt32(lengthBytes[0]) << 24 | 
                                           UInt32(lengthBytes[1]) << 16 | 
                                           UInt32(lengthBytes[2]) << 8 | 
                                           UInt32(lengthBytes[3]))
            let totalLength = 4 + Int(length)
            
            guard buffer.count >= totalLength else { break }
            
            let jsonData = buffer.subdata(in: 4..<totalLength)
            buffer.removeFirst(totalLength)
            
            if let event = try? JSONDecoder().decode(InputEvent.self, from: jsonData) {
                handleEvent(event)
            }
        }
    }
    
    private func handleEvent(_ event: InputEvent) {
        sendStatus("Processing: \(event.type)")
        
        switch event.type {
        case .mouseMove:
            if let x = event.x, let y = event.y {
                sendStatus("mouseMove to (\(Int(x)), \(Int(y)))")
                eventPoster.postMouseMove(x: x, y: y)
                sendStatus("✓ mouseMove posted")
            }
            
        case .mouseDown:
            if let x = event.x, let y = event.y, let button = event.button {
                eventPoster.postMouseButton(x: x, y: y, button: button, isDown: true)
                sendStatus("✓ mouseDown")
            }
            
        case .mouseUp:
            if let x = event.x, let y = event.y, let button = event.button {
                eventPoster.postMouseButton(x: x, y: y, button: button, isDown: false)
                sendStatus("✓ mouseUp")
            }
            
        case .mouseDrag:
            if let x = event.x, let y = event.y, let button = event.button {
                eventPoster.postMouseDrag(x: x, y: y, button: button)
                sendStatus("✓ mouseDrag")
            }
            
        case .scroll:
            if let deltaX = event.deltaX, let deltaY = event.deltaY {
                eventPoster.postScroll(deltaX: deltaX, deltaY: deltaY)
                sendStatus("✓ scroll")
            }
            
        case .keyDown:
            if let keyCode = event.keyCode {
                eventPoster.postKey(keyCode: keyCode, flags: event.flags ?? 0, isDown: true)
                sendStatus("✓ keyDown \(keyCode)")
            }
            
        case .keyUp:
            if let keyCode = event.keyCode {
                eventPoster.postKey(keyCode: keyCode, flags: event.flags ?? 0, isDown: false)
                sendStatus("✓ keyUp \(keyCode)")
            }
            
        case .flagsChanged:
            if let flags = event.flags {
                eventPoster.postFlagsChanged(flags: flags)
                sendStatus("✓ flagsChanged")
            }
        }
    }
}

// App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var inputReceiver: InputReceiver?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Remote Keyboard/Mouse Client ===")
        print("Using dedicated event poster thread")
        print("")
        
        // Ensure cursor is visible
        CGDisplayShowCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(1)
        
        // Start event poster thread first
        eventPoster.start()
        print("✅ Event poster thread started")
        
        // Check accessibility
        if checkAccessibility() {
            print("✅ Accessibility permission granted")
        } else {
            print("⏳ Grant accessibility permission and restart")
        }
        print("")
        
        inputReceiver = InputReceiver()
        inputReceiver?.start()
    }
}

// Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
