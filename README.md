# RemoteKbMouse

A LAN-based keyboard and mouse sharing system between two Macs, implemented as command-line tools using Swift and public macOS APIs.

## Overview

This project provides two command-line tools:

- **RemoteKbMouseHost** - Runs on the Mac with the physical keyboard/mouse (Mac A). Captures input events and forwards them over the network when remote control is enabled.
- **RemoteKbMouseClient** - Runs on the remote Mac to be controlled (Mac B). Receives events over the network and injects them locally.

### Key Features

- **No GUI** - Pure command-line tools for simplicity and reliability
- **No edge-slide behavior** - Control mode is toggled via a global hotkey
- **Swift-only** - Uses only Swift and public macOS APIs
- **Minimal permissions** - Each binary requests only the permissions it needs
- **Length-prefixed JSON protocol** - Simple and reliable TCP communication

## Architecture

```
┌──────────────────────────────────────┐      ┌──────────────────────────────────────┐
│            Mac A (Host)              │      │          Mac B (Client)              │
│   M1 Mac Studio with KB/Mouse        │      │           M3 MacBook                 │
│                                      │      │                                      │
│  ┌─────────────────────────────────┐ │      │  ┌─────────────────────────────────┐ │
│  │     RemoteKbMouseHost           │ │      │  │     RemoteKbMouseClient         │ │
│  │                                 │ │      │  │                                 │ │
│  │  ┌─────────────────────────┐    │ │      │  │  ┌─────────────────────────┐    │ │
│  │  │ HostInputCaptureManager │    │ │      │  │  │ ClientNetworkListener   │    │ │
│  │  │   (CGEvent Tap)         │    │ │      │  │  │   (NWListener)          │    │ │
│  │  └───────────┬─────────────┘    │ │      │  │  └───────────┬─────────────┘    │ │
│  │              │                  │ │      │  │              │                  │ │
│  │  ┌───────────▼─────────────┐    │ │      │  │  ┌───────────▼─────────────┐    │ │
│  │  │ HostControlStateMachine │    │ │      │  │  │ ClientEventInjector     │    │ │
│  │  │   (LOCAL/REMOTE mode)   │    │ │      │  │  │   (CGEventPost)         │    │ │
│  │  └───────────┬─────────────┘    │ │      │  │  └─────────────────────────┘    │ │
│  │              │                  │ │      │  │                                 │ │
│  │  ┌───────────▼─────────────┐    │ │      │  └─────────────────────────────────┘ │
│  │  │ HostNetworkSender       │────┼─┼──────┼──▶ TCP Port 50505                   │
│  │  │   (NWConnection)        │    │ │      │                                      │
│  │  └─────────────────────────┘    │ │      │                                      │
│  │                                 │ │      │                                      │
│  └─────────────────────────────────┘ │      └──────────────────────────────────────┘
│                                      │
└──────────────────────────────────────┘
```

## Building

### Prerequisites

- macOS 13.0 or later
- Xcode 15.0 or later

### Build Commands

```bash
# Build both targets
cd /path/to/RemoteKbMouse
xcodebuild -target RemoteKbMouseHost -configuration Release
xcodebuild -target RemoteKbMouseClient -configuration Release

# Or use Xcode GUI
open RemoteKbMouse.xcodeproj
# Select scheme and build (Cmd+B)
```

The binaries will be in `build/Release/` (or `build/Debug/` for Debug builds).

## Permissions

### RemoteKbMouseHost (Mac A)

The Host requires these permissions:

1. **Input Monitoring** - To capture keyboard events globally via CGEvent tap
2. **Accessibility** - To capture mouse events and observe global input

Grant permissions in:
- System Settings → Privacy & Security → Input Monitoring → Add `RemoteKbMouseHost`
- System Settings → Privacy & Security → Accessibility → Add `RemoteKbMouseHost`

### RemoteKbMouseClient (Mac B)

The Client requires:

1. **Accessibility** - To allow CGEventPost to inject events system-wide

Grant permissions in:
- System Settings → Privacy & Security → Accessibility → Add `RemoteKbMouseClient`

### Code Signing

For the permissions to work, the binaries must be code-signed:

```bash
# Ad-hoc signing (for local testing)
codesign --force --sign - build/Release/RemoteKbMouseHost
codesign --force --sign - build/Release/RemoteKbMouseClient

# Or with Developer ID (for distribution)
codesign --force --sign "Developer ID Application: Your Name" build/Release/RemoteKbMouseHost
codesign --force --sign "Developer ID Application: Your Name" build/Release/RemoteKbMouseClient
```

## Usage

### On Mac B (Client - the Mac to be controlled)

```bash
# Start the client and wait for connections
./RemoteKbMouseClient --port 50505

# With verbose logging
./RemoteKbMouseClient --port 50505 --verbose
```

Output:
```
╔══════════════════════════════════════════════════════════╗
║              RemoteKbMouseClient v1.0                     ║
║     Keyboard/Mouse Sharing Client for macOS              ║
╚══════════════════════════════════════════════════════════╝
[...] [Client] Configuration:
  Port: 50505
  Verbose: false

[...] [Client] Checking permissions...
[...] [Client] Accessibility permissions OK
[...] [Network] Listening on port 50505
[...] [Client] Client is running!
[...] [Client] Waiting for Host to connect on port 50505...
```

