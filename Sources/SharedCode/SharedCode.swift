import Foundation
import CoreGraphics

// The Bonjour service name, like "_myservice._tcp"
public enum NetworkConstants {
    public static let serviceType = "_remotekvm._tcp"
}

// MARK: - Remote Input Event (unified keyboard + mouse)

public enum RemoteInputEvent: Codable {
    case keyboard(RemoteKeyboardEvent)
    case mouse(RemoteMouseEvent)
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
    public let x: Double           // Normalized 0.0 - 1.0 (percentage of screen)
    public let y: Double           // Normalized 0.0 - 1.0 (percentage of screen)
    public let deltaX: Double      // For scroll events
    public let deltaY: Double      // For scroll events
    public let buttonNumber: Int32 // 0 = left, 1 = right, 2 = middle/other
    public let clickState: Int64   // For double/triple click detection
    
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
        let location = event.location
        
        // Normalize coordinates to 0.0 - 1.0 range
        self.x = Double(location.x / screenSize.width)
        self.y = Double(location.y / screenSize.height)
        
        self.deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        self.deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        self.buttonNumber = Int32(event.getIntegerValueField(.mouseEventButtonNumber))
        self.clickState = event.getIntegerValueField(.mouseEventClickState)
        
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
        // Convert normalized coordinates back to screen coordinates
        let absoluteX = x * Double(screenSize.width)
        let absoluteY = y * Double(screenSize.height)
        let point = CGPoint(x: absoluteX, y: absoluteY)
        
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
            // Scroll events are created differently
            guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 10), wheel2: Int32(deltaX * 10), wheel3: 0) else {
                return nil
            }
            return scrollEvent
        }
        
        guard let event = CGEvent(mouseEventSource: nil, mouseType: cgEventType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            return nil
        }
        
        // Set click state for double/triple clicks
        if clickState > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        
        return event
    }
}