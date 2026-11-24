package main

import (
	"net"
	"sync"

	"github.com/pion/webrtc/v4"
)

const cursorPacketSize = 9

type cursorRelay struct {
	socket  *net.UDPConn
	mu      sync.Mutex
	channel *webrtc.DataChannel
	owner   string
	ready   bool
	changes chan struct{}
}

func newCursorRelay() (*cursorRelay, error) {
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return nil, err
	}
	return &cursorRelay{socket: socket, changes: make(chan struct{}, 1)}, nil
}

func (c *cursorRelay) attach(peer *webrtc.PeerConnection, id string) (func(), error) {
	ordered, retries := false, uint16(0)
	channel, err := peer.CreateDataChannel("extnd-cursor", &webrtc.DataChannelInit{
		Ordered: &ordered, MaxRetransmits: &retries,
	})
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.channel = channel
	c.owner = id
	c.setReadyLocked(false)
	c.mu.Unlock()
	detach := func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.channel == channel {
			c.channel = nil
			c.owner = ""
			c.setReadyLocked(false)
		}
	}
	channel.OnClose(detach)
	return detach, nil
}

func (c *cursorRelay) setReady(id string, ready bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.owner != id || c.channel == nil || (ready && c.channel.ReadyState() != webrtc.DataChannelStateOpen) {
		return false
	}
	c.setReadyLocked(ready)
	return true
}

func (c *cursorRelay) setReadyLocked(ready bool) {
	if c.ready == ready {
		return
	}
	c.ready = ready
	select {
	case c.changes <- struct{}{}:
	default:
	}
}

func (c *cursorRelay) notifyCapture(apply func(bool)) {
	for range c.changes {
		c.mu.Lock()
		ready := c.ready
		c.mu.Unlock()
		apply(ready)
	}
}

func (c *cursorRelay) forward() {
	var buffer [cursorPacketSize + 1]byte
	for {
		n, _, err := c.socket.ReadFromUDP(buffer[:])
		if err != nil {
			c.mu.Lock()
			c.setReadyLocked(false)
			c.mu.Unlock()
			return
		}
		if n != cursorPacketSize {
			continue
		}
		c.mu.Lock()
		channel := c.channel
		c.mu.Unlock()
		if channel != nil && channel.ReadyState() == webrtc.DataChannelStateOpen &&
			channel.BufferedAmount() < 2*cursorPacketSize {
			_ = channel.Send(buffer[:n])
		}
	}
}
