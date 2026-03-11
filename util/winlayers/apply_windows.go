//go:build windows

package winlayers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Microsoft/go-winio"
	"github.com/Microsoft/hcsshim/pkg/ociwclayer"
	"github.com/containerd/containerd/v2/core/mount"
	"github.com/moby/buildkit/util/bklog"
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
		p := filepath.Join(snapshotDir, name)
		if err := os.RemoveAll(p); err != nil {
			return 0, fmt.Errorf("failed to clean %s before import: %w", p, err)
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
			bklog.G(ctx).Warnf("ProcessBaseLayer failed (expected for Linux content): %v; creating formatted VHDs", err)
			if err := createLayerVhds(ctx, snapshotDir); err != nil {
				return 0, fmt.Errorf("failed to create layer VHDs after ProcessBaseLayer failure: %w", err)
			}
			return size, nil
		}
		return 0, err
	}
	return size, nil
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
// Uses PowerShell/Hyper-V cmdlets to create and format VHDs, as the HCS
// FormatWritableLayerVhd API may return "Access is denied" in contexts
// where buildkitd runs.
func createLayerVhds(ctx context.Context, snapshotDir string) error {
	baseVhd := filepath.Join(snapshotDir, "blank-base.vhdx")
	diffVhd := filepath.Join(snapshotDir, "blank.vhdx")

	// Remove any partial VHDs from the failed ProcessBaseLayer.
	os.Remove(baseVhd)
	os.Remove(diffVhd)

	// Create a formatted base VHD and differencing disk via PowerShell.
	// This avoids the HCS FormatWritableLayerVhd API which may fail with
	// "Access is denied" depending on the caller's context.
	script := fmt.Sprintf(
		`$ErrorActionPreference='Stop';`+
			`New-VHD -Path '%s' -SizeBytes 1GB -Dynamic -BlockSizeBytes 1MB | Out-Null;`+
			`$d=Mount-VHD -Path '%s' -Passthru|Get-Disk;`+
			`Initialize-Disk -Number $d.Number -PartitionStyle GPT;`+
			`$p=New-Partition -DiskNumber $d.Number -UseMaximumSize;`+
			`Format-Volume -Partition $p -FileSystem NTFS -Force -Confirm:$false|Out-Null;`+
			`Dismount-VHD -Path '%s';`+
			`New-VHD -Path '%s' -ParentPath '%s' -Differencing|Out-Null`,
		baseVhd, baseVhd, baseVhd, diffVhd, baseVhd,
	)

	cmd := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("VHD creation failed: %w\noutput: %s", err, string(out))
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
