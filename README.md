# Extnd

Extnd turns an iPad into an extended Mac display over the local network. The Mac creates a separate 1024 × 768 desktop and the iPad displays it in Safari. Use the Mac's mouse and keyboard to move and control windows on the Extnd display.

## Quick start

1. Open the built `Extnd.app` in Finder. To build it yourself, open `Extnd.xcodeproj` in Xcode, select **Extnd** and **My Mac**, then press **⌘R**.
2. Connect the Mac and iPad to the same network. If the Mac lists several IP addresses, select the one on the iPad's network.
3. Choose a **Streaming Mode** and click **Start Extended Display**. Allow screen recording and local network access when macOS asks. Reopen Extnd if prompted.
4. Scan the QR code shown by Extnd or open the viewer address in Safari on the iPad. In WebRTC modes, tap **Start WebRTC**. The Mac app starts the bundled relay automatically.
5. Drag a window onto the **Extnd** display. To change its position, open **System Settings → Displays** on the Mac and arrange it alongside the main display.
6. Click **Stop Streaming** or quit Extnd to close the virtual display and end the session.

## Streaming modes

| Mode | Video output | When to use it |
| --- | --- | --- |
| **WebRTC 60 fps** | H.264 at 768 × 576, targeting 60 fps | Smoother cursor movement and window dragging |
| **WebRTC 30 fps** | H.264 at 1024 × 768, targeting 30 fps | Sharper text at the desktop's full resolution |
| **MJPEG** | JPEG frames at 1024 × 768, targeting up to 30 fps | Fallback if WebRTC does not connect |

The virtual desktop stays at 1024 × 768 in all modes. The MJPEG viewer also offers **Compatibility Mode**, which fetches JPEGs one at a time when the continuous stream cannot play.

During a session, toggle **Show Streaming Stats on iPad** on the Mac to show or hide the overlay. WebRTC reports decoded FPS, video receive rate, resolution, and packet loss when Safari exposes them. The overlay labels source encoding rates when receiver statistics are unavailable. These figures describe the Extnd stream. Use the camera-based test below to measure cursor-to-display delay.

## How Extnd works

| Technology | Role |
| --- | --- |
| **Swift 6, SwiftUI, and AppKit** | Run the Mac app and provide network selection, streaming controls, and session lifecycle. Core Image generates the viewer QR code. |
| **CoreGraphics virtual display** | Creates the separate desktop that macOS treats as an extended monitor. The private API lives in `Extnd/Display` and may need changes after macOS updates. |
| **ScreenCaptureKit** | Captures the Extnd display and the Mac cursor. In WebRTC modes, it supplies bi-planar YCbCr frames directly to the encoder. |
| **VideoToolbox and H.264** | Encode video in real time without frame reordering. The 60 fps profile requests zero queued frames where supported and provides more frequent keyframes. |
| **Core Image, MJPEG, and Network.framework** | Encode independent JPEGs and serve them to Safari over one persistent HTTP/TCP connection. The server skips older JPEGs when a viewer is busy. |
| **Go and Pion WebRTC** | Run the relay bundled inside the Mac app. The relay takes encoded H.264 from the local capture server, handles WebRTC signaling, sends encrypted video over UDP, and requests a keyframe when the viewer reports picture loss. |
| **Safari and JavaScript** | Play the stream in Safari and render the optional statistics overlay. |

The viewer uses a fresh random URL per session and HTTP for page loading and signaling. Use a trusted local network and share the URL only with intended viewers. WebRTC media is encrypted. Extnd handles signaling and media on the local network using host ICE candidates.

## How the streaming path evolved

1. **JPEG polling.** Safari requested a complete JPEG for each update. This proved the display and viewer worked, but each request added overhead.
2. **Continuous MJPEG.** One persistent HTTP connection eliminated repeated requests in the standard viewer. It still encoded each frame as a full JPEG.
3. **H.264 over WebRTC.** VideoToolbox encoded the display as video, and Pion switched media delivery to WebRTC over UDP. The iPad mini 3 on iOS 12.5.8 played the stream in a manual trial and felt more responsive than the earlier viewer.
4. **Integrated WebRTC.** Xcode now bundles the relay, and the app launches it and displays the viewer QR code. The 60 fps mode trades some stream resolution for smoother motion, and picture-loss feedback helps the decoder recover without waiting for the next scheduled keyframe.

For repeatable comparisons, see [WebRTC testing and diagnostics](Experiments/WebRTC/README.md). The Mac WebKit test used synthetic frames. End-to-end cursor latency and sustained 60 fps have yet to be measured on the target iPad.

## Build, test, and troubleshoot

Building from source requires macOS 14 or later, Xcode with Swift 6, and Go 1.25 or later. Xcode builds the Go/Pion relay for the app's architectures, embeds it in the app, and signs it. The built app already contains the relay.

Run the XCTest suite with **⌘U** or use:

```sh
xcodebuild -project Extnd.xcodeproj -scheme Extnd -destination 'platform=macOS' test
cd Experiments/WebRTC
go test ./...
```

XCTest covers the app configuration, H.264 keyframes, MJPEG and statistics endpoints, and startup of the bundled relay. The Go test checks H.264 delivery to a WebRTC peer over UDP and verifies that picture-loss feedback reaches the relay.

Local builds use ad hoc signing. After a rebuild, macOS may keep the screen-recording approval tied to an older copy of the app. To clear the old approval, quit Extnd and run:

```sh
/usr/bin/tccutil reset ScreenCapture io.extnd.Extnd
```

Open Extnd again, start the display, and grant screen-recording access when prompted.

## Experimental fast cursor

The [fast cursor validation plan](Experiments/WebRTC/README.md#fast-cursor-experiment) covers the optional WebRTC pointer overlay and explains how to compare it with the pointer captured in the video.
