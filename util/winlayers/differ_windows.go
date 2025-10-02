package winlayers

import (
	"github.com/Microsoft/go-winio"
	"github.com/containerd/containerd/v2/pkg/archive"
	"context"
	"io"
)

// writeDiffWithPrivileges executes archive.WriteDiff with elevated Windows privileges
// to access special directories like "System Volume Information"
func writeDiffWithPrivileges(ctx context.Context, w io.Writer, lowerRoot, upperRoot string) error {
	// Windows filesystem may contain special files and directories like
	// "System Volume Information" that require elevated privileges to access.
	// Use the same privilege elevation pattern as other Windows export operations.
	return winio.RunWithPrivileges([]string{winio.SeBackupPrivilege}, func() error {
		return archive.WriteDiff(ctx, w, lowerRoot, upperRoot)
	})
}
