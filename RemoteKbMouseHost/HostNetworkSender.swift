//
//  HostNetworkSender.swift
//  RemoteKbMouseHost
//
//  Manages the network connection to the client and sends events.
//

import Foundation
import Network
import Shared

/// Handles the TCP connection to the client and sends event messages.
final class HostNetworkSender {
    
    /// Connection to the client.
    private var connection: NWConnection?
    
    /// The client host address.
    private let clientHost: String
    
    /// The client port.
    private let port: UInt16
    
    /// Queue for network operations.
    private let queue = DispatchQueue(label: "com.remotekbmouse.host.network")
    
    /// Whether we're currently connected.
    private(set) var isConnected: Bool = false
    
    /// Closure called when connection state changes.
    var onConnectionStateChange: ((Bool) -> Void)?
    
    /// Initialize with client address and port.
    init(clientHost: String, port: UInt16) {
        self.clientHost = clientHost
        self.port = port
    }
    
    /// Start connecting to the client.
    func connect() {
        log("Connecting to \(clientHost):\(port)...")
        
        let host = NWEndpoint.Host(clientHost)
        let port = NWEndpoint.Port(rawValue: self.port)!
        
        // Create TCP connection with keep-alive
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        connection = NWConnection(host: host, port: port, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }
        
        connection?.start(queue: queue)
    }
    
    /// Disconnect from the client.
    func disconnect() {
        log("Disconnecting...")
        connection?.cancel()
        connection = nil
        isConnected = false
    }
    
    /// Send an event message to the client.
    func send(_ message: EventMessage) {
        guard isConnected, let connection = connection else {
            // Silently drop if not connected
            return
        }
        
        do {
            let framedData = try MessageFraming.encode(message)
            
            connection.send(content: framedData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.log("Send error: \(error.localizedDescription)")
                    self?.handleDisconnection()
                }
            })
        } catch {
            log("Failed to encode message: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
            log("Connected to client at \(clientHost):\(port)")
            onConnectionStateChange?(true)
            
        case .failed(let error):
            isConnected = false
            log("Connection failed: \(error.localizedDescription)")
            onConnectionStateChange?(false)
            scheduleReconnect()
            
        case .cancelled:
            isConnected = false
            log("Connection cancelled")
            onConnectionStateChange?(false)
            
        case .waiting(let error):
            log("Waiting for connection: \(error.localizedDescription)")
            
        case .preparing:
            log("Preparing connection...")
            
        case .setup:
            break
            
        @unknown default:
            break
        }
    }
    
    private func handleDisconnection() {
        guard isConnected else { return }
        isConnected = false
        onConnectionStateChange?(false)
        scheduleReconnect()
    }
    
    private func scheduleReconnect() {
        log("Will attempt to reconnect in 3 seconds...")
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.connect()
        }
    }
    
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Network] \(message)")
    }
}
