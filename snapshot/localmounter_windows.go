package snapshot

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Microsoft/go-winio/pkg/bindfilter"
	"github.com/containerd/containerd/v2/core/mount"
	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/buildkit/util/bklog"
	"github.com/moby/locker"
	"github.com/pkg/errors"
	"golang.org/x/sys/windows"
)

var windowsMountDiagnosticMu sync.Mutex
var windowsSharingViolationCaptureOnce sync.Once
var windowsLayerOperationLocker = locker.New()

type windowsMountDiagnosticEvent struct {
	Timestamp   time.Time `json:"timestamp"`
	Event       string    `json:"event"`
	PID         int       `json:"pid"`
	Source      string    `json:"source"`
	Target      string    `json:"target"`
	Type        string    `json:"type"`
	ReadOnly    bool      `json:"readOnly"`
	ParentPaths []string  `json:"parentPaths,omitempty"`
	Attempt     int       `json:"attempt,omitempty"`
	ElapsedMS   int64     `json:"elapsedMs,omitempty"`
	Error       string    `json:"error,omitempty"`
}

func (lm *localMounter) Mount() (string, error) {
	lm.mu.Lock()
	defer lm.mu.Unlock()

	if lm.target != "" {
		return lm.target, nil
	}

	if lm.mounts == nil && lm.mountable != nil {
		mounts, release, err := lm.mountable.Mount()
		if err != nil {
			return "", err
		}
		lm.mounts = mounts
		lm.release = release
	}

	// Windows can only mount a single mount at a given location.
	// Parent layers are carried in Options, opaquely to localMounter.
	if len(lm.mounts) != 1 {
		return "", errors.Wrapf(cerrdefs.ErrNotImplemented, "request to mount %d layers, only 1 is supported", len(lm.mounts))
	}

	m := lm.mounts[0]
	dir, err := os.MkdirTemp("", "buildkit-mount")
	if err != nil {
		return "", errors.Wrap(err, "failed to create temp dir")
	}

	if m.Type == "bind" || m.Type == "rbind" {
		if !m.ReadOnly() {
			// This is a rw bind mount, we can simply return the source.
			// NOTE(gabriel-samfira): This is safe to do if the source of the bind mount is a DOS path
			// of a local folder. If it's a \\?\Volume{} (for any reason that I can't think of now)
			// we should allow bindfilter.ApplyFileBinding() to mount it.
			return m.Source, nil
		}
		// The Windows snapshotter does not have any notion of bind mounts. We emulate
		// bind mounts here using the bind filter.
		if err := bindfilter.ApplyFileBinding(dir, m.Source, m.ReadOnly()); err != nil {
			return "", errors.Wrapf(err, "failed to mount %v", m)
		}
	} else {
		// see https://github.com/moby/buildkit/issues/5807
		// if it's a race condition issue, do max 2 retries with some backoff
		// should adjust the retries if this persists but 1 retry
		// seems to be enough.
		lm.lockWindowsLayer(m, dir)
		if err := mountWithRetries(m, dir, 2); err != nil {
			lm.unlockWindowsLayer(m, dir)
			return "", errors.Wrapf(err, "failed to mount %v", m)
		}
	}

	lm.target = dir
	return lm.target, nil
}

func mountWithRetries(m mount.Mount, dir string, retries int) error {
	errStr := "cannot access the file because it is being used by another process"
	backoff := 30 * time.Millisecond
	started := time.Now()
	var err error

	for i := range retries + 1 {
		// i = 0 is first call and not a retry
		writeWindowsMountDiagnostic("mount-attempt", m, dir, i+1, time.Since(started), nil)
		err = m.Mount(dir)
		writeWindowsMountDiagnostic("mount-result", m, dir, i+1, time.Since(started), err)
		if err == nil || i == retries {
			return err
		}
		if strings.Contains(err.Error(), errStr) {
			windowsSharingViolationCaptureOnce.Do(func() {
				captureWindowsSharingViolation(m, dir, err)
			})
			time.Sleep(time.Duration(i+1) * backoff)
		} else {
			return err
		}
	}

	return err
}

