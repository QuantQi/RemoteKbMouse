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
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.buffer.append(data)
                self?.processBuffer()
            }
            
            if let error = error {
                print("[Input] Receive error: \(error)")
                return
            }
            
            if isComplete {
                print("[Input] Connection closed by host")
                return
            }
            
            self?.receiveData()
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
                handleEvent(event)
            }
        }
    }
    
    private func handleEvent(_ event: InputEvent) {
        switch event.type {
        case .mouseMove:
            if let x = event.x, let y = event.y {
                moveMouse(to: CGPoint(x: x, y: y))
            }
            
        case .mouseDown:
            if let x = event.x, let y = event.y, let button = event.button {
                mouseDown(at: CGPoint(x: x, y: y), button: button)
            }
            
        case .mouseUp:
            if let x = event.x, let y = event.y, let button = event.button {
                mouseUp(at: CGPoint(x: x, y: y), button: button)
            }
            
        case .mouseDrag:
            if let x = event.x, let y = event.y, let button = event.button {
                mouseDrag(to: CGPoint(x: x, y: y), button: button)
            }
            
        case .scroll:
            if let deltaX = event.deltaX, let deltaY = event.deltaY {
                scroll(deltaX: deltaX, deltaY: deltaY)
            }
            
        case .keyDown:
            if let keyCode = event.keyCode {
                keyDown(keyCode: keyCode, flags: event.flags ?? 0)
            }
            
        case .keyUp:
            if let keyCode = event.keyCode {
                keyUp(keyCode: keyCode, flags: event.flags ?? 0)
            }
            
        case .flagsChanged:
            if let flags = event.flags {
                flagsChanged(flags: flags)
            }
        }
    }
    
    // MARK: - Event Simulation
    
    private func moveMouse(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cgSessionEventTap)
    }
    
    private func mouseDown(at point: CGPoint, button: Int) {
        let mouseType: CGEventType = button == 0 ? .leftMouseDown : .rightMouseDown
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        event.post(tap: .cgSessionEventTap)
    }
    
    private func mouseUp(at point: CGPoint, button: Int) {
        let mouseType: CGEventType = button == 0 ? .leftMouseUp : .rightMouseUp
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        event.post(tap: .cgSessionEventTap)
    }
    
    private func mouseDrag(to point: CGPoint, button: Int) {
        let mouseType: CGEventType = button == 0 ? .leftMouseDragged : .rightMouseDragged
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        event.post(tap: .cgSessionEventTap)
    }
    
    private func scroll(deltaX: Double, deltaY: Double) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else { return }
        event.post(tap: .cgSessionEventTap)
    }
    
    private func keyDown(keyCode: UInt16, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cgSessionEventTap)
    }
    
    private func keyUp(keyCode: UInt16, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cgSessionEventTap)
    }
    
    private func flagsChanged(flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cgSessionEventTap)
    }
}

// Main
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

let inputReceiver = InputReceiver()
inputReceiver.start()

RunLoop.main.run()
