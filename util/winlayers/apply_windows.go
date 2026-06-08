//go:build windows

package winlayers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/Microsoft/go-winio"
	"github.com/Microsoft/go-winio/vhd"
	"github.com/Microsoft/hcsshim/computestorage"
	"github.com/Microsoft/hcsshim/pkg/ociwclayer"
	"github.com/containerd/containerd/v2/core/mount"
	"github.com/moby/buildkit/util/bklog"
	"golang.org/x/sys/windows"
)

// importLinuxLayerAsWindows wraps a Linux tar stream with Windows layer
// structure and imports it via HCS (Host Compute Service). This creates
// a proper Windows container layer with all required metadata (VHDs,
// layer identity, etc.) so the layer can be mounted and used by the
// Windows snapshotter.
func importLinuxLayerAsWindows(ctx context.Context, snapshotDir string, wrappedTar io.Reader, parentPaths []string) (int64, error) {
	// ImportLayerFromTar uses safefile.OpenRelative with FILE_CREATE which
	// fails if directories already exist. The snapshotter's Prepare may
	// pre-create Files/ or Hives/, so remove them before importing.
	for _, name := range []string{"Files", "Hives"} {
		if err := os.RemoveAll(filepath.Join(snapshotDir, name)); err != nil {
			return 0, fmt.Errorf("failed to clean %s before import: %w", name, err)
		}
	}

	// Enable privileges at the process level rather than thread level.
	// ProcessBaseLayer (called internally by ImportLayerFromTar) uses
	// vmcompute.dll syscalls that check the process token, not the
	// thread impersonation token that RunWithPrivileges sets.
	requiredPrivileges := []string{winio.SeBackupPrivilege, winio.SeRestorePrivilege, winio.SeSecurityPrivilege}
	if err := winio.EnableProcessPrivileges(requiredPrivileges); err != nil {
		return 0, fmt.Errorf("failed to enable required privileges: %w", err)
	}
	defer winio.DisableProcessPrivileges(requiredPrivileges)

	size, err := ociwclayer.ImportLayerFromTar(ctx, wrappedTar, snapshotDir, parentPaths)
	if err != nil {
		// ProcessBaseLayer may fail with "Access is denied" when processing
		// Linux layers (empty Hives/, no Windows registry). It creates an
		// unformatted blank-base.vhdx before failing. We need to replace it
		// with properly formatted VHDs so the Windows snapshotter can mount.
		if isProcessBaseLayerError(err) && hasFilesDir(snapshotDir) {
			bklog.G(ctx).Debugf("ProcessBaseLayer failed (expected for Linux content): %v; creating formatted VHDs", err)
			if err := createLayerVhds(ctx, snapshotDir); err != nil {
				return 0, fmt.Errorf("failed to create layer VHDs after ProcessBaseLayer failure: %w", err)
			}
			if err := writeCrossOSMarker(snapshotDir); err != nil {
				return 0, fmt.Errorf("failed to write cross-OS marker: %w", err)
			}
			return size, nil
		}
		return 0, err
	}
	if err := writeCrossOSMarker(snapshotDir); err != nil {
		return 0, fmt.Errorf("failed to write cross-OS marker: %w", err)
	}
	return size, nil
}

// crossOSLinuxMarker is the filename written into a snapshot directory to
// signal that the layer stores Linux content wrapped into the Windows
// Files/+Hives/+VHDs layout. The Windows BuildKit localmounter uses this
// marker to bypass HCS when mounting the layer for reads, because HCS
// PrepareLayer on a Linux-content layer requires Hyper-V backing that
// hosted Windows runners do not have.
//
// The file lives alongside Files/, Hives/, Layout and the VHDs; the
// Windows snapshotter and HCS only look at those known names, so the
// marker is invisible to them.
const crossOSLinuxMarker = ".cross-os-linux"

// writeCrossOSMarker stamps the snapshot dir so that consumers can
// distinguish a cross-OS Linux source layer from a native Windows layer.
func writeCrossOSMarker(snapshotDir string) error {
	return os.WriteFile(filepath.Join(snapshotDir, crossOSLinuxMarker), nil, 0o644)
}

