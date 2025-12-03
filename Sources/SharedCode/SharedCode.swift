import Foundation
import CoreGraphics

// The Bonjour service name, like "_myservice._tcp"
public enum NetworkConstants {
    public static let serviceType = "_remotekvm._tcp"
    public static let videoServiceType = "_remotekvmvideo._tcp"  // Separate service for video
}

// MARK: - Edge Detection Configuration

public enum EdgeDetectionConfig {
    /// Inset in points from screen edge to trigger edge crossing
    public static let edgeInset: CGFloat = 6.0
    
    /// Cooldown in seconds before another edge crossing can be triggered
    public static let cooldownSeconds: TimeInterval = 0.25
    
    /// Logging: only log every Nth miss to avoid spam
    public static let logEveryNthMiss: Int = 120
}

// MARK: - Control State

public enum ControlState: String, Codable {
    case local           // Client has control (no remote input being sent)
    case remote          // Remote (server) has control (client sending input to server)
    case pendingRelease  // Server signaled release, waiting for client to acknowledge
}

// MARK: - Remote Input Event (unified keyboard + mouse)

public enum RemoteInputEvent: Codable {
    case keyboard(RemoteKeyboardEvent)
    case mouse(RemoteMouseEvent)
    case gesture(RemoteGestureEvent)       // Magic Mouse gestures
    case screenInfo(ScreenInfoEvent)      // Server tells client its screen size
    case controlRelease                    // Server tells client to release control (edge hit)
    case warpCursor(WarpCursorEvent)       // Client tells server to warp cursor
    case startVideoStream                  // Client requests video stream
    case stopVideoStream                   // Client stops video stream
    case clipboard(ClipboardPayload)       // Clipboard sync
}

// MARK: - Gesture Event (Magic Mouse gestures)

public struct RemoteGestureEvent: Codable {
    public enum Kind: String, Codable {
        case swipe
        case smartZoom
        case missionControlTap
    }
    
    public enum Direction: String, Codable {
        case left
        case right
        case up
        case down
        case none
    }
    
    public enum Phase: String, Codable {
        case began
        case changed
        case ended
        case momentumBegan
        case momentum
        case momentumEnded
        case mayBegin
    }
    
    public let kind: Kind
    public let direction: Direction
    public let deltaX: Double
    public let deltaY: Double
    public let phase: Phase
    public let tapCount: Int
    public let timestamp: Double
    
    public init(kind: Kind,
                direction: Direction = .none,
                deltaX: Double = 0,
                deltaY: Double = 0,
                phase: Phase = .ended,
                tapCount: Int = 0,
                timestamp: Double) {
        self.kind = kind
        self.direction = direction
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.tapCount = tapCount
        self.timestamp = timestamp
    }
}

// MARK: - Video Frame Header (binary protocol, not JSON)
// Format: [4 bytes: frame size][4 bytes: timestamp][1 byte: is keyframe][data...]

public struct VideoFrameHeader {
    public let frameSize: UInt32
    public let timestamp: UInt32      // milliseconds
    public let isKeyframe: Bool
    
    public static let headerSize = 9  // 4 + 4 + 1 bytes
    
    public init(frameSize: UInt32, timestamp: UInt32, isKeyframe: Bool) {
        self.frameSize = frameSize
        self.timestamp = timestamp
        self.isKeyframe = isKeyframe
    }
    
    public func toData() -> Data {
        var data = Data(capacity: Self.headerSize)
        var size = frameSize.bigEndian
        var ts = timestamp.bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(Data(bytes: &ts, count: 4))
        data.append(isKeyframe ? 1 : 0)
        return data
    }
    
    public static func fromData(_ data: Data) -> VideoFrameHeader? {
        guard data.count >= headerSize else { return nil }
        let size = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let ts = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let keyframe = data[8] == 1
        return VideoFrameHeader(frameSize: size, timestamp: ts, isKeyframe: keyframe)
    }
}

// MARK: - Clipboard Payload

public struct ClipboardPayload: Codable {
    public enum Kind: String, Codable {
        case text
    }
    
    public let id: UInt64
    public let kind: Kind
    public let text: String
    public let timestamp: TimeInterval
    
    public static let maxTextBytes = 256 * 1024
    
    public var isValid: Bool {
        kind == .text && text.utf8.count <= Self.maxTextBytes
    }
    
    public init(id: UInt64, kind: Kind, text: String, timestamp: TimeInterval) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Screen Info Event

public struct ScreenInfoEvent: Codable {
    public let width: Double
    public let height: Double
    
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

// MARK: - Warp Cursor Event

public struct WarpCursorEvent: Codable {
    public let x: Double
    public let y: Double
    
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Keyboard Event

public struct RemoteKeyboardEvent: Codable {
    
    public let keyCode: UInt16
    public let eventType: KeyboardEventType
    public let flags: UInt64

    public enum KeyboardEventType: Codable {
        case keyDown
        case keyUp
    }
    
    public init?(event: CGEvent) {
        self.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        self.flags = event.flags.rawValue
        
        if event.type == .keyDown {
            self.eventType = .keyDown
        } else if event.type == .keyUp {
            self.eventType = .keyUp
        } else {
            return nil
        }
    }
    
