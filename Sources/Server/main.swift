import Foundation
import Network
import CoreGraphics
import ApplicationServices // <-- FIX 1: Import ApplicationServices
import SharedCode

class Server {
    let listener: NWListener

    init(port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        
        do {
            listener = try NWListener(using: parameters, on: port)
            
            // Enable Bonjour advertising <-- FIX 2: Set service on the listener
            listener.service = NWListener.Service(name: "RemoteKVMServer", type: NetworkConstants.serviceType)
            
            listener.stateUpdateHandler = self.stateDidChange(to:)
            listener.newConnectionHandler = self.didAccept(nwConnection:)
        } catch {
            fatalError("Failed to create listener: \(error)")
        }
    }

    func start() {
        print("Server starting...")
        listener.start(queue: .main)
        
        // Check for accessibility permissions and guide the user if needed
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            print("\n--- PERMISSION REQUIRED ---")
            print("This application needs Accessibility permissions to simulate keyboard events.")
            print("Please go to System Settings > Privacy & Security > Accessibility and enable it for 'Server'.")
            print("---------------------------\n")
        }
    }

    private func stateDidChange(to newState: NWListener.State) {
        switch newState {
        case .ready:
            print("Server ready and advertising on port \(listener.port?.debugDescription ?? "?")")
        case .failed(let error):
            print("Server failed with error: \(error). Restarting.")
            listener.cancel()
            start()
        default:
            break
        }
    }

    private func didAccept(nwConnection: NWConnection) {
        print("Accepted new connection from \(nwConnection.endpoint)")
        let connection = ServerConnection(nwConnection: nwConnection)
        connection.didStopCallback = { // <-- FIX 3: Remove unused capture
            // Handle cleanup if needed when a connection closes
            print("Connection with \(nwConnection.endpoint) stopped.")
        }
        connection.start()
    }
}

class ServerConnection {
    private static let newline = "\n".data(using: .utf8)!

    private let nwConnection: NWConnection
    var didStopCallback: (() -> Void)? = nil

    init(nwConnection: NWConnection) {
        self.nwConnection = nwConnection
    }
    
    func start() {
        nwConnection.stateUpdateHandler = self.stateDidChange(to:)
        nwConnection.start(queue: .main)
        receive()
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .failed(let error):
            print("Connection failed with error: \(error)")
            self.stop(error: error)
        case .cancelled:
            // The connection has been cancelled, so stop processing
            self.stop(error: nil)
        case .ready:
             print("Connection ready.")
        default:
            break
        }
    }
    
    private func receive() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data, _, isComplete, error) in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                // This is the core of the newline-delimited stream processing
                self.processData(data)
                // Continue waiting for more data
                self.receive()
            }
            
            if isComplete {
                self.stop(error: nil)
            } else if let error = error {
                self.stop(error: error)
            }
        }
    }
    
    // Buffer to hold incoming data until a newline is found
    private var buffer = Data()

    private func processData(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: ServerConnection.newline) {
            let messageData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            
            if !messageData.isEmpty {
                handleMessage(messageData)
            }
        }
    }
    
    private func handleMessage(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            let event = try decoder.decode(RemoteKeyboardEvent.self, from: data)
            
            // Convert to CGEvent and post it
            if let cgEvent = event.toCGEvent() {
                cgEvent.post(tap: .cgSessionEventTap)
            } else {
                 print("Failed to convert to CGEvent")
            }
        } catch {
            print("Failed to decode RemoteKeyboardEvent: \(error)")
        }
    }

    private func stop(error: Error?) {
        self.nwConnection.stateUpdateHandler = nil
        self.nwConnection.cancel()
        if let didStopCallback = self.didStopCallback {
            didStopCallback()
        }
    }
}

// Main entry point
let server = Server(port: .any)
server.start()

// Keep the server running
RunLoop.main.run()