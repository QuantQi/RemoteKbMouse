import Foundation
import CoreGraphics

// The Bonjour service name, like "_myservice._tcp"
public enum NetworkConstants {
    public static let serviceType = "_remotekvm._tcp"
}

// A Codable struct to send event data over the network
public struct RemoteKeyboardEvent: Codable {
    
    // Using raw values to be Codable
    public let keyCode: UInt16
    public let eventType: EventType
    public let flags: UInt64

    // A simpler, Codable version of CGEventType
    public enum EventType: Codable {
        case keyDown
        case keyUp
    }
    
    // Convenience initializer from a real CGEvent
    public init?(event: CGEvent) {
        self.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        self.flags = event.flags.rawValue
        
        if event.type == .keyDown {
            self.eventType = .keyDown
        } else if event.type == .keyUp {
            self.eventType = .keyUp
        } else {
            // Not a keyboard event we can handle
            return nil
        }
    }
    
    // Method to create a new CGEvent from this struct's data
    public func toCGEvent() -> CGEvent? {
        let type: CGEventType
        switch self.eventType {
        case .keyDown:
            type = .keyDown
        case .keyUp:
            type = .keyUp
        }
        
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: self.keyCode, keyDown: type == .keyDown) else {
            return nil
        }
        
        event.flags = CGEventFlags(rawValue: self.flags)
        
        return event
    }
}