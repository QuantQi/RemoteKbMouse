//
//  main.swift
//  RemoteKbMouseClient
//
//  Client command-line tool that receives keyboard/mouse events
//  from the Host and injects them locally.
//

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Signal Handling

/// Global flag for clean shutdown.
var shouldTerminate = false

/// References for cleanup.
var networkListener: ClientNetworkListener?

/// Signal handler for SIGINT (Ctrl+C).
func signalHandler(signal: Int32) {
    print("\n")
    log("Received termination signal, shutting down...")
    shouldTerminate = true
    
    // Clean up
    networkListener?.stop()
    
    // Exit the run loop
    CFRunLoopStop(CFRunLoopGetMain())
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] [Client] \(message)")
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
    ║              RemoteKbMouseClient v1.0                     ║
    ║     Keyboard/Mouse Sharing Client for macOS              ║
    ╚══════════════════════════════════════════════════════════╝
    """)
    
    // Parse command-line arguments
    guard let config = ClientConfig.parse(from: CommandLine.arguments) else {
        exit(1)
    }
    
    // Print configuration summary
    log("Configuration:")
    print("  Port: \(config.port)")
    print("  Verbose: \(config.verbose)")
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
    
    // Create the event injector
    let injector = ClientEventInjector(verbose: config.verbose)
    
    // Create and start the network listener
    networkListener = ClientNetworkListener(port: config.port, injector: injector)
    
    guard let listener = networkListener else {
        log("ERROR: Failed to create network listener")
        exit(1)
    }
    
    if !listener.start() {
        log("ERROR: Failed to start network listener")
        exit(1)
    }
    
    print("")
    log("Client is running!")
    log("Waiting for Host to connect on port \(config.port)...")
    log("Press Ctrl+C to exit")
    print("")
    
    // Run the main run loop
    RunLoop.main.run()
    
    // Cleanup (reached after run loop is stopped)
    log("Shutting down...")
    listener.stop()
    log("Goodbye!")
}

// Entry point
main()