func (lm *localMounter) Unmount() error {
	lm.mu.Lock()
	defer lm.mu.Unlock()

	// NOTE(gabriel-samfira): Should we just return nil if len(lm.mounts) == 0?
	// Calling Mount() would fail on an instance of the localMounter where mounts contains
	// anything other than 1 mount.
	if len(lm.mounts) != 1 {
		return errors.Wrapf(cerrdefs.ErrNotImplemented, "request to mount %d layers, only 1 is supported", len(lm.mounts))
	}
	m := lm.mounts[0]
	target := lm.target
	defer lm.unlockWindowsLayer(m, target)

	if target != "" {
		writeWindowsMountDiagnostic("unmount-start", m, target, 0, 0, nil)
		if m.Type == "bind" || m.Type == "rbind" {
			if err := bindfilter.RemoveFileBinding(target); err != nil {
				// The following two errors denote that lm.target is not a mount point.
				if !errors.Is(err, windows.ERROR_INVALID_PARAMETER) && !errors.Is(err, windows.ERROR_NOT_FOUND) {
					writeWindowsMountDiagnostic("unmount-result", m, target, 0, 0, err)
					return errors.Wrapf(err, "failed to unmount %v: %+v", target, err)
				}
			}
		} else {
			// The containerd snapshotter uses the bind filter internally to mount windows-layer
			// volumes. We use same bind filter here to emulate bind mounts. In theory we could
			// simply call mount.Unmount() here, without the extra check for bind mounts and explicit
			// call to bindfilter.RemoveFileBinding() (above), but this would operate under the
			// assumption that the internal implementation in containerd will always be based on the
			// bind filter, which feels brittle.
			if err := mount.Unmount(target, 0); err != nil {
				writeWindowsMountDiagnostic("unmount-result", m, target, 0, 0, err)
				return errors.Wrapf(err, "failed to unmount %v: %+v", target, err)
			}
		}
		writeWindowsMountDiagnostic("unmount-result", m, target, 0, 0, nil)
		os.RemoveAll(target)
		lm.target = ""
	}

	if lm.release != nil {
		writeWindowsMountDiagnostic("release-start", m, target, 0, 0, nil)
		err := lm.release()
		writeWindowsMountDiagnostic("release-result", m, target, 0, 0, err)
		return err
	}

	return nil
}