### On Mac A (Host - the Mac with keyboard/mouse)

```bash
# Connect to the client
./RemoteKbMouseHost --client-ip 192.168.1.50 --port 50505

# With custom hotkey
./RemoteKbMouseHost --client-ip 192.168.1.50 --hotkey ctrl+opt+cmd+r
```

Output:
```
╔══════════════════════════════════════════════════════════╗
║              RemoteKbMouseHost v1.0                       ║
║     Keyboard/Mouse Sharing Host for macOS                ║
╚══════════════════════════════════════════════════════════╝
[...] [Host] Configuration:
  Client: 192.168.1.50:50505
  Hotkey: Ctrl+Opt+Cmd+H

[...] [Host] Checking permissions...
[...] [Host] Accessibility permissions OK
[...] [Input] Setting up event tap...
[...] [Input] Event tap started successfully
[...] [Network] Connecting to 192.168.1.50:50505...
[...] [Network] Connected to client at 192.168.1.50:50505
[...] [Host] Host is running!
[...] [Host] Press Ctrl+Opt+Cmd+H to toggle between LOCAL and REMOTE control
```

### Switching Control Modes

Press the hotkey (default: **Ctrl+Opt+Cmd+H**) to toggle between:

- **LOCAL control** - Keyboard/mouse affects Mac A normally
- **REMOTE control** - Keyboard/mouse events are forwarded to Mac B

The Host will log mode changes:
```
[...] [Mode] Switched to REMOTE control
[...] [Mode] Switched to LOCAL control
```

### CLI Options

#### RemoteKbMouseHost

| Option | Short | Required | Default | Description |
|--------|-------|----------|---------|-------------|
| `--client-ip` | `-c` | Yes | - | IP address or hostname of the client Mac |
| `--port` | `-p` | No | 50505 | TCP port to connect to |
| `--hotkey` | `-k` | No | ctrl+opt+cmd+h | Key combination to toggle control |
| `--help` | `-h` | No | - | Show help message |

#### RemoteKbMouseClient

| Option | Short | Required | Default | Description |
|--------|-------|----------|---------|-------------|
| `--port` | `-p` | No | 50505 | TCP port to listen on |
| `--verbose` | `-v` | No | false | Print verbose debug logs |
| `--help` | `-h` | No | - | Show help message |

### Hotkey Format

The hotkey is specified as modifier keys plus a key, separated by `+`:

- **Modifiers**: `ctrl`, `control`, `opt`, `option`, `alt`, `cmd`, `command`, `shift`
- **Keys**: `a-z`, `0-9`, `f1-f12`, `space`, `return`, `escape`, `tab`, etc.

Examples:
- `ctrl+opt+cmd+h` (default)
- `ctrl+shift+f12`
- `cmd+opt+space`

## Event Protocol

Events are transmitted as length-prefixed JSON over TCP:

```
[4-byte big-endian length][JSON-encoded EventMessage]
```

### Event Types

```swift
enum EventKind: String, Codable {
    case keyboard    // Key press/release
    case mouseMove   // Mouse movement
    case mouseButton // Mouse button click
    case scroll      // Scroll wheel
}
```

### Example Messages

Keyboard event:
```json
{
  "kind": "keyboard",
  "keyboard": {
    "keyCode": 4,
    "isKeyDown": true,
    "flags": 1048576
  }
}
```

Mouse move event:
```json
{
  "kind": "mouseMove",
  "mouseMove": {
    "deltaX": 10,
    "deltaY": -5,
    "absoluteX": 500.0,
    "absoluteY": 300.0
  }
}
```

## Troubleshooting

### "Failed to create event tap"

This means Input Monitoring or Accessibility permissions are not granted:

1. Open System Settings → Privacy & Security
2. Add the Host binary to both Input Monitoring and Accessibility
3. Make sure the binary is code-signed
4. Restart the Host after granting permissions

### Connection refused

1. Make sure the Client is running first
2. Check that the IP address is correct
3. Verify both Macs are on the same network
4. Check firewall settings allow port 50505

### Events not being injected

1. Make sure the Client has Accessibility permissions
2. The Client binary must be code-signed
3. Try restarting the Client after granting permissions

### Keyboard events work but not in secure text fields

Some secure text fields (like password fields) may block synthetic keyboard events. This is a macOS security feature and cannot be bypassed.

## Caveats

1. **Secure Text Fields**: Password fields and other secure inputs may not accept synthetic keyboard events
2. **TCC Prompts**: First run will trigger permission prompts that need to be approved
3. **Screen Resolution**: Mouse positions use absolute coordinates from the Host's screen; different resolutions may need scaling
4. **Network Latency**: High latency networks may cause noticeable input lag

## License

MIT License - See LICENSE file for details.

## Project Structure

```
RemoteKbMouse/
├── RemoteKbMouse.xcodeproj/
├── RemoteKbMouseHost/           # Host target sources
│   ├── main.swift
│   ├── HostConfig.swift
│   ├── HostControlStateMachine.swift
│   ├── HostInputCaptureManager.swift
│   └── HostNetworkSender.swift
├── RemoteKbMouseClient/         # Client target sources
│   ├── main.swift
│   ├── ClientConfig.swift
│   ├── ClientEventInjector.swift
│   └── ClientNetworkListener.swift
├── Shared/                      # Shared code
│   └── EventMessage.swift
└── README.md
```
