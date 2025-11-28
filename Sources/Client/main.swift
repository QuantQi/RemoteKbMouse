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

// Global event source - create once and reuse
var globalEventSource: CGEventSource?

func getEventSource() -> CGEventSource? {
    if globalEventSource == nil {
        globalEventSource = CGEventSource(stateID: .hidSystemState)
    }
    return globalEventSource
}

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
                self?.buffer = Data()  // Clear buffer on new connection
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
                print("[Input] Connection closed by host")
                return
            }
            
            self.receiveData()
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
                // Handle immediately on main thread
                handleEvent(event)
            }
        }
    }
    
    private func handleEvent(_ event: InputEvent) {
        autoreleasepool {
            switch event.type {
            case .mouseMove:
                if let x = event.x, let y = event.y {
                    moveMouse(to: CGPoint(x: x, y: y))
                }
                
            case .mouseDown:
                if let x = event.x, let y = event.y, let button = event.button {
                    mouseClick(at: CGPoint(x: x, y: y), button: button, isDown: true)
                }
                
            case .mouseUp:
                if let x = event.x, let y = event.y, let button = event.button {
                    mouseClick(at: CGPoint(x: x, y: y), button: button, isDown: false)
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
                    keyEvent(keyCode: keyCode, flags: event.flags ?? 0, isDown: true)
                }
                
            case .keyUp:
                if let keyCode = event.keyCode {
                    keyEvent(keyCode: keyCode, flags: event.flags ?? 0, isDown: false)
                }
                
            case .flagsChanged:
                if let flags = event.flags {
                    flagsChanged(flags: flags)
                }
            }
        }
    }
    
    // MARK: - Event Simulation using CGWarp and CGEvent with shared source
    
    private func moveMouse(to point: CGPoint) {
        // Use CGWarpMouseCursorPosition - most reliable
        CGWarpMouseCursorPosition(point)
        // Optionally associate with display
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    
    private func mouseClick(at point: CGPoint, button: Int, isDown: Bool) {
        // First warp cursor to position
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
        
        if let event = CGEvent(mouseEventSource: getEventSource(), mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func mouseDrag(to point: CGPoint, button: Int) {
        CGWarpMouseCursorPosition(point)
        
        let mouseType: CGEventType = button == 0 ? .leftMouseDragged : .rightMouseDragged
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        
        if let event = CGEvent(mouseEventSource: getEventSource(), mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func scroll(deltaX: Double, deltaY: Double) {
        if let event = CGEvent(scrollWheelEvent2Source: getEventSource(), units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 10), wheel2: Int32(deltaX * 10), wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func keyEvent(keyCode: UInt16, flags: UInt64, isDown: Bool) {
        if let event = CGEvent(keyboardEventSource: getEventSource(), virtualKey: keyCode, keyDown: isDown) {
            event.flags = CGEventFlags(rawValue: flags)
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func flagsChanged(flags: UInt64) {
        if let event = CGEvent(keyboardEventSource: getEventSource(), virtualKey: 0, keyDown: false) {
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: flags)
            event.post(tap: .cghidEventTap)
        }
    }
}

// App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var inputReceiver: InputReceiver?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Remote Keyboard/Mouse Client ===")
        print("Listening for input events on port \(INPUT_PORT)")
        print("")
        
        // Initialize event source early
        _ = getEventSource()
        print("✅ CGEventSource initialized")
        
        // Check accessibility
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

// Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