    public func toCGEvent() -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: self.keyCode, keyDown: eventType == .keyDown) else {
            return nil
        }
        event.flags = CGEventFlags(rawValue: self.flags)
        return event
    }
}

// MARK: - Mouse Event

public struct RemoteMouseEvent: Codable {
    
    public let eventType: MouseEventType
    public let deltaX: Double      // Mouse movement delta X
    public let deltaY: Double      // Mouse movement delta Y
    public let scrollDeltaX: Double // For scroll events
    public let scrollDeltaY: Double // For scroll events
    public let buttonNumber: Int32 // 0 = left, 1 = right, 2 = middle/other
    public let clickState: Int64   // For double/triple click detection
    
    // Scroll phase fields for Magic Mouse gesture support
    public let scrollPhase: Int64       // NSEvent.Phase raw value for gesture phase
    public let momentumPhase: Int64     // NSEvent.Phase raw value for momentum phase
    
    public enum MouseEventType: String, Codable {
        case moved
        case leftDown
        case leftUp
        case leftDragged
        case rightDown
        case rightUp
        case rightDragged
        case otherDown
        case otherUp
        case otherDragged
        case scrollWheel
    }
    
    public init?(event: CGEvent, screenSize: CGSize) {
        // Use delta values for mouse movement (works even with disassociated cursor)
        self.deltaX = Double(event.getIntegerValueField(.mouseEventDeltaX))
        self.deltaY = Double(event.getIntegerValueField(.mouseEventDeltaY))
        
        // Scroll wheel deltas are separate
        self.scrollDeltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        self.scrollDeltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        self.buttonNumber = Int32(event.getIntegerValueField(.mouseEventButtonNumber))
        self.clickState = event.getIntegerValueField(.mouseEventClickState)
        
        // Capture scroll phases for gesture support (Magic Mouse swipes)
        self.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        self.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        
        switch event.type {
        case .mouseMoved:
            self.eventType = .moved
        case .leftMouseDown:
            self.eventType = .leftDown
        case .leftMouseUp:
            self.eventType = .leftUp
        case .leftMouseDragged:
            self.eventType = .leftDragged
        case .rightMouseDown:
            self.eventType = .rightDown
        case .rightMouseUp:
            self.eventType = .rightUp
        case .rightMouseDragged:
            self.eventType = .rightDragged
        case .otherMouseDown:
            self.eventType = .otherDown
        case .otherMouseUp:
            self.eventType = .otherUp
        case .otherMouseDragged:
            self.eventType = .otherDragged
        case .scrollWheel:
            self.eventType = .scrollWheel
        default:
            return nil
        }
    }
    
    public func toCGEvent(screenSize: CGSize) -> CGEvent? {
        // Get current mouse position and apply delta
        let currentLocation = CGEvent(source: nil)?.location ?? CGPoint.zero
        var newX = currentLocation.x + deltaX
        var newY = currentLocation.y + deltaY
        
        // Clamp to screen bounds
        let clampedX = max(0, min(newX, Double(screenSize.width) - 1))
        let clampedY = max(0, min(newY, Double(screenSize.height) - 1))
        
        // // Log if clamping occurred (cursor hit edge)
        // if newX != clampedX || newY != clampedY {
        //     print("[MOUSE] CLAMPED: (\\(String(format: \"%.1f\", newX)), \\(String(format: \"%.1f\", newY))) -> (\\(String(format: \"%.1f\", clampedX)), \\(String(format: \"%.1f\", clampedY))), screen=\\(screenSize)")
        // }
        
        newX = clampedX
        newY = clampedY
        
        let point = CGPoint(x: newX, y: newY)
        
        let cgEventType: CGEventType
        let mouseButton: CGMouseButton
        
        switch eventType {
        case .moved:
            cgEventType = .mouseMoved
            mouseButton = .left
        case .leftDown:
            cgEventType = .leftMouseDown
            mouseButton = .left
        case .leftUp:
            cgEventType = .leftMouseUp
            mouseButton = .left
        case .leftDragged:
            cgEventType = .leftMouseDragged
            mouseButton = .left
        case .rightDown:
            cgEventType = .rightMouseDown
            mouseButton = .right
        case .rightUp:
            cgEventType = .rightMouseUp
            mouseButton = .right
        case .rightDragged:
            cgEventType = .rightMouseDragged
            mouseButton = .right
        case .otherDown:
            cgEventType = .otherMouseDown
            mouseButton = .center
        case .otherUp:
            cgEventType = .otherMouseUp
            mouseButton = .center
        case .otherDragged:
            cgEventType = .otherMouseDragged
            mouseButton = .center
        case .scrollWheel:
            // Scroll events are created differently - use scroll deltas
            guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(scrollDeltaY * 10), wheel2: Int32(scrollDeltaX * 10), wheel3: 0) else {
                return nil
            }
            
            // Set scroll phases for gesture support (Magic Mouse swipes)
            if scrollPhase != 0 {
                scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
            }
            if momentumPhase != 0 {
                scrollEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            }
            
            return scrollEvent
        }
        
        guard let event = CGEvent(mouseEventSource: nil, mouseType: cgEventType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            return nil
        }
        
        // Set delta values in the event (some apps need these)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
        
        // Set click state for double/triple clicks
        if clickState > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        
        return event
    }
}