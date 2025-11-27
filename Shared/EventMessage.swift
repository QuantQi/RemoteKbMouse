//
//  EventMessage.swift
//  RemoteKbMouse
//
//  Shared protocol for keyboard and mouse events sent between Host and Client.
//

import Foundation

// MARK: - Event Kind

/// The type of input event being transmitted.
public enum EventKind: String, Codable {
    case keyboard
    case mouseMove
    case mouseButton
    case scroll
}

// MARK: - Payloads

/// Payload for keyboard events.
public struct KeyboardPayload: Codable {
    /// The virtual key code (e.g., kVK_ANSI_A = 0x00).
    public let keyCode: UInt16
    /// True if key is pressed down, false if released.
    public let isKeyDown: Bool
    /// CGEventFlags.rawValue for modifiers (Shift, Control, Option, Command, etc.).
    public let flags: UInt64
    
    public init(keyCode: UInt16, isKeyDown: Bool, flags: UInt64) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.flags = flags
    }
}

/// Payload for mouse movement events.
public struct MouseMovePayload: Codable {
    /// Relative movement in X direction.
    public let deltaX: Int64
    /// Relative movement in Y direction.
    public let deltaY: Int64
    /// Absolute X position (used for positioning cursor on client).
    public let absoluteX: Double?
    /// Absolute Y position (used for positioning cursor on client).
    public let absoluteY: Double?
    
    public init(deltaX: Int64, deltaY: Int64, absoluteX: Double?, absoluteY: Double?) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.absoluteX = absoluteX
        self.absoluteY = absoluteY
    }
}

/// Payload for mouse button events.
public struct MouseButtonPayload: Codable {
    /// Button number: 0=left, 1=right, 2=center/other.
    public let button: Int
    /// True if button pressed down, false if released.
    public let isDown: Bool
    /// Number of clicks (for double-click, triple-click, etc.).
    public let clickCount: Int
    /// X position where the click occurred.
    public let x: Double
    /// Y position where the click occurred.
    public let y: Double
    
    public init(button: Int, isDown: Bool, clickCount: Int, x: Double, y: Double) {
        self.button = button
        self.isDown = isDown
        self.clickCount = clickCount
        self.x = x
        self.y = y
    }
}

/// Payload for scroll wheel events.
public struct ScrollPayload: Codable {
    /// Scroll delta in X direction (horizontal scroll).
    public let deltaX: Int32
    /// Scroll delta in Y direction (vertical scroll).
    public let deltaY: Int32
    
    public init(deltaX: Int32, deltaY: Int32) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

// MARK: - Event Message

/// The main message structure sent over the network.
/// Exactly one payload will be non-nil based on the `kind`.
public struct EventMessage: Codable {
    public let kind: EventKind
    public let keyboard: KeyboardPayload?
    public let mouseMove: MouseMovePayload?
    public let mouseButton: MouseButtonPayload?
    public let scroll: ScrollPayload?
    
    public init(kind: EventKind, keyboard: KeyboardPayload?, mouseMove: MouseMovePayload?, mouseButton: MouseButtonPayload?, scroll: ScrollPayload?) {
        self.kind = kind
        self.keyboard = keyboard
        self.mouseMove = mouseMove
        self.mouseButton = mouseButton
        self.scroll = scroll
    }
    
    // MARK: - Convenience Initializers
    
    /// Create a keyboard event message.
    public static func keyboard(keyCode: UInt16, isKeyDown: Bool, flags: UInt64) -> EventMessage {
        return EventMessage(
            kind: .keyboard,
            keyboard: KeyboardPayload(keyCode: keyCode, isKeyDown: isKeyDown, flags: flags),
            mouseMove: nil,
            mouseButton: nil,
            scroll: nil
        )
    }
    
    /// Create a mouse move event message.
    public static func mouseMove(deltaX: Int64, deltaY: Int64, absoluteX: Double? = nil, absoluteY: Double? = nil) -> EventMessage {
        return EventMessage(
            kind: .mouseMove,
            keyboard: nil,
            mouseMove: MouseMovePayload(deltaX: deltaX, deltaY: deltaY, absoluteX: absoluteX, absoluteY: absoluteY),
            mouseButton: nil,
            scroll: nil
        )
    }
    
    /// Create a mouse button event message.
    public static func mouseButton(button: Int, isDown: Bool, clickCount: Int, x: Double, y: Double) -> EventMessage {
        return EventMessage(
            kind: .mouseButton,
            keyboard: nil,
            mouseMove: nil,
            mouseButton: MouseButtonPayload(button: button, isDown: isDown, clickCount: clickCount, x: x, y: y),
            scroll: nil
        )
    }
    
    /// Create a scroll event message.
    public static func scroll(deltaX: Int32, deltaY: Int32) -> EventMessage {
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
public struct MessageFraming {
    
    /// Encode a message with length prefix for network transmission.
    public static func encode(_ message: EventMessage) throws -> Data {
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
    public static func extractLength(from data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }
    }
    
    /// Decode a message from JSON data.
    public static func decode(_ data: Data) throws -> EventMessage {
        let decoder = JSONDecoder()
        return try decoder.decode(EventMessage.self, from: data)
    }
}
