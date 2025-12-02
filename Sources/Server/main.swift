import Foundation
import Network
import CoreGraphics
import ApplicationServices
import SharedCode

class Server {
    private var listener: NWListener
    private let port: NWEndpoint.Port
    
    // Cached permission state (checked once at launch)
    private var hasAccessibilityPermission: Bool = false

    init(port: NWEndpoint.Port) {
        self.port = port
        let parameters = NWParameters.tcp
        
        do {
            listener = try NWListener(using: parameters, on: port)
            
            // Enable Bonjour advertising
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
        
        // Check for accessibility permissions once and cache the result
        if !hasAccessibilityPermission {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
            hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)

            if !hasAccessibilityPermission {
                print("\n--- PERMISSION REQUIRED ---")
                print("This application needs Accessibility permissions to simulate keyboard events.")
                print("Please go to System Settings > Privacy & Security > Accessibility and enable it for 'Server'.")
                print("---------------------------\n")
            }
        }
    }
    
    /// Creates a new listener instance (required after cancel)
    private func rebuildListener() {
        let parameters = NWParameters.tcp
        
        do {
            listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(name: "RemoteKVMServer", type: NetworkConstants.serviceType)
            listener.stateUpdateHandler = self.stateDidChange(to:)
            listener.newConnectionHandler = self.didAccept(nwConnection:)
        } catch {
            print("Failed to rebuild listener: \(error). Exiting.")
            exit(1)
        }
    }

    private func stateDidChange(to newState: NWListener.State) {
        switch newState {
        case .ready:
            print("Server ready and advertising on port \(listener.port?.debugDescription ?? "?")")
        case .failed(let error):
            print("Server failed with error: \(error). Rebuilding listener...")
            listener.cancel()
            // After cancel, listener cannot be reused - must create a new one
            rebuildListener()
            start()
        default:
            break
        }
    }

    private func didAccept(nwConnection: NWConnection) {
        print("Accepted new connection from \(nwConnection.endpoint)")
        let connection = ServerConnection(nwConnection: nwConnection)
        connection.didStopCallback = {
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
            // Send screen info to client on connect
            sendScreenInfo()
        default:
            break
        }
    }
    
    private func sendScreenInfo() {
        let screenSize = getMainScreenSize()
        let screenInfo = ScreenInfoEvent(width: Double(screenSize.width), height: Double(screenSize.height))
        let event = RemoteInputEvent.screenInfo(screenInfo)
        send(event: event)
        print("Sent screen info: \(screenSize.width)x\(screenSize.height)")
    }
    
    private func sendControlRelease() {
        let event = RemoteInputEvent.controlRelease
        send(event: event)
        print("Sent control release (right edge hit)")
    }
    
    private func send(event: RemoteInputEvent) {
        guard nwConnection.state == .ready else { return }
        do {
            let data = try JSONEncoder().encode(event)
            let framedData = data + ServerConnection.newline
            nwConnection.send(content: framedData, completion: .idempotent)
        } catch {
            print("Failed to encode event: \(error)")
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
            let inputEvent = try decoder.decode(RemoteInputEvent.self, from: data)
            
            switch inputEvent {
            case .keyboard(let keyboardEvent):
                if let cgEvent = keyboardEvent.toCGEvent() {
                    cgEvent.post(tap: .cgSessionEventTap)
                } else {
                    print("Failed to convert keyboard event to CGEvent")
                }
                
            case .mouse(let mouseEvent):
                let screenSize = getMainScreenSize()
                
                if let cgEvent = mouseEvent.toCGEvent(screenSize: screenSize) {
                    cgEvent.post(tap: .cgSessionEventTap)
                    
                    // Check for right edge hit after posting the event
                    checkRightEdge(screenSize: screenSize)
                } else {
                    print("Failed to convert mouse event to CGEvent")
                }
                
            case .warpCursor(let warpEvent):
                // Warp cursor to specified position
                let point = CGPoint(x: warpEvent.x, y: warpEvent.y)
                CGWarpMouseCursorPosition(point)
                print("Warped cursor to \(point)")
                
            case .screenInfo, .controlRelease:
                // These are server-to-client events, ignore if received
                break
            }
        } catch {
            print("Failed to decode RemoteInputEvent: \(error)")
            print("Raw data: \(String(data: data, encoding: .utf8) ?? "non-utf8")")
        }
    }
    
    private func checkRightEdge(screenSize: CGSize) {
        // Get current cursor position
        guard let currentPos = CGEvent(source: nil)?.location else { return }
        
        // Check if cursor hit right edge
        if currentPos.x >= screenSize.width - 1 {
            sendControlRelease()
        }
    }
    
    private func getMainScreenSize() -> CGSize {
        let mainDisplayID = CGMainDisplayID()
        let width = CGDisplayPixelsWide(mainDisplayID)
        let height = CGDisplayPixelsHigh(mainDisplayID)
        return CGSize(width: width, height: height)
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