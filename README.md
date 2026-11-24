# Extnd

Extnd creates a 1024 × 768 extended display on a Mac and streams it to Safari on an iPad over the local network. The Mac app requires macOS 14 or later, uses Swift 6, and has no external dependencies.

## Run on your Mac

1. Open `Extnd.xcodeproj` in Xcode, select the **Extnd** scheme and **My Mac**, then press **⌘R**.
2. Connect the Mac and iPad to the same network. If Extnd lists several addresses, choose the one on the iPad's network.
3. Click **Iniciar tela estendida** (Start extended display). Allow screen recording in **System Settings → Privacy & Security** when prompted, and reopen Extnd if macOS asks. Allow local network access if prompted.
4. Scan the QR code with the iPad camera or enter the full URL in Safari. The default viewer streams JPEG frames continuously. If Safari cannot display it, tap **Modo compatível** (Compatibility mode).
5. Drag a window from the Mac to the **Extnd** display. Use **System Settings → Displays** to arrange it beside the main display. If both displays show the same desktop, check that **Use as** is set to **Extended display**.
6. Click **Parar transmissão** (Stop streaming) or quit Extnd to end the session.

## Streaming and compatibility

- The default viewer uses a persistent MJPEG connection. Capture targets up to 30 frames per second, and the sender skips intermediate frames when it is busy. The actual frame rate and latency depend on the Wi-Fi connection and the iPad.
- Compatibility mode still requests individual JPEG frames. It can feel slower, especially when moving the cursor. Control the extended display with the Mac's mouse and keyboard.
- The viewer uses HTTP and a new random URL for each session. Use a trusted network and share the URL only with people authorized to view the display.
- Display creation uses a private CoreGraphics API isolated in `Extnd/Display`. This build is for local use and may need changes after macOS updates. ScreenCaptureKit captures only the virtual display.
- The target client is an iPad mini 3 running iOS 12.5.8. The earlier viewer displayed the Mac screen on the device. The new streaming mode still needs a latency and compatibility check on that iPad.

## Development and tests

| Directory | Responsibility |
| --- | --- |
| `Extnd/App` | macOS app lifecycle |
| `Extnd/Display` | Virtual display creation and release |
| `Extnd/Features/Home` | Session setup and controls |
| `Extnd/Sharing` | Screen capture, local HTTP server, and Safari viewer |
| `ExtndTests` | App configuration and HTTP server tests |

The macOS bundle identifier is `io.extnd.Extnd`. Local builds use ad hoc signing. Press **⌘U** in Xcode or run:

```sh
xcodebuild -project Extnd.xcodeproj -scheme Extnd -destination 'platform=macOS' test
```
