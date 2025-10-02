//go:build !windows

package winlayers

import (
	"github.com/containerd/containerd/v2/pkg/archive"
	"context"
	"io"
)

// writeDiffWithPrivileges executes archive.WriteDiff without special privileges
// on non-Windows platforms where Windows-specific privileges are not needed
func writeDiffWithPrivileges(ctx context.Context, w io.Writer, lowerRoot, upperRoot string) error {
	return archive.WriteDiff(ctx, w, lowerRoot, upperRoot)
}
