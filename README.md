# Extnd

Extnd turns an iPad into an extended Mac display over the local network. The Mac creates a separate 1024 × 768 desktop and the iPad displays it in Safari. Use the Mac's mouse and keyboard to move and control windows on the Extnd display.

## Quick start

1. Open the built `Extnd.app` in Finder. To build it yourself, open `Extnd.xcodeproj` in Xcode, select **Extnd** and **My Mac**, then press **⌘R**.
2. Connect the Mac and iPad to the same network. If the Mac lists several IP addresses, select the one on the iPad's network.
3. Choose a **Streaming Mode** and click **Start Extended Display**. Allow screen recording and local network access when macOS asks. Reopen Extnd if prompted.
4. Scan the QR code shown by Extnd or open the viewer address in Safari on the iPad. In WebRTC modes, tap **Start WebRTC**. The Mac app starts the bundled relay automatically.
5. Drag a window onto the **Extnd** display. To change its position, open **System Settings → Displays** on the Mac and arrange it alongside the main display.
6. Click **Stop Streaming** or quit Extnd to close the virtual display and end the session.

Use **Appearance** in the Mac toolbar to choose System, Light, or Dark. **Black border on iPad** toggles a thin frame around the streamed picture and can be changed during a session.

## Streaming modes

| Mode | Video output | When to use it |
| --- | --- | --- |
| **WebRTC 60 fps (768 × 576)** | H.264 at 768 × 576, targeting 60 fps | Smoother cursor movement and window dragging |
| **WebRTC 60 fps (640 × 480)** | H.264 at 640 × 480, targeting 60 fps | Smoother motion observed on iPad mini 3, with softer text |
| **WebRTC 30 fps** | H.264 at 1024 × 768, targeting 30 fps | Sharper text at the desktop's full resolution |
| **MJPEG** | JPEG frames at 1024 × 768, targeting up to 30 fps | Fallback if WebRTC does not connect |

The virtual desktop stays at 1024 × 768 in all modes. The MJPEG viewer also offers **Compatibility Mode**, which fetches JPEGs one at a time when the continuous stream cannot play.

