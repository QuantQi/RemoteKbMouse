//
//  ClientEventInjector.swift
//  RemoteKbMouseClient
//
//  Injects keyboard and mouse events into macOS.
//

import Foundation
import CoreGraphics

/// Injects received events into the local macOS session.
final class ClientEventInjector {
    
    /// Whether to print verbose logs.
    private let verbose: Bool
    
    /// Current cursor position (tracked for relative movement).
    private var cursorPosition: CGPoint
    
    /// Screen bounds for clamping cursor position.
    private var screenBounds: CGRect
    
    /// Initialize the injector.
    init(verbose: Bool = false) {
        self.verbose = verbose
        
        // Get the main display bounds
        self.screenBounds = CGDisplayBounds(CGMainDisplayID())
        
        // Get current cursor position
        if let event = CGEvent(source: nil) {
            self.cursorPosition = event.location
        } else {
            self.cursorPosition = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        }
        
        log("Injector initialized, screen bounds: \(screenBounds)")
    }
    
    /// Inject an event message.
    func inject(_ message: EventMessage) {
        switch message.kind {
        case .keyboard:
            if let payload = message.keyboard {
                injectKeyboardEvent(payload)
            }
            
        case .mouseMove:
            if let payload = message.mouseMove {
                injectMouseMoveEvent(payload)
            }
            
        case .mouseButton:
            if let payload = message.mouseButton {
                injectMouseButtonEvent(payload)
            }
            
        case .scroll:
            if let payload = message.scroll {
                injectScrollEvent(payload)
            }
        }
    }
    
    // MARK: - Keyboard Events
    
    private func injectKeyboardEvent(_ payload: KeyboardPayload) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                   virtualKey: CGKeyCode(payload.keyCode),
                                   keyDown: payload.isKeyDown) else {
            logError("Failed to create keyboard event")
            return
        }
        
        // Set the modifier flags
        event.flags = CGEventFlags(rawValue: payload.flags)
        
        // Post the event at the HID event tap location
        event.post(tap: .cghidEventTap)
        
        if verbose {
            log("Keyboard: keyCode=\(payload.keyCode) down=\(payload.isKeyDown) flags=\(payload.flags)")
        }
    }
    
    // MARK: - Mouse Move Events
    
    private func injectMouseMoveEvent(_ payload: MouseMovePayload) {
        // Use absolute position if available, otherwise apply delta
        if let absX = payload.absoluteX, let absY = payload.absoluteY {
            // Scale the absolute position to the local screen
            // For now, we'll use the absolute position directly
            // In a more sophisticated setup, you'd want to scale based on screen ratios
            cursorPosition = CGPoint(x: absX, y: absY)
        } else {
            // Apply delta movement
            cursorPosition.x += CGFloat(payload.deltaX)
            cursorPosition.y += CGFloat(payload.deltaY)
        }
        
        // Clamp to screen bounds
        cursorPosition.x = max(screenBounds.minX, min(screenBounds.maxX, cursorPosition.x))
        cursorPosition.y = max(screenBounds.minY, min(screenBounds.maxY, cursorPosition.y))
        
        // Create and post the mouse move event
        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: cursorPosition,
                                   mouseButton: .left) else {
            logError("Failed to create mouse move event")
            return
        }
        
        event.post(tap: .cghidEventTap)
        
        if verbose {
            log("MouseMove: delta=(\(payload.deltaX), \(payload.deltaY)) pos=\(cursorPosition)")
        }
    }
    
    // MARK: - Mouse Button Events
    
    private func injectMouseButtonEvent(_ payload: MouseButtonPayload) {
        // Update cursor position from the event
        cursorPosition = CGPoint(x: payload.x, y: payload.y)
        
        // Determine the event type based on button and state
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        
        switch (payload.button, payload.isDown) {
        case (0, true):
            mouseType = .leftMouseDown
            mouseButton = .left
        case (0, false):
            mouseType = .leftMouseUp
            mouseButton = .left
        case (1, true):
            mouseType = .rightMouseDown
            mouseButton = .right
        case (1, false):
            mouseType = .rightMouseUp
            mouseButton = .right
        case (_, true):
            mouseType = .otherMouseDown
            mouseButton = .center
        case (_, false):
            mouseType = .otherMouseUp
            mouseButton = .center
        }
        
        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: mouseType,
                                   mouseCursorPosition: cursorPosition,
                                   mouseButton: mouseButton) else {
            logError("Failed to create mouse button event")
            return
        }
        
        // Set click count for double/triple clicks
        event.setIntegerValueField(.mouseEventClickState, value: Int64(payload.clickCount))
        
        // For other mouse buttons, set the button number
        if payload.button > 1 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(payload.button))
        }
        
        event.post(tap: .cghidEventTap)
        
        if verbose {
            log("MouseButton: button=\(payload.button) down=\(payload.isDown) clicks=\(payload.clickCount) pos=\(cursorPosition)")
        }
    }
    
    // MARK: - Scroll Events
    
    private func injectScrollEvent(_ payload: ScrollPayload) {
        // Create a scroll wheel event using CGEventCreateScrollWheelEvent
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .pixel,
                                   wheelCount: 2,
                                   wheel1: payload.deltaY,
                                   wheel2: payload.deltaX,
                                   wheel3: 0) else {
            logError("Failed to create scroll event")
            return
        }
        
        event.post(tap: .cghidEventTap)
        
        if verbose {
            log("Scroll: delta=(\(payload.deltaX), \(payload.deltaY))")
        }
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        guard verbose else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Inject] \(message)")
    }
    
    private func logError(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Inject] ERROR: \(message)")
    }
}
