//
//  main.swift
//  RemoteKbMouseHost
//
//  Host command-line tool that captures keyboard/mouse input
//  and forwards it to a remote client Mac.
//

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Signal Handling

/// Global flag for clean shutdown.
var shouldTerminate = false

/// References for cleanup.
var inputManager: HostInputCaptureManager?
var networkSender: HostNetworkSender?

/// Signal handler for SIGINT (Ctrl+C).
func signalHandler(signal: Int32) {
    print("\n")
    log("Received termination signal, shutting down...")
    shouldTerminate = true
    
    // Clean up
    inputManager?.stop()
    networkSender?.disconnect()
    
    // Exit the run loop
    CFRunLoopStop(CFRunLoopGetMain())
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] [Host] \(message)")
}

// MARK: - Permission Check

/// Check if we have the required accessibility permissions.
func checkAccessibilityPermissions() -> Bool {
    // This will prompt the user if permissions haven't been granted
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

// MARK: - Main

func main() {
    // Print banner
    print("""
    ╔══════════════════════════════════════════════════════════╗
    ║              RemoteKbMouseHost v1.0                       ║
    ║     Keyboard/Mouse Sharing Host for macOS                ║
    ╚══════════════════════════════════════════════════════════╝
    """)
    
    // Parse command-line arguments
    guard let config = HostConfig.parse(from: CommandLine.arguments) else {
        exit(1)
    }
    
    // Print configuration summary
    log("Configuration:")
    print("  Client: \(config.clientHost):\(config.port)")
    print("  Hotkey: \(config.hotkeyDescription)")
    print("")
    
    // Check permissions
    log("Checking permissions...")
    if !checkAccessibilityPermissions() {
        log("WARNING: Accessibility permissions not granted!")
        log("Please grant permissions in System Settings → Privacy & Security → Accessibility")
        log("Then restart this application.")
        print("")
        log("Waiting for permissions (you can grant them now and the app will continue)...")
        
        // Wait for permissions in a loop
        var attempts = 0
        while !AXIsProcessTrusted() && attempts < 60 {
            Thread.sleep(forTimeInterval: 1.0)
            attempts += 1
        }
        
        if !AXIsProcessTrusted() {
            log("ERROR: Timed out waiting for permissions. Exiting.")
            exit(1)
        }
        
        log("Permissions granted!")
    } else {
        log("Accessibility permissions OK")
    }
    
    // Set up signal handler for clean shutdown
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    
    // Create components
    let stateMachine = HostControlStateMachine()
    
    networkSender = HostNetworkSender(clientHost: config.clientHost, port: config.port)
    guard let sender = networkSender else {
        log("ERROR: Failed to create network sender")
        exit(1)
    }
    
    // Set up connection state change handler
    sender.onConnectionStateChange = { connected in
        if connected {
            log("Ready to forward events when in REMOTE mode")
        } else {
            log("Client disconnected - events will be dropped until reconnected")
        }
    }
    
    // Connect to client
    sender.connect()
    
    // Create input capture manager
    inputManager = HostInputCaptureManager(
        config: config,
        stateMachine: stateMachine,
        networkSender: sender
    )
    
    guard let manager = inputManager else {
        log("ERROR: Failed to create input capture manager")
        exit(1)
    }
    
    // Start capturing input
    if !manager.start() {
        log("ERROR: Failed to start input capture")
        log("Make sure you have granted Input Monitoring and Accessibility permissions")
        exit(1)
    }
    
    print("")
    log("Host is running!")
    log("Press \(config.hotkeyDescription) to toggle between LOCAL and REMOTE control")
    log("Press Ctrl+C to exit")
    print("")
    
    // Run the main run loop
    RunLoop.main.run()
    
    // Cleanup (reached after run loop is stopped)
    log("Shutting down...")
    manager.stop()
    sender.disconnect()
    log("Goodbye!")
}

// Entry point
main()
