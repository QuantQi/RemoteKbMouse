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
    
    /// Grace period after warp to avoid immediate edge triggers
    public static let graceAfterWarpSeconds: TimeInterval = 0.5
    
    /// Logging: only log every Nth miss to avoid spam
    public static let logEveryNthMiss: Int = 120
    
    /// Debug logging enabled via environment variable EDGE_DEBUG=1
    public static var isDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["EDGE_DEBUG"] == "1"
    }
}

// MARK: - Display Geometry Helpers

#if canImport(AppKit)
import AppKit

public enum DisplayGeometry {
    /// Find the screen containing a given point (checks both X and Y)
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
    
    /// The leftmost edge of all screens (true global left boundary)
    public static var globalLeftEdge: CGFloat {
        NSScreen.screens.map { $0.frame.minX }.min() ?? 0
    }
    
    /// The rightmost edge of all screens (true global right boundary)
    public static var globalRightEdge: CGFloat {
        NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
    }
    
    /// The topmost edge of all screens
    public static var globalTopEdge: CGFloat {
        NSScreen.screens.map { $0.frame.minY }.min() ?? 0
    }
    
    /// The bottommost edge of all screens
    public static var globalBottomEdge: CGFloat {
        NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    }
    
    /// Get the leftmost screen
    public static var leftmostScreen: NSScreen? {
        NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
    }
    
    /// Get the rightmost screen
    public static var rightmostScreen: NSScreen? {
        NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX }
    }
    
    /// Check if a point is at the true global left edge (not an interior seam)
    public static func isAtGlobalLeftEdge(_ point: CGPoint, inset: CGFloat = EdgeDetectionConfig.edgeInset) -> Bool {
        point.x <= globalLeftEdge + inset
    }
    
    /// Check if a point is at the true global right edge (not an interior seam)
    public static func isAtGlobalRightEdge(_ point: CGPoint, inset: CGFloat = EdgeDetectionConfig.edgeInset) -> Bool {
        point.x >= globalRightEdge - inset
    }
}
#endif

// MARK: - Edge Detector (Reusable State Machine)

/// A stateful edge detector shared by client and server for consistent edge detection behavior
public struct EdgeDetector {
    private var lastPoint: CGPoint = .zero
    private var lastHitTime: CFTimeInterval = 0
    private var lastWarpTime: CFTimeInterval = 0
    
    public init() {}
    
    /// Record a warp event to suppress edge detection briefly
    public mutating func recordWarp(at time: CFTimeInterval) {
        lastWarpTime = time
    }
    
    /// Check if enough time has passed since the last warp to allow edge detection
    public func isGracePeriodOver(now: CFTimeInterval) -> Bool {
        now - lastWarpTime >= EdgeDetectionConfig.graceAfterWarpSeconds
    }
    
    /// Check if enough time has passed since the last edge hit (cooldown)
    public func isCooldownOver(now: CFTimeInterval) -> Bool {
        now - lastHitTime >= EdgeDetectionConfig.cooldownSeconds
    }
    
    /// Check if cursor should enter remote control (client-side, left edge detection)
    /// - Parameters:
    ///   - now: Current time from CACurrentMediaTime()
    ///   - point: Current cursor location
    ///   - deltaX: Mouse movement delta X (negative = moving left)
    ///   - globalLeftEdge: The true leftmost X coordinate of all screens
    /// - Returns: true if remote control should be entered
    public mutating func shouldEnterRemote(now: CFTimeInterval, point: CGPoint, deltaX: Double, globalLeftEdge: CGFloat) -> Bool {
        // Check cooldown
        guard isCooldownOver(now: now) else {
            if EdgeDetectionConfig.isDebugEnabled {
                print("[EdgeDetector] shouldEnterRemote: cooldown not passed")
            }
            return false
        }
        
        // Check grace period after warp
        guard isGracePeriodOver(now: now) else {
            if EdgeDetectionConfig.isDebugEnabled {
                print("[EdgeDetector] shouldEnterRemote: grace period not passed")
            }
            return false
        }
        
        // Check if at global left edge
        guard point.x <= globalLeftEdge + EdgeDetectionConfig.edgeInset else {
            lastPoint = point
            return false
        }
        
        // Check movement direction: moving left (deltaX < 0) or at wall with position < last (for zero-delta case)
        let movingLeft = deltaX < -0.5 || point.x < lastPoint.x || (deltaX == 0 && point.x <= globalLeftEdge)
        
        if movingLeft {
            lastHitTime = now
            if EdgeDetectionConfig.isDebugEnabled {
                print("[EdgeDetector] shouldEnterRemote: LEFT EDGE HIT at x=\(point.x), deltaX=\(deltaX)")
            }
        }
        
        lastPoint = point
        return movingLeft
    }
    
