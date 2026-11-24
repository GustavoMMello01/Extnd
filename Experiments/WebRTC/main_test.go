package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

func TestH264OverWebRTC(t *testing.T) {
	b, err := newBridge("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	cursor, err := newCursorRelay()
	if err != nil {
		t.Fatal(err)
	}
	defer cursor.socket.Close()
	b.cursor = cursor
	go cursor.forward()
	keyFrameRequests := make(chan struct{}, 4)
	b.requestKeyFrame = func() { keyFrameRequests <- struct{}{} }
	req := httptest.NewRequest(http.MethodPost, "/offer", nil)
	offerResponse := httptest.NewRecorder()
	b.offer(offerResponse, req)
	if offerResponse.Code != http.StatusOK {
		t.Fatalf("offer: %s", offerResponse.Body.String())
	}
	var result struct {
		ID    string
		Offer webrtc.SessionDescription
	}
	if err := json.Unmarshal(offerResponse.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	defer b.peers[result.ID].Close()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	receiver, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	got := make(chan string, 1)
	receivedSSRC := make(chan uint32, 1)
	cursorChannel := make(chan *webrtc.DataChannel, 1)
	cursorMessages := make(chan []byte, 1)
	receiver.OnDataChannel(func(channel *webrtc.DataChannel) {
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			select {
			case cursorMessages <- message.Data:
			default:
			}
		})
		channel.OnOpen(func() { cursorChannel <- channel })
	})
	receiver.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		packet, _, err := track.ReadRTP()
		if err != nil {
			got <- err.Error()
			return
		}
		if packet.Timestamp != 90000 {
			got <- "incorrect RTP timestamp"
			return
		}
		receivedSSRC <- uint32(track.SSRC())
		got <- track.Codec().MimeType
	})
	if err := receiver.SetRemoteDescription(result.Offer); err != nil {
		t.Fatal(err)
	}
	answer, err := receiver.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gather := webrtc.GatheringCompletePromise(receiver)
	if err := receiver.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	select {
	case <-gather:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	payload, err := json.Marshal(receiver.LocalDescription())
	if err != nil {
		t.Fatal(err)
	}
	answerRequest := httptest.NewRequest(http.MethodPost, "/answer/"+result.ID, bytes.NewReader(payload))
	answerRequest.SetPathValue("id", result.ID)
	answerResponse := httptest.NewRecorder()
	b.answer(answerResponse, answerRequest)
	if answerResponse.Code != http.StatusNoContent {
		t.Fatalf("answer: %s", answerResponse.Body.String())
	}

	frame := []byte{0, 0, 0, 1, 0x65, 0xaa, 0xbb}
	header := make([]byte, 8)
	binary.BigEndian.PutUint32(header[:4], uint32(len(frame)))
	binary.BigEndian.PutUint32(header[4:], 90000)
	ticks := time.NewTicker(75 * time.Millisecond)
	defer ticks.Stop()
	for {
		select {
		case codec := <-got:
			if !strings.EqualFold(codec, webrtc.MimeTypeH264) {
				t.Fatalf("received %s", codec)
			}
			select {
			case <-keyFrameRequests:
			case <-ctx.Done():
				t.Fatal("no key frame requested when the viewer connected")
			}
			if err := receiver.WriteRTCP([]rtcp.Packet{
				&rtcp.PictureLossIndication{MediaSSRC: <-receivedSSRC},
			}); err != nil {
				t.Fatal(err)
			}
			select {
			case <-keyFrameRequests:
			case <-ctx.Done():
				t.Fatal("the relay ignored the viewer's picture loss indication")
			}
			var channel *webrtc.DataChannel
			select {
			case channel = <-cursorChannel:
			case <-ctx.Done():
				t.Fatal("the receiver did not open the cursor data channel")
			}
			if channel.Ordered() || channel.MaxRetransmits() == nil || *channel.MaxRetransmits() != 0 {
				t.Fatal("cursor data channel must avoid ordering and retransmission")
			}
			if cursor.setReady("stale-viewer", true) || !cursor.setReady(result.ID, true) {
				t.Fatal("cursor readiness must belong to the active viewer")
			}
			socket, err := net.DialUDP("udp4", nil, cursor.socket.LocalAddr().(*net.UDPAddr))
			if err != nil {
				t.Fatal(err)
			}
			defer socket.Close()
			want := []byte{3, 0, 0, 0, 1, 0, 64, 0, 127}
			for {
				if _, err := socket.Write(want); err != nil {
					t.Fatal(err)
				}
				select {
				case got := <-cursorMessages:
					if !bytes.Equal(got, want) {
						t.Fatalf("cursor packet = %v, want %v", got, want)
					}
					return
				case <-ticks.C:
					// The cursor channel deliberately sends unreliable messages.
				case <-ctx.Done():
					t.Fatal("the cursor packet did not reach the viewer")
				}
			}
		case <-ticks.C:
			err := b.forward(bytes.NewReader(append(header[:8:8], frame...)))
			if !errors.Is(err, io.EOF) {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("receiver did not get H.264 over WebRTC")
		}
	}
}

func TestRelayTimingOnlyAppearsWithTimingDetails(t *testing.T) {
	b := &bridge{}
	now := time.Now()
	b.timing.record(now.Add(-time.Millisecond), now)
	b.timing.record(now.Add(-3*time.Millisecond), now)
	b.timing.record(now.Add(-6*time.Second), now.Add(-5*time.Second))

	basic := []byte(`{"enabled":true}`)
	if got := b.addRelayTiming(basic); !bytes.Equal(got, basic) {
		t.Fatalf("timing leaked into basic stats: %s", got)
	}
	var stats struct {
		RelayTiming timingSummary `json:"relayTiming"`
	}
	err := json.Unmarshal(b.addRelayTiming([]byte(`{"enabled":true,"timings":{"peakLimit":"off"}}`)), &stats)
	if err != nil || stats.RelayTiming != (timingSummary{P50: 1, P95: 3, Samples: 2}) {
		t.Fatalf("unexpected relay timing: %+v, error: %v", stats, err)
	}
}
