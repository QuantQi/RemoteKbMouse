//
//  HostConfig.swift
//  RemoteKbMouseHost
//
//  Configuration for the Host command-line tool.
//

import Foundation
import CoreGraphics

/// Configuration parsed from command-line arguments.
struct HostConfig {
    /// IP address or hostname of the client.
    let clientHost: String
    /// TCP port to connect to on the client.
    let port: UInt16
    /// The key code for the hotkey (e.g., kVK_ANSI_H = 0x04).
    let hotkeyKeyCode: UInt16
    /// Required modifier flags for the hotkey.
    let hotkeyModifiers: CGEventFlags
    
    /// Default port for the connection.
    static let defaultPort: UInt16 = 50505
    
    /// Default hotkey: Control + Option + Command + H
    static let defaultHotkeyKeyCode: UInt16 = 0x04 // kVK_ANSI_H
    static let defaultHotkeyModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    
    /// Parse configuration from command-line arguments.
    static func parse(from arguments: [String]) -> HostConfig? {
        var clientHost: String?
        var port: UInt16 = defaultPort
        var hotkeyKeyCode: UInt16 = defaultHotkeyKeyCode
        var hotkeyModifiers: CGEventFlags = defaultHotkeyModifiers
        
        var i = 1 // Skip program name
        while i < arguments.count {
            let arg = arguments[i]
            
            switch arg {
            case "--client-ip", "-c":
                guard i + 1 < arguments.count else {
                    printUsage()
                    return nil
                }
                clientHost = arguments[i + 1]
                i += 2
                
            case "--port", "-p":
                guard i + 1 < arguments.count,
                      let parsedPort = UInt16(arguments[i + 1]) else {
                    printUsage()
                    return nil
                }
                port = parsedPort
                i += 2
                
            case "--hotkey", "-k":
                guard i + 1 < arguments.count else {
                    printUsage()
                    return nil
                }
                if let parsed = parseHotkey(arguments[i + 1]) {
                    hotkeyKeyCode = parsed.keyCode
                    hotkeyModifiers = parsed.modifiers
                } else {
                    print("Warning: Invalid hotkey format, using default (Ctrl+Opt+Cmd+H)")
                }
                i += 2
                
            case "--help", "-h":
                printUsage()
                return nil
                
            default:
                print("Unknown argument: \(arg)")
                printUsage()
                return nil
            }
        }
        
        guard let host = clientHost else {
            print("Error: --client-ip is required")
            printUsage()
            return nil
        }
        
        return HostConfig(
            clientHost: host,
            port: port,
            hotkeyKeyCode: hotkeyKeyCode,
            hotkeyModifiers: hotkeyModifiers
        )
    }
    
    /// Parse a hotkey string like "ctrl+opt+cmd+h".
    private static func parseHotkey(_ string: String) -> (keyCode: UInt16, modifiers: CGEventFlags)? {
        let parts = string.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }
        
        var modifiers: CGEventFlags = []
        var keyCode: UInt16?
        
        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers.insert(.maskControl)
            case "opt", "option", "alt":
                modifiers.insert(.maskAlternate)
            case "cmd", "command":
                modifiers.insert(.maskCommand)
            case "shift":
                modifiers.insert(.maskShift)
            default:
                // Assume it's the key
                if let code = keyCodeFromString(part) {
                    keyCode = code
                }
            }
        }
        
        guard let code = keyCode else { return nil }
        return (code, modifiers)
    }
    
    /// Map a key name to its virtual key code.
    private static func keyCodeFromString(_ key: String) -> UInt16? {
        // Common keys mapping (macOS virtual key codes)
        let keyMap: [String: UInt16] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
            "z": 0x06,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
            "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
            "space": 0x31, "return": 0x24, "escape": 0x35, "esc": 0x35,
            "tab": 0x30, "delete": 0x33, "backspace": 0x33,
            "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
        ]
        return keyMap[key]
    }
    
    private static func printUsage() {
        let usage = """
        RemoteKbMouseHost - Capture and forward keyboard/mouse events to a remote Mac
        
        USAGE:
            RemoteKbMouseHost --client-ip <IP> [OPTIONS]
        
        REQUIRED:
            --client-ip, -c <IP>    IP address or hostname of the client Mac
        
        OPTIONS:
            --port, -p <PORT>       TCP port to connect to (default: 50505)
            --hotkey, -k <COMBO>    Key combination to toggle remote control
                                    Format: modifier+modifier+key
                                    Example: ctrl+opt+cmd+h (default)
                                    Modifiers: ctrl, opt/alt, cmd, shift
            --help, -h              Show this help message
        
        EXAMPLES:
            RemoteKbMouseHost --client-ip 192.168.1.50
            RemoteKbMouseHost --client-ip 192.168.1.50 --port 50505 --hotkey ctrl+opt+cmd+h
        
        PERMISSIONS REQUIRED:
            - Input Monitoring (System Settings → Privacy & Security → Input Monitoring)
            - Accessibility (System Settings → Privacy & Security → Accessibility)
        """
        print(usage)
    }
    
    /// Human-readable description of the hotkey.
    var hotkeyDescription: String {
        var parts: [String] = []
        if hotkeyModifiers.contains(.maskControl) { parts.append("Ctrl") }
        if hotkeyModifiers.contains(.maskAlternate) { parts.append("Opt") }
        if hotkeyModifiers.contains(.maskCommand) { parts.append("Cmd") }
        if hotkeyModifiers.contains(.maskShift) { parts.append("Shift") }
        parts.append(keyNameFromCode(hotkeyKeyCode))
        return parts.joined(separator: "+")
    }
    
    private func keyNameFromCode(_ code: UInt16) -> String {
        let codeMap: [UInt16: String] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E",
            0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
            0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O",
            0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
            0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y",
            0x06: "Z"
        ]
        return codeMap[code] ?? "Key(\(code))"
    }
}
