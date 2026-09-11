package snapshot

import (
	"testing"
	"time"
)

func TestWindowsLayerMountRetryDelay(t *testing.T) {
	expected := []time.Duration{
		50 * time.Millisecond,
		100 * time.Millisecond,
		200 * time.Millisecond,
		400 * time.Millisecond,
		800 * time.Millisecond,
		time.Second,
		time.Second,
		time.Second,
	}
	for attempt, want := range expected {
		if got := windowsLayerMountRetryDelay(attempt); got != want {
			t.Fatalf("attempt %d: expected %s, got %s", attempt, want, got)
		}
	}
}
