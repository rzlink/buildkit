package snapshot

import (
	"testing"
	"time"

	"github.com/containerd/containerd/v2/core/mount"
)

func TestWindowsLayerLockSerializesSameSource(t *testing.T) {
	layer1 := mount.Mount{
		Type:   "windows-layer",
		Source: `C:\layers\Example`,
	}
	layer2 := mount.Mount{
		Type:   "windows-layer",
		Source: `c:\LAYERS\example`,
	}

	lm1 := &localMounter{}
	lm2 := &localMounter{}
	lm1.lockWindowsLayer(layer1)
	t.Cleanup(lm1.unlockWindowsLayer)

	acquired := make(chan struct{})
	go func() {
		lm2.lockWindowsLayer(layer2)
		close(acquired)
	}()

	select {
	case <-acquired:
		lm2.unlockWindowsLayer()
		t.Fatal("second lock acquired before the first local mounter released the layer")
	case <-time.After(100 * time.Millisecond):
	}

	lm1.unlockWindowsLayer()

	select {
	case <-acquired:
		lm2.unlockWindowsLayer()
	case <-time.After(5 * time.Second):
		t.Fatal("second lock did not acquire after the first local mounter released the layer")
	}
}
