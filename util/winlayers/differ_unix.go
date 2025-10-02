//go:build !windows

package winlayers

import (
	"github.com/containerd/containerd/v2/pkg/archive"
	"context"
	"io"
)

// writeDiffWithMetadataFiltering executes archive.WriteDiff without special handling
// on non-Windows platforms where Windows-specific metadata file filtering is not needed
func writeDiffWithMetadataFiltering(ctx context.Context, w io.Writer, lowerRoot, upperRoot string) error {
	return archive.WriteDiff(ctx, w, lowerRoot, upperRoot)
}
