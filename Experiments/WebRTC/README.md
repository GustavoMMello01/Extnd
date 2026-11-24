# H.264 over WebRTC experiment

This experiment compares the standard MJPEG viewer with hardware-capable H.264 encoding in VideoToolbox and WebRTC delivery through Pion. Both modes capture the same 1024 × 768 virtual display and target up to 30 fps. The experiment requires Go 1.25 or later to build the relay. The regular macOS app and MJPEG mode still build without Go or third-party dependencies.

## Start the experiment

1. Run Extnd from Xcode. Select the Mac's Wi-Fi address, enable **Teste WebRTC (H.264)**, and click **Iniciar tela estendida**. Allow screen capture when macOS asks. Copy the address shown by Extnd.
2. From the repository root, start the relay. Replace the quoted value with the full address you copied:

   ```sh
   cd Experiments/WebRTC
   go run . -source 'http://MAC_IP:PORT/SESSION/'
   ```

3. On the iPad, open the **different URL printed by the relay** in Safari. Tap **Start WebRTC**. The page shows the decoded video size and, when Safari exposes it, the receive frame rate. Move a window to Extnd's display and move the mouse over it.
4. Stop the Extnd session when done. To repeat in MJPEG mode, turn off the WebRTC checkbox, start a new session, and open the app's QR link.

The relay uses local UDP candidates and needs the Mac and iPad on the same network. It uses a random URL for signaling over HTTP and WebRTC's encrypted media transport. Allow the relay on a trusted local network if the macOS firewall asks. No external signaling service or STUN/TURN server is used.

## Compare the modes

Keep both devices in the same place, use the same Wi-Fi connection, and repeat the same cursor movements and window drags with each mode. If you can film both the physical mouse and the iPad with a high-frame-rate camera, count frames between the start of the motion and the first visible cursor movement. Compare several runs. The Safari frame-rate readout measures throughput, which does not establish end-to-end latency.

The test still needs a real iPad mini 3 running iOS 12.5.8. If the Safari viewer fails, record the message shown beside **Start WebRTC**. That distinguishes negotiation problems from a connection that never delivers a decoded frame.

## Local validation

Run `go test ./...` from this directory to verify that a separate WebRTC peer receives H.264 RTP over UDP. Run XCTest from Xcode to verify the VideoToolbox encoder and the existing MJPEG server.
