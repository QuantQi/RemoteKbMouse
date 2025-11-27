//
//  ClientNetworkListener.swift
//  RemoteKbMouseClient
//
//  Listens for incoming connections and receives events from the Host.
//

import Foundation
import Network

/// Listens for incoming connections from the Host and receives event messages.
final class ClientNetworkListener {
    
    /// The network listener.
    private var listener: NWListener?
    
    /// The current connection from the Host.
    private var connection: NWConnection?
    
    /// The port to listen on.
    private let port: UInt16
    
    /// Queue for network operations.
    private let queue = DispatchQueue(label: "com.remotekbmouse.client.network")
    
    /// The event injector to forward received events to.
    private let injector: ClientEventInjector
    
    /// Buffer for incomplete message data.
    private var receiveBuffer = Data()
    
    /// Initialize with port and injector.
    init(port: UInt16, injector: ClientEventInjector) {
        self.port = port
        self.injector = injector
    }
    
    /// Start listening for connections.
    func start() -> Bool {
        log("Starting listener on port \(port)...")
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            log("ERROR: Failed to create listener: \(error.localizedDescription)")
            return false
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        
        listener?.newConnectionHandler = { [weak self] newConnection in
            self?.handleNewConnection(newConnection)
        }
        
        listener?.start(queue: queue)
        
        return true
    }
    
    /// Stop the listener and close any connections.
    func stop() {
        log("Stopping listener...")
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }
    
    // MARK: - Connection Handling
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                log("Listening on port \(port.rawValue)")
            }
            
        case .failed(let error):
            log("Listener failed: \(error.localizedDescription)")
            
        case .cancelled:
            log("Listener cancelled")
            
        case .waiting(let error):
            log("Listener waiting: \(error.localizedDescription)")
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ newConnection: NWConnection) {
        // If we already have a connection, close it
        if let existing = connection {
            log("Closing existing connection for new one")
            existing.cancel()
        }
        
        connection = newConnection
        receiveBuffer = Data()
        
        // Get the remote endpoint info
        var remoteAddress = "unknown"
        if case .hostPort(let host, _) = newConnection.endpoint {
            remoteAddress = "\(host)"
        }
        
        log("Host connected from \(remoteAddress)")
        
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        
        newConnection.start(queue: queue)
        
        // Start receiving data
        startReceiving()
    }
    
    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            log("Connection ready")
            
        case .failed(let error):
            log("Connection failed: \(error.localizedDescription)")
            connection = nil
            
        case .cancelled:
            log("Connection closed")
            connection = nil
            
        case .waiting(let error):
            log("Connection waiting: \(error.localizedDescription)")
            
        default:
            break
        }
    }
    
    // MARK: - Receiving Data
    
    private func startReceiving() {
        guard let connection = connection else { return }
        
        // Receive data continuously
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let error = error {
                self?.log("Receive error: \(error.localizedDescription)")
                return
            }
            
            if let data = content {
                self?.processReceivedData(data)
            }
            
            if isComplete {
                self?.log("Connection completed")
                return
            }
            
            // Continue receiving
            self?.startReceiving()
        }
    }
    
    private func processReceivedData(_ data: Data) {
        receiveBuffer.append(data)
        
        // Process complete messages from the buffer
        while receiveBuffer.count >= 4 {
            // Read the length prefix
            guard let length = MessageFraming.extractLength(from: receiveBuffer) else {
                break
            }
            
            let totalLength = 4 + Int(length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalLength else {
                break
            }
            
            // Extract the message data (skip the 4-byte length prefix)
            let messageData = receiveBuffer.subdata(in: 4..<totalLength)
            
            // Remove the processed data from the buffer
            receiveBuffer.removeFirst(totalLength)
            
            // Decode and inject the message
            do {
                let message = try MessageFraming.decode(messageData)
                injector.inject(message)
            } catch {
                log("Failed to decode message: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [Network] \(message)")
    }
}
