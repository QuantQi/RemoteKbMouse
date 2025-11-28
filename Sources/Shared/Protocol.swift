import Foundation
import Network

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
    
    init(type: EventType, x: Double? = nil, y: Double? = nil, deltaX: Double? = nil, deltaY: Double? = nil, button: Int? = nil, keyCode: UInt16? = nil, flags: UInt64? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.keyCode = keyCode
        self.flags = flags
    }
}

let PORT: UInt16 = 9876
let TOGGLE_FLAGS: UInt64 = 0b1101 << 17 // cmd + option + ctrl

func encodeEvent(_ event: InputEvent) -> Data? {
    try? JSONEncoder().encode(event)
}

func decodeEvent(_ data: Data) -> InputEvent? {
    try? JSONDecoder().decode(InputEvent.self, from: data)
}