// isProcessBaseLayerError checks if the error is from ProcessBaseLayer.
func isProcessBaseLayerError(err error) bool {
	return strings.Contains(err.Error(), "ProcessBaseLayer")
}

// hasFilesDir checks if the Files/ directory exists in the snapshot.
func hasFilesDir(snapshotDir string) bool {
	_, err := os.Stat(filepath.Join(snapshotDir, "Files"))
	return err == nil
}

// createLayerVhds creates properly formatted blank-base.vhdx and blank.vhdx
// for a layer where ProcessBaseLayer failed. This replaces any partial VHDs
// left behind by the failed ProcessBaseLayer call.
//
// Uses native Windows storage APIs (virtdisk.dll + computestorage.dll) so
// the host does not need the Hyper-V feature installed. The previous
// PowerShell + Hyper-V cmdlet path silently produced unformatted VHDs on
// hosts where the hypervisor is not enabled (e.g. GitHub-hosted runners).
func createLayerVhds(ctx context.Context, snapshotDir string) error {
	const (
		vhdSizeBytes  = uint64(1) << 30 // 1 GiB
		vhdBlockBytes = uint32(1) << 20 // 1 MiB
	)
	baseVhd := filepath.Join(snapshotDir, "blank-base.vhdx")
	diffVhd := filepath.Join(snapshotDir, "blank.vhdx")

	// Remove any partial VHDs left behind by the failed ProcessBaseLayer.
	if err := os.RemoveAll(baseVhd); err != nil {
		return fmt.Errorf("failed to remove stale base vhd: %w", err)
	}
	if err := os.RemoveAll(diffVhd); err != nil {
		return fmt.Errorf("failed to remove stale diff vhd: %w", err)
	}

	createParams := &vhd.CreateVirtualDiskParameters{
		Version: 2,
		Version2: vhd.CreateVersion2{
			MaximumSize:      vhdSizeBytes,
			BlockSizeInBytes: vhdBlockBytes,
		},
	}
	handle, err := vhd.CreateVirtualDisk(baseVhd, vhd.VirtualDiskAccessNone, vhd.CreateVirtualDiskFlagNone, createParams)
	if err != nil {
		return fmt.Errorf("failed to create base vhdx %s: %w", baseVhd, err)
	}
	closed := false
	defer func() {
		if !closed {
			_ = syscall.CloseHandle(handle)
		}
	}()

	if err := computestorage.FormatWritableLayerVhd(ctx, windows.Handle(handle)); err != nil {
		os.Remove(baseVhd)
		// CFA silently blocks raw VHD sector writes; surface a hint
		// because the underlying ACCESS_DENIED is otherwise opaque.
		if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			return fmt.Errorf("failed to format base vhdx %s: %w\n"+
				"NOTE: ACCESS_DENIED from HcsFormatWritableLayerVhd is almost always Windows Defender "+
				"Controlled Folder Access blocking raw VHD sector writes. Allow-list BOTH "+
				"buildkitd.exe AND containerd.exe (and restart each) with:\n"+
				"  Add-MpPreference -ControlledFolderAccessAllowedApplications <path-to-exe>",
				baseVhd, err)
		}
		return fmt.Errorf("failed to format base vhdx %s: %w", baseVhd, err)
	}
	if err := syscall.CloseHandle(handle); err != nil {
		os.Remove(baseVhd)
		return fmt.Errorf("failed to close base vhdx handle: %w", err)
	}
	closed = true

	if err := vhd.CreateDiffVhd(diffVhd, baseVhd, vhdBlockBytes/(1024*1024)); err != nil {
		os.Remove(baseVhd)
		return fmt.Errorf("failed to create differencing vhdx %s: %w", diffVhd, err)
	}
	return nil
}

// getParentLayerPaths extracts parent layer paths from Windows mount options.
func getParentLayerPaths(mounts []mount.Mount) []string {
	for _, m := range mounts {
		for _, opt := range m.Options {
			if after, ok := strings.CutPrefix(opt, "parentLayerPaths="); ok {
				var paths []string
				if err := json.Unmarshal([]byte(after), &paths); err == nil {
					return paths
				}
			}
		}
	}
	return nil
}