    /// Check if control should be released back to client (server-side, right edge detection)
    /// - Parameters:
    ///   - now: Current time from CACurrentMediaTime()
    ///   - point: Current cursor location (use the posted position, not re-read)
    ///   - displayMaxX: The right edge of the active display
    /// - Returns: true if control should be released
    public mutating func shouldRelease(now: CFTimeInterval, point: CGPoint, displayMaxX: CGFloat) -> Bool {
        // Check cooldown
        guard isCooldownOver(now: now) else {
            if EdgeDetectionConfig.isDebugEnabled {
                print("[EdgeDetector] shouldRelease: cooldown not passed")
            }
            return false
        }
        
        // Check grace period after warp
        guard isGracePeriodOver(now: now) else {
            if EdgeDetectionConfig.isDebugEnabled {
                print("[EdgeDetector] shouldRelease: grace period not passed")
            }
            return false
        }
        
        // Check if at right edge
        guard point.x >= displayMaxX - EdgeDetectionConfig.edgeInset else {
            return false
        }
        
        lastHitTime = now
        if EdgeDetectionConfig.isDebugEnabled {
            print("[EdgeDetector] shouldRelease: RIGHT EDGE HIT at x=\(point.x), maxX=\(displayMaxX)")
        }
        return true
    }
    
    /// Reset the detector state (e.g., on disconnect)
    public mutating func reset() {
        lastPoint = .zero
        lastHitTime = 0
        lastWarpTime = 0
    }
}

// MARK: - Control State

public enum ControlState: String, Codable {
    case local           // Client has control (no remote input being sent)
    case remote          // Remote (server) has control (client sending input to server)
    case pendingRelease  // Server signaled release, waiting for client to acknowledge
}

// MARK: - Display Mode & Capability

/// Represents the desired display mode from client
public struct DesiredDisplayMode: Codable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public let refreshRate: Int?  // Optional refresh rate in Hz
    
    public init(width: Int, height: Int, scale: Double = 2.0, refreshRate: Int? = 60) {
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
    }
}

/// Server response confirming virtual display setup
public struct VirtualDisplayReady: Codable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public let displayID: UInt32
    public let isVirtual: Bool  // true if virtual display, false if fallback to mirror
    
    public init(width: Int, height: Int, scale: Double, displayID: UInt32, isVirtual: Bool) {
        self.width = width
        self.height = height
        self.scale = scale
        self.displayID = displayID
        self.isVirtual = isVirtual
    }
}

/// Server capability flags
public struct ServerCapabilities: Codable {
    public let supportsVirtualDisplay: Bool
    public let macOSVersion: String
    
    public init(supportsVirtualDisplay: Bool, macOSVersion: String) {
        self.supportsVirtualDisplay = supportsVirtualDisplay
        self.macOSVersion = macOSVersion
    }
    
    /// Check if current system supports virtual displays (macOS 14+)
    public static func current() -> ServerCapabilities {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let supportsVirtual = version.majorVersion >= 14
        return ServerCapabilities(supportsVirtualDisplay: supportsVirtual, macOSVersion: versionString)
    }
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
    case clientDesiredDisplayMode(DesiredDisplayMode)  // Client sends desired display mode
    case virtualDisplayReady(VirtualDisplayReady)      // Server confirms virtual display ready
    case serverCapabilities(ServerCapabilities)        // Server sends capabilities on connect
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
    public let isVirtual: Bool       // true if reporting virtual display mode
    public let displayID: UInt32?    // Display ID if virtual
    
    public init(width: Double, height: Double, isVirtual: Bool = false, displayID: UInt32? = nil) {
        self.width = width
        self.height = height
        self.isVirtual = isVirtual
        self.displayID = displayID
    }
}

// MARK: - Display Frame (for mouse clamping)

/// Represents a display frame with origin and size
public struct DisplayFrame {
    public let origin: CGPoint
    public let size: CGSize
    
    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }
    
    public init(rect: CGRect) {
        self.origin = rect.origin
        self.size = rect.size
    }
    
    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    
    /// Clamp a point to within this display frame
    public func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(minX, min(point.x, maxX - 1)),
            y: max(minY, min(point.y, maxY - 1))
        )
    }
    
    /// Check if point is at or past the right edge (for edge release detection)
    public func isAtRightEdge(_ x: CGFloat, inset: CGFloat = EdgeDetectionConfig.edgeInset) -> Bool {
        x >= maxX - inset
    }
    
    /// Check if point is at or past the left edge
    public func isAtLeftEdge(_ x: CGFloat, inset: CGFloat = EdgeDetectionConfig.edgeInset) -> Bool {
        x <= minX + inset
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
        return toCGEvent(displayFrame: DisplayFrame(origin: .zero, size: screenSize))
    }
    
    /// Convert to CGEvent with explicit display frame (supports non-zero origin for virtual displays)
    public func toCGEvent(displayFrame: DisplayFrame) -> CGEvent? {
        // Get current mouse position and apply delta
        let currentLocation = CGEvent(source: nil)?.location ?? CGPoint.zero
        let newX = currentLocation.x + deltaX
        let newY = currentLocation.y + deltaY
        
        // Clamp to display frame bounds (handles non-zero origin)
        let clampedPoint = displayFrame.clamp(CGPoint(x: newX, y: newY))
        
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
        
        guard let event = CGEvent(mouseEventSource: nil, mouseType: cgEventType, mouseCursorPosition: clampedPoint, mouseButton: mouseButton) else {
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