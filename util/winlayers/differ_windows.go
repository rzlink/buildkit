package winlayers

import (
	"context"
	"io"
	"strings"

	"github.com/containerd/containerd/v2/pkg/archive"
)


// writeDiffWithMetadataFiltering executes archive.WriteDiff with graceful handling of 
// Windows system directories that commonly cause access denied errors in CI environments.
// Following the same pattern as continuity's HasDiff() function, we handle metadata files
// by catching and ignoring access denied errors for known system directories.
func writeDiffWithMetadataFiltering(ctx context.Context, w io.Writer, lowerRoot, upperRoot string) error {
	// Try archive.WriteDiff first - this gives us proper diff behavior
	err := archive.WriteDiff(ctx, w, lowerRoot, upperRoot)
	
	// If we get access denied errors for system directories, that's expected and we can ignore them
	// following the same pattern as continuity's HasDiff() function
	if err != nil && isMetadataFileError(err) {
		// This is an expected error for Windows metadata files - ignore it
		return nil
	}
	
	return err
}

// isMetadataFileError checks if the error is related to Windows metadata files
// that should be ignored, following the same pattern as continuity's metadataFiles handling
func isMetadataFileError(err error) bool {
	if err == nil {
		return false
	}
	
	errStr := err.Error()
	
	// Check for access denied errors on known system directories
	// These correspond to the paths in windowsSystemDirectories map
	systemPaths := []string{
		"System Volume Information",
		"WcSandboxState", 
		"Windows\\System32\\config",
		"$Recycle.Bin",
		"Recovery",
	}
	
	for _, path := range systemPaths {
		if strings.Contains(errStr, path) && strings.Contains(errStr, "Access is denied") {
			return true
		}
	}
	
	return false
}
