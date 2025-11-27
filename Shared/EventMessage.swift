//
//  EventMessage.swift
//  RemoteKbMouse
//
//  Shared protocol for keyboard and mouse events sent between Host and Client.
//

import Foundation

// MARK: - Event Kind

/// The type of input event being transmitted.
enum EventKind: String, Codable {
    case keyboard
    case mouseMove
    case mouseButton
    case scroll
}

// MARK: - Payloads

/// Payload for keyboard events.
struct KeyboardPayload: Codable {
    /// The virtual key code (e.g., kVK_ANSI_A = 0x00).
    let keyCode: UInt16
    /// True if key is pressed down, false if released.
    let isKeyDown: Bool
    /// CGEventFlags.rawValue for modifiers (Shift, Control, Option, Command, etc.).
    let flags: UInt64
}

/// Payload for mouse movement events.
struct MouseMovePayload: Codable {
    /// Relative movement in X direction.
    let deltaX: Int64
    /// Relative movement in Y direction.
    let deltaY: Int64
    /// Absolute X position (used for positioning cursor on client).
    let absoluteX: Double?
    /// Absolute Y position (used for positioning cursor on client).
    let absoluteY: Double?
}

/// Payload for mouse button events.
struct MouseButtonPayload: Codable {
    /// Button number: 0=left, 1=right, 2=center/other.
    let button: Int
    /// True if button pressed down, false if released.
    let isDown: Bool
    /// Number of clicks (for double-click, triple-click, etc.).
    let clickCount: Int
    /// X position where the click occurred.
    let x: Double
    /// Y position where the click occurred.
    let y: Double
}

/// Payload for scroll wheel events.
struct ScrollPayload: Codable {
    /// Scroll delta in X direction (horizontal scroll).
    let deltaX: Int32
    /// Scroll delta in Y direction (vertical scroll).
    let deltaY: Int32
}

// MARK: - Event Message

/// The main message structure sent over the network.
/// Exactly one payload will be non-nil based on the `kind`.
struct EventMessage: Codable {
    let kind: EventKind
    let keyboard: KeyboardPayload?
    let mouseMove: MouseMovePayload?
    let mouseButton: MouseButtonPayload?
    let scroll: ScrollPayload?
    
    // MARK: - Convenience Initializers
    
    /// Create a keyboard event message.
    static func keyboard(keyCode: UInt16, isKeyDown: Bool, flags: UInt64) -> EventMessage {
        return EventMessage(
            kind: .keyboard,
            keyboard: KeyboardPayload(keyCode: keyCode, isKeyDown: isKeyDown, flags: flags),
            mouseMove: nil,
            mouseButton: nil,
            scroll: nil
        )
    }
    
    /// Create a mouse move event message.
    static func mouseMove(deltaX: Int64, deltaY: Int64, absoluteX: Double? = nil, absoluteY: Double? = nil) -> EventMessage {
        return EventMessage(
            kind: .mouseMove,
            keyboard: nil,
            mouseMove: MouseMovePayload(deltaX: deltaX, deltaY: deltaY, absoluteX: absoluteX, absoluteY: absoluteY),
            mouseButton: nil,
            scroll: nil
        )
    }
    
    /// Create a mouse button event message.
    static func mouseButton(button: Int, isDown: Bool, clickCount: Int, x: Double, y: Double) -> EventMessage {
        return EventMessage(
            kind: .mouseButton,
            keyboard: nil,
            mouseMove: nil,
            mouseButton: MouseButtonPayload(button: button, isDown: isDown, clickCount: clickCount, x: x, y: y),
            scroll: nil
        )
    }
    
    /// Create a scroll event message.
    static func scroll(deltaX: Int32, deltaY: Int32) -> EventMessage {
        return EventMessage(
            kind: .scroll,
            keyboard: nil,
            mouseMove: nil,
            mouseButton: nil,
            scroll: ScrollPayload(deltaX: deltaX, deltaY: deltaY)
        )
    }
}

// MARK: - Network Protocol Helpers

/// Helper for length-prefixed message framing.
/// Format: [4-byte big-endian length][JSON data]
struct MessageFraming {
    
    /// Encode a message with length prefix for network transmission.
    static func encode(_ message: EventMessage) throws -> Data {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(message)
        
        var lengthData = Data(count: 4)
        let length = UInt32(jsonData.count).bigEndian
        lengthData.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: length, as: UInt32.self)
        }
        
        return lengthData + jsonData
    }
    
    /// Extract the length from a 4-byte header.
    static func extractLength(from data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }
    }
    
    /// Decode a message from JSON data.
    static func decode(_ data: Data) throws -> EventMessage {
        let decoder = JSONDecoder()
        return try decoder.decode(EventMessage.self, from: data)
    }
}
