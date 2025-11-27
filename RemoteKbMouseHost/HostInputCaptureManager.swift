//
//  HostInputCaptureManager.swift
//  RemoteKbMouseHost
//
//  Captures keyboard and mouse input using CGEvent taps.
//

import Foundation
import CoreGraphics
import Quartz
import Shared

/// Manages the CGEvent tap for capturing keyboard and mouse input.
final class HostInputCaptureManager {
    
    /// The configuration including hotkey settings.
    private let config: HostConfig
    
    /// The state machine for control mode.
    private let stateMachine: HostControlStateMachine
    
    /// The network sender for forwarding events.
    private let networkSender: HostNetworkSender
    
    /// The event tap reference.
    private var eventTap: CFMachPort?
    
    /// Run loop source for the event tap.
    private var runLoopSource: CFRunLoopSource?
    
    /// Track the current mouse position for relative movement calculation.
    private var lastMousePosition: CGPoint = .zero
    
    /// Initialize with dependencies.
    init(config: HostConfig, stateMachine: HostControlStateMachine, networkSender: HostNetworkSender) {
        self.config = config
        self.stateMachine = stateMachine
        self.networkSender = networkSender
        
        // Get initial mouse position
        if let event = CGEvent(source: nil) {
            lastMousePosition = event.location
        }
    }
    
    /// Start capturing input events.
    func start() -> Bool {
        log("Setting up event tap...")
        
        // Event mask for keyboard and mouse events - build incrementally to avoid type-checker issues
        var eventMask: CGEventMask = 0
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.keyUp.rawValue)
        eventMask |= (1 << CGEventType.flagsChanged.rawValue)
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        
        // Create the event tap
        // Using Unmanaged to pass self to the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            log("ERROR: Failed to create event tap!")
            log("Make sure the app has Accessibility and Input Monitoring permissions.")
            log("Go to System Settings → Privacy & Security → Accessibility")
            log("Go to System Settings → Privacy & Security → Input Monitoring")
            return false
        }
        
        eventTap = tap
        
        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)
        
        log("Event tap started successfully")
        return true
    }
    
    /// Stop capturing input events.
    func stop() {
        log("Stopping event tap...")
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        
        log("Event tap stopped")
    }
    
    /// Handle an incoming event (called from the C callback).
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Handle tap disabled events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("Event tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return event
        }
        
        // Check for hotkey
        if isHotkey(type: type, event: event) {
            stateMachine.toggleMode()
            return nil // Swallow the hotkey
        }
        
        // If in local control mode, pass events through unchanged
        if stateMachine.isLocalControl {
            return event
        }
        
        // In remote control mode, forward events and suppress locally
        if let message = createEventMessage(type: type, event: event) {
            networkSender.send(message)
        }
        
        // Return nil to suppress the event locally
        return nil
    }
    
    // MARK: - Private Methods
    
    /// Check if the event matches the configured hotkey.
    private func isHotkey(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Check if key code matches
        guard keyCode == config.hotkeyKeyCode else { return false }
        
        // Check if required modifiers are present
        // We need to mask out other flags and check only the modifier flags we care about
        let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let activeModifiers = flags.intersection(modifierMask)
        
        return activeModifiers == config.hotkeyModifiers
    }
    
    /// Create an EventMessage from a CGEvent.
    private func createEventMessage(type: CGEventType, event: CGEvent) -> EventMessage? {
        switch type {
        case .keyDown:
            return createKeyboardMessage(event: event, isKeyDown: true)
            
        case .keyUp:
            return createKeyboardMessage(event: event, isKeyDown: false)
            
        case .flagsChanged:
            // Handle modifier key changes
            return createFlagsChangedMessage(event: event)
            
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return createMouseMoveMessage(event: event)
            
        case .leftMouseDown:
            return createMouseButtonMessage(event: event, button: 0, isDown: true)
            
        case .leftMouseUp:
            return createMouseButtonMessage(event: event, button: 0, isDown: false)
            
        case .rightMouseDown:
            return createMouseButtonMessage(event: event, button: 1, isDown: true)
            
        case .rightMouseUp:
            return createMouseButtonMessage(event: event, button: 1, isDown: false)
            
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return createMouseButtonMessage(event: event, button: button, isDown: true)
            
        case .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return createMouseButtonMessage(event: event, button: button, isDown: false)
            
        case .scrollWheel:
            return createScrollMessage(event: event)
            
        default:
            return nil
        }
    }
    
    private func createKeyboardMessage(event: CGEvent, isKeyDown: Bool) -> EventMessage {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        return EventMessage.keyboard(keyCode: keyCode, isKeyDown: isKeyDown, flags: flags)
    }
    
    private func createFlagsChangedMessage(event: CGEvent) -> EventMessage? {
        // flagsChanged events indicate modifier key press/release
        // We need to determine which modifier changed and whether it was pressed or released
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Determine if the key is down based on the corresponding flag
        let isKeyDown: Bool
        switch keyCode {
        case 0x38, 0x3C: // Left/Right Shift
            isKeyDown = flags.contains(.maskShift)
        case 0x3B, 0x3E: // Left/Right Control
            isKeyDown = flags.contains(.maskControl)
        case 0x3A, 0x3D: // Left/Right Option
            isKeyDown = flags.contains(.maskAlternate)
        case 0x37, 0x36: // Left/Right Command
            isKeyDown = flags.contains(.maskCommand)
        case 0x39: // Caps Lock
            isKeyDown = flags.contains(.maskAlphaShift)
        case 0x3F: // Fn
            isKeyDown = flags.contains(.maskSecondaryFn)
        default:
            isKeyDown = true
        }
        
        return EventMessage.keyboard(keyCode: keyCode, isKeyDown: isKeyDown, flags: flags.rawValue)
    }
    
    private func createMouseMoveMessage(event: CGEvent) -> EventMessage {
        let currentPosition = event.location
        let deltaX = Int64(event.getIntegerValueField(.mouseEventDeltaX))
        let deltaY = Int64(event.getIntegerValueField(.mouseEventDeltaY))
        
        lastMousePosition = currentPosition
        
        return EventMessage.mouseMove(
            deltaX: deltaX,
            deltaY: deltaY,
            absoluteX: Double(currentPosition.x),
            absoluteY: Double(currentPosition.y)
        )
    }
    
    private func createMouseButtonMessage(event: CGEvent, button: Int, isDown: Bool) -> EventMessage {
        let position = event.location
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        
        return EventMessage.mouseButton(
            button: button,
            isDown: isDown,
            clickCount: clickCount,
            x: Double(position.x),
            y: Double(position.y)
        )
    }
    
    private func createScrollMessage(event: CGEvent) -> EventMessage {
        // Get scroll deltas - use the continuous scroll values for smoother scrolling
        let deltaY = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let deltaX = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        
        return EventMessage.scroll(deltaX: deltaX, deltaY: deltaY)
    }
    
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Input] \(message)")
    }
}

// MARK: - C Callback

/// The C callback function for the CGEvent tap.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    
    let manager = Unmanaged<HostInputCaptureManager>.fromOpaque(refcon).takeUnretainedValue()
    
    if let resultEvent = manager.handleEvent(type: type, event: event) {
        return Unmanaged.passUnretained(resultEvent)
    }
    
    return nil
}
