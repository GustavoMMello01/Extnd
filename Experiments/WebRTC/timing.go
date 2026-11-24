package main

import (
	"sort"
	"sync"
	"time"
)

type timingSample struct {
	at time.Time
	ms float64
}

type relayTiming struct {
	mu    sync.Mutex
	ring  [240]timingSample
	index int
}

type timingSummary struct {
	P50     float64 `json:"p50"`
	P95     float64 `json:"p95"`
	Samples int     `json:"samples"`
}

func (t *relayTiming) record(start, end time.Time) {
	t.mu.Lock()
	t.ring[t.index] = timingSample{at: end, ms: end.Sub(start).Seconds() * 1000}
	t.index = (t.index + 1) % len(t.ring)
	t.mu.Unlock()
}

func (t *relayTiming) summarize(now time.Time) *timingSummary {
	cutoff := now.Add(-4 * time.Second)
	values := make([]float64, 0, len(t.ring))
	t.mu.Lock()
	for _, sample := range t.ring {
		if !sample.at.Before(cutoff) {
			values = append(values, sample.ms)
		}
	}
	t.mu.Unlock()
	if len(values) == 0 {
		return nil
	}
	sort.Float64s(values)
	return &timingSummary{
		P50:     values[(len(values)-1)/2],
		P95:     values[(95*len(values)+99)/100-1],
		Samples: len(values),
	}
}
