# Copilot Instructions for RemoteKbMouse

## Project Overview
RemoteKbMouse is a Swift-based project designed to facilitate remote keyboard and mouse control. The codebase is divided into three main components:

1. **Client**: Handles the user interface and interactions on the client side.
2. **Server**: Manages the backend logic and communication with the client.
3. **SharedCode**: Contains shared utilities and logic, including video streaming and other reusable components.

### Key Files and Directories
- `Sources/Client/main.swift`: Entry point for the client-side application.
- `Sources/Server/main.swift`: Entry point for the server-side application.
- `Sources/SharedCode/SharedCode.swift`: Contains shared logic used by both client and server.
- `Sources/SharedCode/VideoStreaming.swift`: Implements video streaming functionality.

## Architecture
The project follows a modular architecture:
- **Client** and **Server** are distinct modules that rely on **SharedCode** for common functionality.
- Communication between the client and server is likely facilitated through network protocols (e.g., WebSockets or HTTP).
- Shared utilities in `SharedCode` ensure consistency and reduce duplication.

## Developer Workflows

### Building the Project
Use the Swift Package Manager (SPM) to build the project:
```bash
swift build
```

### Running the Project
To run the client:
```bash
swift run Client
```
To run the server:
```bash
swift run Server
```

### Testing
If tests are added, run them using:
```bash
swift test
```

### Debugging
- Use Xcode for debugging with breakpoints and runtime analysis.
- Add logging statements in critical sections for runtime insights.

## Project-Specific Conventions
- **Modular Design**: Keep shared logic in `SharedCode` to maintain separation of concerns.
- **Swift Best Practices**: Follow Swift naming conventions and use type safety wherever possible.
- **Video Streaming**: Implemented in `VideoStreaming.swift`, ensure any updates maintain compatibility with both client and server.

## Integration Points
- **Networking**: Ensure client-server communication is robust and handles edge cases like network failures.
- **SharedCode**: Any changes here must be tested across both client and server to avoid regressions.

## Examples
### Shared Utility Usage
Example of using shared code in `SharedCode.swift`:
```swift
import SharedCode

let utility = SharedUtility()
utility.performTask()
```

### Video Streaming
Example of initializing video streaming:
```swift
import SharedCode

let streamer = VideoStreamer()
streamer.startStreaming()
```

---

This document is a starting point. Update it as the project evolves to ensure it remains accurate and helpful.