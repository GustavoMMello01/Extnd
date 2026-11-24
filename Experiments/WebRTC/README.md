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

## Fast cursor experiment

In a WebRTC mode, enable **Experimental Fast Cursor** on the Mac before starting the session. This adds a separate unordered WebRTC data channel that sends the latest pointer position without retransmission. The viewer draws an arrow over the video after the channel starts receiving data. Extnd keeps the captured cursor enabled until the viewer confirms that the overlay is ready. The Mac toggle can restore the captured cursor during the session. The experimental mode supports one viewer at a time.

### Validation plan

1. **Check correctness.** Confirm that the pointer follows the Extnd display after rotation or a Safari resize, hides when it leaves the display, and returns to the captured cursor when the Mac toggle is turned off. Repeat with a click and a window drag. If Safari cannot negotiate the experimental connection, start a new session with **Experimental Fast Cursor** turned off.
2. **Isolate the two paths on the Mac.** Start matching synthetic cursor and video changes at the same time. Poll the two visible states using the same WebKit clock. Record the number of matched transitions and how far the cursor leads the video at 30 and 60 fps. This isolates the relay and rendering paths and excludes mouse input, desktop capture, and the iPad's Wi-Fi and display.
3. **Measure on the target iPad.** Use a separate camera at 120 or 240 fps to film the mouse and iPad together. Run the same motions with the overlay off and on at 60 fps, then repeat at 30 fps. Measure from the first visible mouse movement to the first visible cursor motion or window response. Collect at least 20 moves per condition and compare medians and slow samples. Keep the Wi-Fi, room, and workload constant.
4. **Decide.** Advance the overlay if it improves the cursor median by roughly one 60 Hz refresh (17 ms) or more, preserves visibility and click alignment, and introduces no extra stalls. A larger gap between the pointer and a dragged window points to the video path as the next target. Compare 5 GHz conditions or instrument capture, encoding, and receiver buffering before changing codecs.

### Mac results

On macOS 26.6.2, an embedded WebKit viewer received both the overlay and H.264 video from the same local relay. The test sent 24 matched state changes per profile and sampled the position and decoded video from the same browser clock, with a 4 ms pause between observations. Each positive measurement means that the overlay update was observed before its matching video change.

| Stream profile | Overlay ahead | Median lead | Observed range |
| --- | --- | --- | --- |
| 1024 × 768 at 30 fps | 24 of 24 | 20 ms | 13–27 ms |
| 768 × 576 at 60 fps | 24 of 24 | 17 ms | 14–23 ms |

The WebKit test also hid the overlay while the video continued playing. These are synthetic, same-Mac measurements. Keep the experiment opt-in until the iPad mini 3 confirms the gain, correctly tracks the display, and passes the dragging and fallback checks above.
