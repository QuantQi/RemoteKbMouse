# RemoteKbMouse

A simple Swift utility for sharing keyboard and mouse control between two Macs over LAN, with video capture card support.

## Setup

```
┌─────────────────────────────────────────────────────────────┐
│  HOST MAC (where you sit)                                    │
│  - Has video capture card                                    │
│  - Displays client screen fullscreen                        │
│  - Sends keyboard/mouse events to client                    │
└──────────────────┬──────────────────────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    │ HDMI/Video   │ LAN (TCP)    │
    │ (capture)    │ (kb/mouse)   │
    ▼              ▼              │
┌─────────────────────────────────────────────────────────────┐
│  CLIENT MAC (remote)                                         │
│  - HDMI out to capture card                                  │
│  - Receives and executes input events                       │
└─────────────────────────────────────────────────────────────┘
```

## Building

```bash
swift build -c release
```

Binaries:
- `.build/release/Host`
- `.build/release/Client`

## Usage

### On the Client Mac (remote machine):

```bash
.build/release/Client
```

Listens on port 9876. New connections automatically kill existing ones.

### On the Host Mac (where you sit):

```bash
.build/release/Host              # Uses default IP: 192.168.1.8
.build/release/Host 192.168.1.50 # Custom client IP
```

Launches fullscreen video display from capture card at maximum resolution/refresh rate.

### Control Switching

Two ways to switch between controlling Host and Client:

**1. Automatic (default):**
- Click on/focus the video window → Control goes to **Client**
- Click elsewhere or switch apps → Control returns to **Host**

**2. Manual hotkey:**
- Press **Cmd+Option+Ctrl+C** to toggle manual override mode
- When manual override is ON, auto-switching is disabled
- Press again to return to auto-switch mode

## Permissions

**Host Mac:**
- Accessibility (for input capture)
- Camera (for video capture card access)

**Client Mac:**
- Accessibility (for input simulation)

## Network

TCP port **9876** for input events.

## Limitations

- macOS only
- Screen coordinates sent as-is (works best with matching resolutions)
- No encryption (trusted networks only)
