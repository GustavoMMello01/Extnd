package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestH264OverWebRTC(t *testing.T) {
	b, err := newBridge("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
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
			return
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
