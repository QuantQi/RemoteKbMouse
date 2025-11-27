//
//  ClientConfig.swift
//  RemoteKbMouseClient
//
//  Configuration for the Client command-line tool.
//

import Foundation

/// Configuration parsed from command-line arguments.
struct ClientConfig {
    /// TCP port to listen on.
    let port: UInt16
    /// Whether to print verbose debug logs.
    let verbose: Bool
    
    /// Default port for the listener.
    static let defaultPort: UInt16 = 50505
    
    /// Parse configuration from command-line arguments.
    static func parse(from arguments: [String]) -> ClientConfig? {
        var port: UInt16 = defaultPort
        var verbose = false
        
        var i = 1 // Skip program name
        while i < arguments.count {
            let arg = arguments[i]
            
            switch arg {
            case "--port", "-p":
                guard i + 1 < arguments.count,
                      let parsedPort = UInt16(arguments[i + 1]) else {
                    printUsage()
                    return nil
                }
                port = parsedPort
                i += 2
                
            case "--verbose", "-v":
                verbose = true
                i += 1
                
            case "--help", "-h":
                printUsage()
                return nil
                
            default:
                print("Unknown argument: \(arg)")
                printUsage()
                return nil
            }
        }
        
        return ClientConfig(port: port, verbose: verbose)
    }
    
    private static func printUsage() {
        let usage = """
        RemoteKbMouseClient - Receive and inject keyboard/mouse events from a remote Mac
        
        USAGE:
            RemoteKbMouseClient [OPTIONS]
        
        OPTIONS:
            --port, -p <PORT>       TCP port to listen on (default: 50505)
            --verbose, -v           Print verbose debug logs for each event
            --help, -h              Show this help message
        
        EXAMPLES:
            RemoteKbMouseClient
            RemoteKbMouseClient --port 50505
            RemoteKbMouseClient --port 50505 --verbose
        
        PERMISSIONS REQUIRED:
            - Accessibility (System Settings → Privacy & Security → Accessibility)
        """
        print(usage)
    }
}
