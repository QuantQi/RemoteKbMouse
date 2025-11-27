//
//  HostControlStateMachine.swift
//  RemoteKbMouseHost
//
//  Manages the control mode state (local vs remote).
//

import Foundation

/// The control mode determines where input events are directed.
enum ControlMode: String {
    case localControl = "LOCAL"
    case remoteControl = "REMOTE"
}

/// Protocol for receiving control mode change notifications.
protocol ControlModeDelegate: AnyObject {
    func controlModeDidChange(to mode: ControlMode)
}

/// Manages the state machine for switching between local and remote control.
final class HostControlStateMachine {
    
    /// Current control mode.
    private(set) var currentMode: ControlMode = .localControl
    
    /// Delegate to notify of mode changes.
    weak var delegate: ControlModeDelegate?
    
    /// Closure called when mode changes (alternative to delegate).
    var onModeChange: ((ControlMode) -> Void)?
    
    /// Initialize with local control as the default mode.
    init() {
        log("Initial mode: \(currentMode.rawValue) control")
    }
    
    /// Toggle between local and remote control modes.
    func toggleMode() {
        switch currentMode {
        case .localControl:
            currentMode = .remoteControl
        case .remoteControl:
            currentMode = .localControl
        }
        
        log("Switched to \(currentMode.rawValue) control")
        
        delegate?.controlModeDidChange(to: currentMode)
        onModeChange?(currentMode)
    }
    
    /// Check if currently in remote control mode.
    var isRemoteControl: Bool {
        return currentMode == .remoteControl
    }
    
    /// Check if currently in local control mode.
    var isLocalControl: Bool {
        return currentMode == .localControl
    }
    
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Mode] \(message)")
    }
}
