package main

import (
	"bytes"
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
)

//go:embed viewer.html
var viewer []byte

const h264Format = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"

type bridge struct {
	api   *webrtc.API
	track *webrtc.TrackLocalStaticRTP
	mu    sync.Mutex
	peers map[string]*webrtc.PeerConnection
}

func main() {
	sourceFlag := flag.String("source", "", "Extnd session URL displayed in WebRTC test mode")
	flag.Parse()
	source, err := url.Parse(*sourceFlag)
	if err != nil || source.Scheme != "http" || net.ParseIP(source.Hostname()).To4() == nil ||
		source.Port() == "" || source.User != nil || source.RawQuery != "" || source.Fragment != "" ||
		len(source.Path) != 38 || source.Path[0] != '/' || source.Path[37] != '/' {
		log.Fatal("Pass the complete HTTP URL displayed by Extnd using -source.")
	}
	source = source.JoinPath("h264")

	b, err := newBridge(source.Hostname())
	if err != nil {
		log.Fatal(err)
	}
	stream, err := openFeed(source)
	if err != nil {
		log.Fatal(err)
	}
	defer stream.Close()

	listener, err := net.Listen("tcp4", net.JoinHostPort(source.Hostname(), "0"))
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := b.forward(stream); err != nil && !errors.Is(err, io.EOF) {
			log.Printf("Extnd capture ended: %v", err)
		}
		_ = listener.Close()
	}()

	path := "/" + randomID() + "/"
	mux := http.NewServeMux()
	mux.HandleFunc("GET "+path+"{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(viewer)
	})
	mux.HandleFunc("POST "+path+"offer", b.offer)
	mux.HandleFunc("POST "+path+"answer/{id}", b.answer)
	server := http.Server{
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      12 * time.Second,
		IdleTimeout:       20 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Referrer-Policy", "no-referrer")
			mux.ServeHTTP(w, r)
		}),
	}
	fmt.Printf("Open this URL in Safari on the iPad: http://%s%s\n", listener.Addr(), path)
	if err := server.Serve(listener); err != nil && !errors.Is(err, net.ErrClosed) {
		log.Fatal(err)
	}
}

func newBridge(ip string) (*bridge, error) {
	settings := webrtc.SettingEngine{}
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settings.SetIncludeLoopbackCandidate(net.ParseIP(ip).IsLoopback())
	settings.SetIPFilter(func(candidate net.IP) bool { return candidate.String() == ip })
	engine := &webrtc.MediaEngine{}
	codec := webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: h264Format,
		RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}},
	}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: codec, PayloadType: 102}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, err
	}
	track, err := webrtc.NewTrackLocalStaticRTP(codec, "display", "extnd")
	if err != nil {
		return nil, err
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(engine), webrtc.WithSettingEngine(settings))
	return &bridge{api: api, track: track, peers: make(map[string]*webrtc.PeerConnection)}, nil
}

func openFeed(source *url.URL) (io.ReadCloser, error) {
	client := http.Client{
		Transport: &http.Transport{
			DialContext:           (&net.Dialer{Timeout: 3 * time.Second}).DialContext,
			ResponseHeaderTimeout: 5 * time.Second,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get(source.String())
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK || response.Header.Get("Content-Type") != "application/octet-stream" {
		response.Body.Close()
		return nil, fmt.Errorf("Extnd did not start an H.264 feed (%s). Start a session with WebRTC test mode enabled", response.Status)
	}
	return response.Body, nil
}

func (b *bridge) forward(stream io.Reader) error {
	var header [8]byte
	packetizer := rtp.NewPacketizer(1150, 102, 0, &codecs.H264Payloader{}, rtp.NewRandomSequencer(), 90000)
	for {
		if _, err := io.ReadFull(stream, header[:]); err != nil {
			return err
		}
		length := binary.BigEndian.Uint32(header[:4])
		if length == 0 || length > 4<<20 {
			return errors.New("invalid H.264 frame length")
		}
		frame := make([]byte, length)
		if _, err := io.ReadFull(stream, frame); err != nil {
			return err
		}
		timestamp := binary.BigEndian.Uint32(header[4:])
		for _, packet := range packetizer.Packetize(frame, 0) {
			packet.Timestamp = timestamp
			if err := b.track.WriteRTP(packet); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				log.Printf("Could not write RTP packet: %v", err)
			}
		}
	}
}

func (b *bridge) offer(w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	if len(b.peers) >= 2 {
		b.mu.Unlock()
		http.Error(w, "Too many active viewers.", http.StatusServiceUnavailable)
		return
	}
	peer, err := b.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		b.mu.Unlock()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	id := randomID()
	b.peers[id] = peer
	b.mu.Unlock()
	closePeer := func() {
		b.mu.Lock()
		delete(b.peers, id)
		b.mu.Unlock()
		_ = peer.Close()
	}
	go func() {
		time.Sleep(25 * time.Second)
		if peer.ConnectionState() != webrtc.PeerConnectionStateConnected {
			closePeer()
		}
	}()
	peer.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateDisconnected:
			closePeer()
		case webrtc.PeerConnectionStateClosed:
			b.mu.Lock()
			delete(b.peers, id)
			b.mu.Unlock()
		}
	})
	err = prepareOffer(r.Context(), peer, b.track)
	if err != nil {
		closePeer()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		ID    string                     `json:"id"`
		Offer *webrtc.SessionDescription `json:"offer"`
	}{id, peer.LocalDescription()})
}

func prepareOffer(ctx context.Context, peer *webrtc.PeerConnection, track *webrtc.TrackLocalStaticRTP) error {
	transceiver, err := peer.AddTransceiverFromTrack(track, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendonly})
	if err != nil {
		return err
	}
	go func() {
		buffer := make([]byte, 1500)
		for {
			if _, _, err := transceiver.Sender().Read(buffer); err != nil {
				return
			}
		}
	}()
	offer, err := peer.CreateOffer(nil)
	if err != nil {
		return err
	}
	gathering := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(offer); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 7*time.Second)
	defer cancel()
	select {
	case <-gathering:
		if !bytes.Contains([]byte(peer.LocalDescription().SDP), []byte("a=candidate:")) {
			return errors.New("no local WebRTC candidate found")
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (b *bridge) answer(w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	peer := b.peers[r.PathValue("id")]
	b.mu.Unlock()
	if peer == nil {
		http.NotFound(w, r)
		return
	}
	var answer webrtc.SessionDescription
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&answer); err != nil ||
		answer.Type != webrtc.SDPTypeAnswer {
		http.Error(w, "Invalid WebRTC answer.", http.StatusBadRequest)
		return
	}
	if err := peer.SetRemoteDescription(answer); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func randomID() string {
	var id [16]byte
	_, _ = rand.Read(id[:])
	return hex.EncodeToString(id[:])
}