func captureWindowsSharingViolation(m mount.Mount, target string, mountErr error) {
	if os.Getenv("BUILDKIT_WINDOWS_HANDLE_CAPTURE") != "true" {
		return
	}

	dir := os.Getenv("BUILDKIT_WINDOWS_HANDLE_CAPTURE_DIR")
	handleExe := os.Getenv("BUILDKIT_WINDOWS_HANDLE_EXE")
	if dir == "" || handleExe == "" {
		return
	}

	if err := os.MkdirAll(dir, 0700); err != nil {
		bklog.G(context.TODO()).WithError(err).WithField("path", dir).Warn("failed to create Windows handle capture directory")
		return
	}

	parentPaths, parentErr := m.GetParentPaths()
	metadata := map[string]any{
		"timestamp":   time.Now().UTC(),
		"pid":         os.Getpid(),
		"source":      m.Source,
		"target":      target,
		"type":        m.Type,
		"readOnly":    m.ReadOnly(),
		"parentPaths": parentPaths,
		"mountError":  mountErr.Error(),
	}
	if parentErr != nil {
		metadata["parentPathsError"] = parentErr.Error()
	}
	writeWindowsDiagnosticJSON(filepath.Join(dir, "metadata.txt"), metadata)

	runWindowsDiagnosticCommand(dir, "handle-source.txt", handleExe, "-accepteula", "-nobanner", m.Source)
	for i, parentPath := range parentPaths {
		runWindowsDiagnosticCommand(dir, fmt.Sprintf("handle-parent-%d.txt", i+1), handleExe, "-accepteula", "-nobanner", parentPath)
	}
	runWindowsDiagnosticCommand(dir, "processes.txt", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
		"Get-Process | Sort-Object ProcessName | Select-Object Id,ProcessName,Path,StartTime | Format-List | Out-String -Width 4096")
	runWindowsDiagnosticCommand(dir, "filter-drivers.txt", "fltmc.exe", "filters")
	runWindowsDiagnosticCommand(dir, "filter-instances.txt", "fltmc.exe", "instances")
	runWindowsDiagnosticCommand(dir, "defender-status.txt", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
		"Get-MpComputerStatus | Format-List * | Out-String -Width 4096; Get-MpPreference | Format-List * | Out-String -Width 4096")
	runWindowsDiagnosticCommand(dir, "events.txt", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", `
$start = (Get-Date).AddMinutes(-5)
$logs = @(
  'Microsoft-Windows-Hyper-V-Compute-Admin',
  'Microsoft-Windows-Containers-Wcifs/Operational',
  'Microsoft-Windows-Windows Defender/Operational',
  'System'
)
foreach ($log in $logs) {
  "===== $log ====="
  try {
    Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$start} -ErrorAction Stop |
      Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message |
      Format-List | Out-String -Width 4096
  } catch {
    "capture-error: $($_.Exception.Message)"
  }
}
`)
}

func (lm *localMounter) lockWindowsLayer(m mount.Mount, target string) {
	if m.Type != "windows-layer" || os.Getenv("BUILDKIT_WINDOWS_LAYER_OPERATION_LOCK") != "true" {
		return
	}

	key := strings.ToLower(filepath.Clean(m.Source))
	started := time.Now()
	writeWindowsMountDiagnostic("layer-operation-lock-wait", m, target, 0, 0, nil)
	windowsLayerOperationLocker.Lock(key)
	writeWindowsMountDiagnostic("layer-operation-lock-acquired", m, target, 0, time.Since(started), nil)
	lm.layerLockKey = key
}

func (lm *localMounter) unlockWindowsLayer(m mount.Mount, target string) {
	if lm.layerLockKey == "" {
		return
	}

	key := lm.layerLockKey
	lm.layerLockKey = ""
	unlockErr := windowsLayerOperationLocker.Unlock(key)
	writeWindowsMountDiagnostic("layer-operation-lock-released", m, target, 0, 0, unlockErr)
	if unlockErr != nil {
		bklog.G(context.TODO()).WithError(unlockErr).WithField("source", m.Source).Warn("failed to unlock Windows layer operation")
	}
}

func runWindowsDiagnosticCommand(dir, name, command string, args ...string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, command, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		output = append(output, []byte(fmt.Sprintf("\ncommand-error: %v\n", err))...)
	}
	if ctx.Err() != nil {
		output = append(output, []byte(fmt.Sprintf("context-error: %v\n", ctx.Err()))...)
	}

	path := filepath.Join(dir, name)
	if writeErr := os.WriteFile(path, output, 0600); writeErr != nil {
		bklog.G(context.TODO()).WithError(writeErr).WithField("path", path).Warn("failed to write Windows diagnostic command output")
	}
}

func writeWindowsDiagnosticJSON(path string, value any) {
	dt, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		bklog.G(context.TODO()).WithError(err).WithField("path", path).Warn("failed to marshal Windows diagnostic metadata")
		return
	}
	if err := os.WriteFile(path, dt, 0600); err != nil {
		bklog.G(context.TODO()).WithError(err).WithField("path", path).Warn("failed to write Windows diagnostic metadata")
	}
}

func writeWindowsMountDiagnostic(event string, m mount.Mount, target string, attempt int, elapsed time.Duration, eventErr error) {
	path := os.Getenv("BUILDKIT_WINDOWS_MOUNT_DIAGNOSTIC_LOG")
	if path == "" {
		return
	}

	parentPaths, parentErr := m.GetParentPaths()
	record := windowsMountDiagnosticEvent{
		Timestamp:   time.Now().UTC(),
		Event:       event,
		PID:         os.Getpid(),
		Source:      m.Source,
		Target:      target,
		Type:        m.Type,
		ReadOnly:    m.ReadOnly(),
		ParentPaths: parentPaths,
		Attempt:     attempt,
		ElapsedMS:   elapsed.Milliseconds(),
	}
	if eventErr != nil {
		record.Error = eventErr.Error()
	}
	if parentErr != nil {
		if record.Error != "" {
			record.Error += "; "
		}
		record.Error += "failed to read parent paths: " + parentErr.Error()
	}

	dt, err := json.Marshal(record)
	if err != nil {
		bklog.G(context.TODO()).WithError(err).Warn("failed to marshal Windows mount diagnostic event")
		return
	}

	windowsMountDiagnosticMu.Lock()
	defer windowsMountDiagnosticMu.Unlock()

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		bklog.G(context.TODO()).WithError(err).WithField("path", path).Warn("failed to open Windows mount diagnostic log")
		return
	}
	defer f.Close()

	if _, err := f.Write(append(dt, '\n')); err != nil {
		bklog.G(context.TODO()).WithError(err).WithField("path", path).Warn("failed to write Windows mount diagnostic event")
	}
}