Follow the [60 fps resolution comparison](Experiments/WebRTC/README.md#compare-60-fps-resolutions-on-ipad) to test whether the 640 × 480 mode improves window motion and keeps text readable on your iPad.

During a session, toggle **Show Streaming Stats on iPad** on the Mac to show or hide the overlay. WebRTC reports decoded FPS, video receive rate, resolution, and packet loss when Safari exposes them. The overlay labels source encoding rates when receiver statistics are unavailable. These figures describe the Extnd stream. Use the [camera-based validation plan](Experiments/WebRTC/README.md#validation-plan) to measure cursor-to-display delay.

## How Extnd works

[Architecture and technical specifications](ARCHITECTURE.md) covers the session lifecycle, wire formats, dependencies, and test coverage. It also compares [related implementations](ARCHITECTURE.md#related-implementations) and describes the next latency experiments.

| Technology | Role |
| --- | --- |
| **Swift 6, SwiftUI, and AppKit** | Run the Mac app and provide network selection, streaming controls, and session lifecycle. Core Image generates the viewer QR code. |
| **CoreGraphics virtual display** | Creates the separate desktop that macOS treats as an extended monitor. The private API lives in `Extnd/Display` and may need changes after macOS updates. |
| **ScreenCaptureKit** | Captures the Extnd display and the Mac cursor. In WebRTC modes, it supplies bi-planar YCbCr frames directly to the encoder. |
| **VideoToolbox and H.264** | Encode video in real time without frame reordering. The 60 fps profiles request zero queued frames where supported and provide more frequent keyframes. |
| **Core Image, MJPEG, and Network.framework** | Encode independent JPEGs and serve them to Safari over one persistent HTTP/TCP connection. The server skips older JPEGs when a viewer is busy. |
| **Go and Pion WebRTC** | Run the relay bundled inside the Mac app. The relay takes encoded H.264 from the local capture server, handles WebRTC signaling, sends encrypted video over UDP, and requests a keyframe when the viewer reports picture loss. |
| **Safari and JavaScript** | Play the stream in Safari and render the optional statistics overlay. |

The viewer uses a fresh random URL per session and HTTP for page loading and signaling. Use a trusted local network and share the URL only with intended viewers. WebRTC media is encrypted. Extnd handles signaling and media on the local network using host ICE candidates.

## How the streaming path evolved

1. **JPEG polling.** Safari requested a complete JPEG for each update. This proved the display and viewer worked, but each request added overhead.
2. **Continuous MJPEG.** One persistent HTTP connection eliminated repeated requests in the standard viewer. It still encoded each frame as a full JPEG.
3. **H.264 over WebRTC.** VideoToolbox encoded the display as video, and Pion switched media delivery to WebRTC over UDP. The iPad mini 3 on iOS 12.5.8 played the stream in a manual trial and felt more responsive than the earlier viewer.
4. **Integrated WebRTC.** Xcode now bundles the relay, and the app launches it and displays the viewer QR code. Picture-loss feedback helps the decoder recover without waiting for the next scheduled keyframe.
5. **Lower-resolution 60 fps option.** The 640 × 480 profile reduces the number of pixels per frame by about 31% compared with 768 × 576. Both target 60 fps.

## Benchmark results

### 60 fps resolution comparison

On an iPad mini 3 running iOS 12.5.8, the tester reported smoother motion at 640 × 480 than at 768 × 576, with lower image sharpness. The tester also reported playback below the 60 fps target. Sustained decoded FPS and motion-to-display delay still need to be measured on the iPad.

In a separate synthetic test on macOS 26.6.2, WebKit decoded the 640 × 480 stream over the bundled relay at about 60 fps, with zero packet loss reported during the sampled interval.

### Fast cursor

On macOS 26.6.2, the Mac's WebKit viewer observed 24 matched synthetic state changes per profile over the same relay. The lead is how much earlier the cursor overlay updated compared with its matching video change.

| WebRTC profile | Cursor ahead | Median lead | Observed range |
| --- | ---: | ---: | ---: |
| 1024 × 768 at 30 fps | 24/24 | 20 ms | 13–27 ms |
| 768 × 576 at 60 fps | 24/24 | 17 ms | 14–23 ms |

### Bitrate peaks

Each profile encoded the same 360 synthetic frames at 768 × 576 and 60 fps, with high-detail bursts and forced keyframes. Rates are H.264 payload rates over sliding windows. The experimental profile lowered the 250 ms peak by about **28%** in this workload.

| Profile | 250 ms peak | 250 ms p95 | 1 s peak | Encode p95 |
| --- | ---: | ---: | ---: | ---: |
| Standard | 8.38 Mb/s | 5.80 Mb/s | 3.53 Mb/s | 4.01 ms |
| Reduce Bitrate Peaks | 6.01 Mb/s | 4.63 Mb/s | 2.33 Mb/s | 4.26 ms |

### Stage timing example

In a separate synthetic WebKit playback check, the viewer decoded about 60 fps with zero reported packet loss during the sampled interval. The timing overlay reported the following sender-side values for that interval.

| Stage | p50 | p95 |
| --- | ---: | ---: |
| Encode and prepare the H.264 access unit | 3.6 ms | 4.7 ms |
| Submit the encoded frame to the local relay feed | 0.1 ms | 0.2 ms |
| Packetize and write RTP in the relay | 0.1 ms | 0.3 ms |

See [WebRTC testing and diagnostics](Experiments/WebRTC/README.md) for the workloads, statistics and device comparisons. Both experiments remain opt-in.

## Build, test, and troubleshoot

Building from source requires macOS 14 or later, Xcode with Swift 6, and Go 1.25 or later. Xcode builds the Go/Pion relay for the app's architectures, embeds it in the app, and signs it. The built app already contains the relay.

Run the XCTest suite with **⌘U** or use:

```sh
xcodebuild -project Extnd.xcodeproj -scheme Extnd -destination 'platform=macOS' test
cd Experiments/WebRTC
go test ./...
```

The XCTest checks cover app configuration, H.264 keyframes in each WebRTC mode, capture settings for 640 × 480 at 60 fps, the bitrate option, MJPEG and statistics endpoints, the bundled relay, cursor packet format, and timing summaries. The Go checks cover WebRTC video over UDP, picture-loss feedback, cursor delivery, and relay statistics. The Go suite also passes with `go test -race ./...`.

Local builds use ad hoc signing. After a rebuild, macOS may keep the screen-recording approval tied to an older copy of the app. To clear the old approval, quit Extnd and run:

```sh
/usr/bin/tccutil reset ScreenCapture io.extnd.Extnd
```

Open Extnd again, start the display, and grant screen-recording access when prompted.

## Experimental fast cursor

The [fast cursor validation plan](Experiments/WebRTC/README.md#fast-cursor-experiment) covers the optional WebRTC pointer overlay and explains how to compare it with the pointer captured in the video.

## Experimental bitrate profile

[Timing and bitrate tests](Experiments/WebRTC/README.md#timing-and-bitrate-experiment) explain the optional peak limit, per-stage statistics, and how to compare the result on the iPad.
