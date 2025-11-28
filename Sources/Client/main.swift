import Cocoa
import Network
import ApplicationServices

// Check accessibility permissions
func checkAccessibility() -> Bool {
    let trusted = AXIsProcessTrusted()
    if !trusted {
        print("⚠️  Accessibility permission required!")
        print("   Go to: System Settings → Privacy & Security → Accessibility")
        print("   Add this app to the list and enable it.")
        print("")
        print("   Attempting to prompt for permission...")
        
        // This will prompt the user to grant permission
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

let INPUT_PORT: UInt16 = 9876

class InputReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var isProcessing = false
    private var eventQueue: [InputEvent] = []
    
    func start() {
        // Kill any existing listener
        listener?.cancel()
        listener = nil
        
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: INPUT_PORT)!)
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[Input] Server listening on port \(INPUT_PORT)")
                case .failed(let error):
                    print("[Input] Server failed: \(error)")
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                print("[Input] Host connected!")
                // Kill old connection, accept new one
                self?.connection?.cancel()
                self?.connection = conn
                conn.start(queue: .main)
                self?.receiveData()
            }
            listener?.start(queue: .main)
        } catch {
            print("[Input] Failed to start server: \(error)")
        }
    }
    
    private func receiveData() {
        guard let conn = connection else {
            print("[DEBUG] receiveData: No connection!")
            return
        }
        
        print("[DEBUG] receiveData: Waiting for data...")
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            print("[DEBUG] receiveData: Callback fired")
            
            guard let self = self else {
                print("[DEBUG] receiveData: self is nil!")
                return
            }
            
            if let error = error {
                print("[Input] Receive error: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                print("[DEBUG] receiveData: Got \(data.count) bytes")
                self.buffer.append(data)
                self.processBuffer()
            }
            
            if isComplete {
                print("[Input] Connection closed by host")
                return
            }
            
            print("[DEBUG] receiveData: Scheduling next receive...")
            // Use DispatchQueue to avoid potential stack issues
            DispatchQueue.main.async {
                print("[DEBUG] receiveData: Calling receiveData again")
                self.receiveData()
            }
        }
    }
    
    private func processBuffer() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let totalLength = 4 + Int(length)
            
            guard buffer.count >= totalLength else { break }
            
            let jsonData = buffer.subdata(in: 4..<totalLength)
            buffer.removeFirst(totalLength)
            
            if let event = try? JSONDecoder().decode(InputEvent.self, from: jsonData) {
                print("[DEBUG] Received event: \(event.type)")
                // Queue event and process serially
                self.eventQueue.append(event)
                self.processNextEvent()
            }
        }
    }
    
    private func processNextEvent() {
        guard !isProcessing, !eventQueue.isEmpty else { return }
        
        isProcessing = true
        let event = eventQueue.removeFirst()
        
        print("[DEBUG] Processing event: \(event.type)")
        handleEvent(event)
        print("[DEBUG] Event processed: \(event.type)")
        
        isProcessing = false
        
        // Process next event if any
        if !eventQueue.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.processNextEvent()
            }
        }
    }
    
    private func handleEvent(_ event: InputEvent) {
        print("[DEBUG] handleEvent called for: \(event.type)")
        switch event.type {
        case .mouseMove:
            if let x = event.x, let y = event.y {
                print("[DEBUG] mouseMove to (\(x), \(y))")
                moveMouse(to: CGPoint(x: x, y: y))
            }
            
        case .mouseDown:
            if let x = event.x, let y = event.y, let button = event.button {
                print("[DEBUG] mouseDown at (\(x), \(y)) button=\(button)")
                mouseDown(at: CGPoint(x: x, y: y), button: button)
            }
            
        case .mouseUp:
            if let x = event.x, let y = event.y, let button = event.button {
                print("[DEBUG] mouseUp at (\(x), \(y)) button=\(button)")
                mouseUp(at: CGPoint(x: x, y: y), button: button)
            }
            
        case .mouseDrag:
            if let x = event.x, let y = event.y, let button = event.button {
                print("[DEBUG] mouseDrag to (\(x), \(y)) button=\(button)")
                mouseDrag(to: CGPoint(x: x, y: y), button: button)
            }
            
        case .scroll:
            if let deltaX = event.deltaX, let deltaY = event.deltaY {
                print("[DEBUG] scroll deltaX=\(deltaX) deltaY=\(deltaY)")
                scroll(deltaX: deltaX, deltaY: deltaY)
            }
            
        case .keyDown:
            if let keyCode = event.keyCode {
                print("[DEBUG] keyDown keyCode=\(keyCode) flags=\(event.flags ?? 0)")
                keyDown(keyCode: keyCode, flags: event.flags ?? 0)
            }
            
        case .keyUp:
            if let keyCode = event.keyCode {
                print("[DEBUG] keyUp keyCode=\(keyCode) flags=\(event.flags ?? 0)")
                keyUp(keyCode: keyCode, flags: event.flags ?? 0)
            }
            
        case .flagsChanged:
            if let flags = event.flags {
                print("[DEBUG] flagsChanged flags=\(flags)")
                flagsChanged(flags: flags)
            }
        }
        print("[DEBUG] handleEvent completed for: \(event.type)")
    }
    
    // MARK: - Event Simulation
    
    private func moveMouse(to point: CGPoint) {
        print("[DEBUG] Creating mouseMoved CGEvent...")
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            print("[DEBUG] Failed to create mouseMoved event!")
            return
        }
        print("[DEBUG] Posting mouseMoved event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] mouseMoved posted successfully")
    }
    
    private func mouseDown(at point: CGPoint, button: Int) {
        print("[DEBUG] Creating mouseDown CGEvent...")
        let mouseType: CGEventType = button == 0 ? .leftMouseDown : .rightMouseDown
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            print("[DEBUG] Failed to create mouseDown event!")
            return
        }
        print("[DEBUG] Posting mouseDown event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] mouseDown posted successfully")
    }
    
    private func mouseUp(at point: CGPoint, button: Int) {
        print("[DEBUG] Creating mouseUp CGEvent...")
        let mouseType: CGEventType = button == 0 ? .leftMouseUp : .rightMouseUp
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            print("[DEBUG] Failed to create mouseUp event!")
            return
        }
        print("[DEBUG] Posting mouseUp event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] mouseUp posted successfully")
    }
    
    private func mouseDrag(to point: CGPoint, button: Int) {
        print("[DEBUG] Creating mouseDrag CGEvent...")
        let mouseType: CGEventType = button == 0 ? .leftMouseDragged : .rightMouseDragged
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            print("[DEBUG] Failed to create mouseDrag event!")
            return
        }
        print("[DEBUG] Posting mouseDrag event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] mouseDrag posted successfully")
    }
    
    private func scroll(deltaX: Double, deltaY: Double) {
        print("[DEBUG] Creating scroll CGEvent...")
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
            print("[DEBUG] Failed to create scroll event!")
            return
        }
        print("[DEBUG] Posting scroll event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] scroll posted successfully")
    }
    
    private func keyDown(keyCode: UInt16, flags: UInt64) {
        print("[DEBUG] Creating keyDown CGEvent for keyCode=\(keyCode)...")
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            print("[DEBUG] Failed to create keyDown event!")
            return
        }
        event.flags = CGEventFlags(rawValue: flags)
        print("[DEBUG] Posting keyDown event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] keyDown posted successfully")
    }
    
    private func keyUp(keyCode: UInt16, flags: UInt64) {
        print("[DEBUG] Creating keyUp CGEvent for keyCode=\(keyCode)...")
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            print("[DEBUG] Failed to create keyUp event!")
            return
        }
        event.flags = CGEventFlags(rawValue: flags)
        print("[DEBUG] Posting keyUp event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] keyUp posted successfully")
    }
    
    private func flagsChanged(flags: UInt64) {
        print("[DEBUG] Creating flagsChanged CGEvent for flags=\(flags)...")
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            print("[DEBUG] Failed to create flagsChanged event!")
            return
        }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags)
        print("[DEBUG] Posting flagsChanged event...")
        event.post(tap: .cgSessionEventTap)
        print("[DEBUG] flagsChanged posted successfully")
    }
}

// App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var inputReceiver: InputReceiver?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Remote Keyboard/Mouse Client ===")
        print("Listening for input events on port \(INPUT_PORT)")
        print("New connections will kill existing ones")
        print("")
        
        // Check accessibility first
        let hasAccess = checkAccessibility()
        if hasAccess {
            print("✅ Accessibility permission granted")
        } else {
            print("⏳ Waiting for accessibility permission...")
            print("   Grant permission, then restart this app.")
        }
        print("")
        
        inputReceiver = InputReceiver()
        inputReceiver?.start()
    }
}

// Main - Use NSApplication to ensure proper CoreGraphics initialization
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
