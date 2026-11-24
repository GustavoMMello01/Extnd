# WebRTC testing and diagnostics

Extnd includes the Go/Pion WebRTC relay. When a WebRTC session starts, the Mac app captures the virtual display with ScreenCaptureKit, encodes H.264 with VideoToolbox, and runs the relay. The relay reports the Safari viewer URL back to the app so the QR code opens the correct session.

See the [Extnd README](../../README.md) for build requirements, setup steps, and the full technology overview.

## Compare the modes on iPad

1. Open Extnd, choose **WebRTC 60 fps**, and click **Start Extended Display**.
2. Scan the QR code with the iPad, open the link in Safari, and tap **Start WebRTC**.
3. On the Mac, enable **Show Streaming Stats on iPad**. Move the pointer and drag a window on the Extnd display. Note the decoded FPS and packet loss if Safari reports them.
4. End the session and repeat with **WebRTC 30 fps** and **MJPEG**. Use the same network, device positions, and motions.

An FPS counter measures how many frames are decoded per second. To measure visible delay, film the physical mouse and the iPad in the same high-frame-rate recording. Count the frames from the start of the motion to the first visible cursor movement, then repeat several times for each mode.

## Diagnostics

- If a WebRTC viewer fails, record the message displayed in Safari. A connection failure and a connected viewer waiting for its first decoded frame point to different stages.
- The session uses local UDP for WebRTC video. Keep both devices on the same network and grant local network access if macOS asks.
- Xcode builds the relay with [build-relay.sh](build-relay.sh), copies it into `Extnd.app/Contents/Helpers`, and signs it before signing the app bundle.
- Run `go test ./...` in this directory to test H.264 RTP delivery and picture-loss feedback. Run XCTest from Xcode to test the relay startup and video encoding from the Mac side.
