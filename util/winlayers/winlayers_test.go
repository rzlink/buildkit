package winlayers

import (
	"archive/tar"
	"bytes"
	"context"
	"io"
	"runtime"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestContextAPI(t *testing.T) {
	ctx := context.Background()

	// No layer OS set
	assert.Equal(t, "", GetLayerOS(ctx))
	assert.False(t, needsTransformation(ctx))

	// Set Windows layer OS
	ctxWin := SetLayerOS(ctx, "windows")
	assert.Equal(t, "windows", GetLayerOS(ctxWin))

	// UseWindowsLayerMode backward compatibility
	ctxCompat := UseWindowsLayerMode(ctx)
	assert.Equal(t, "windows", GetLayerOS(ctxCompat))

	// Set Linux layer OS
	ctxLinux := SetLayerOS(ctx, "linux")
	assert.Equal(t, "linux", GetLayerOS(ctxLinux))

	// hasWindowsLayerMode: true only on non-Windows host
	if runtime.GOOS != "windows" {
		assert.True(t, hasWindowsLayerMode(ctxWin))
		assert.False(t, hasLinuxLayerMode(ctxWin))
		assert.True(t, needsTransformation(ctxWin))

		assert.False(t, hasWindowsLayerMode(ctxLinux))
		assert.False(t, hasLinuxLayerMode(ctxLinux))
		// On Linux host, "linux" layer doesn't need transformation
		assert.False(t, needsTransformation(ctxLinux))
	}
}

// makeTar creates a tar archive from the given entries.
func makeTar(t *testing.T, entries []tarEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range entries {
		err := tw.WriteHeader(e.header)
		require.NoError(t, err)
		if len(e.data) > 0 {
			_, err = tw.Write(e.data)
			require.NoError(t, err)
		}
	}
	require.NoError(t, tw.Close())
	return buf.Bytes()
}

type tarEntry struct {
	header *tar.Header
	data   []byte
}

// readTar reads all entries from a tar archive.
func readTar(t *testing.T, r io.Reader) []tarEntry {
	t.Helper()
	tr := tar.NewReader(r)
	var entries []tarEntry
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		require.NoError(t, err)
		var data []byte
		if h.Size > 0 {
			data, err = io.ReadAll(tr)
			require.NoError(t, err)
		}
		entries = append(entries, tarEntry{header: h, data: data})
	}
	return entries
}

func TestFilterStripFilesPrefix(t *testing.T) {
	// Create a Windows-format tar with Hives/ and Files/ directories
	windowsTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "Hives", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Hives/registry", Typeflag: tar.TypeReg, Size: 4}, data: []byte("data")},
		{header: &tar.Header{Name: "Files", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Files/bin", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Files/bin/sh", Typeflag: tar.TypeReg, Size: 7}, data: []byte("shellsh")},
		{header: &tar.Header{Name: "Files/etc", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Files/link", Typeflag: tar.TypeSymlink, Linkname: "Files/bin/sh"}},
	})

	// Use the filter function to strip Files/ prefix (same as applyWindowsLayer logic)
	r, discard := filter(bytes.NewReader(windowsTar), func(hdr *tar.Header) bool {
		if after, ok := cutPrefix(hdr.Name, "Files/"); ok {
			hdr.Name = after
			hdr.Linkname = trimPrefix(hdr.Linkname, "Files/")
			return true
		}
		return false
	})
	defer discard(nil)

	entries := readTar(t, r)

	// Should only have Files/ entries with prefix stripped
	require.Len(t, entries, 4) // bin, bin/sh, etc, link
	assert.Equal(t, "bin", entries[0].header.Name)
	assert.Equal(t, "bin/sh", entries[1].header.Name)
	assert.Equal(t, []byte("shellsh"), entries[1].data)
	assert.Equal(t, "etc", entries[2].header.Name)
	assert.Equal(t, "link", entries[3].header.Name)
	assert.Equal(t, "bin/sh", entries[3].header.Linkname)
}

// cutPrefix/trimPrefix are local helpers matching strings package behavior,
// used to avoid adding strings import just for tests.
func cutPrefix(s, prefix string) (string, bool) {
	if len(s) >= len(prefix) && s[:len(prefix)] == prefix {
		return s[len(prefix):], true
	}
	return s, false
}

func trimPrefix(s, prefix string) string {
	if after, ok := cutPrefix(s, prefix); ok {
		return after
	}
	return s
}

func TestWrapLinuxToWindows(t *testing.T) {
	// Create a Linux-format tar
	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "bin", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "bin/sh", Typeflag: tar.TypeReg, Size: 7}, data: []byte("shellsh")},
		{header: &tar.Header{Name: "etc", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "lib", Typeflag: tar.TypeSymlink, Linkname: "usr/lib"}},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	<-done

	// Should have: Hives/ dir, Files/ dir, then wrapped entries
	require.True(t, len(entries) >= 6, "expected at least 6 entries, got %d", len(entries))

	assert.Equal(t, "Hives", entries[0].header.Name)
	assert.Equal(t, byte(tar.TypeDir), entries[0].header.Typeflag)

	assert.Equal(t, "Files", entries[1].header.Name)
	assert.Equal(t, byte(tar.TypeDir), entries[1].header.Typeflag)

	assert.Equal(t, "Files/bin", entries[2].header.Name)
	assert.Equal(t, byte(tar.TypeDir), entries[2].header.Typeflag)

	assert.Equal(t, "Files/bin/sh", entries[3].header.Name)
	assert.Equal(t, []byte("shellsh"), entries[3].data)

	assert.Equal(t, "Files/etc", entries[4].header.Name)

	assert.Equal(t, "Files/lib", entries[5].header.Name)
	assert.Equal(t, "Files/usr/lib", entries[5].header.Linkname)

	// Check Windows-specific PAX records were added
	for _, e := range entries {
		h := e.header
		if h.Typeflag == tar.TypeDir {
			assert.Contains(t, h.PAXRecords, keyFileAttr, "entry %s missing fileattr", h.Name)
			if h.Name != "Hives" && h.Name != "Files" {
				assert.Contains(t, h.PAXRecords, keySDRaw, "entry %s missing security descriptor", h.Name)
			}
		}
		if h.Typeflag == tar.TypeReg {
			assert.Contains(t, h.PAXRecords, keyFileAttr, "entry %s missing fileattr", h.Name)
			assert.Contains(t, h.PAXRecords, keySDRaw, "entry %s missing security descriptor", h.Name)
		}
	}
}

func TestStripWindowsLayer(t *testing.T) {
	// Create a Windows-format tar
	windowsTar := makeTar(t, []tarEntry{
		{header: &tar.Header{
			Name:       "Hives",
			Typeflag:   tar.TypeDir,
			PAXRecords: map[string]string{keyFileAttr: "16"},
		}},
		{header: &tar.Header{
			Name:       "Files",
			Typeflag:   tar.TypeDir,
			PAXRecords: map[string]string{keyFileAttr: "16"},
		}},
		{header: &tar.Header{
			Name:       "Files/bin",
			Typeflag:   tar.TypeDir,
			PAXRecords: map[string]string{keyFileAttr: "16", keySDRaw: "abc"},
		}},
		{header: &tar.Header{
			Name:       "Files/bin/sh",
			Typeflag:   tar.TypeReg,
			Size:       7,
			PAXRecords: map[string]string{keyFileAttr: "32", keySDRaw: "def", keyCreationTime: "123.456"},
		}, data: []byte("shellsh")},
		{header: &tar.Header{
			Name:     "Files/link",
			Typeflag: tar.TypeSymlink,
			Linkname: "Files/bin/sh",
		}},
	})

	ctx := context.Background()
	var outBuf bytes.Buffer
	w, _, done := stripWindowsLayer(ctx, &outBuf)

	_, err := io.Copy(w, bytes.NewReader(windowsTar))
	require.NoError(t, err)

	require.NoError(t, <-done)

	entries := readTar(t, &outBuf)

	// Should have only the Files/ entries with prefix stripped, Hives/ discarded
	require.Len(t, entries, 3) // bin, bin/sh, link
	assert.Equal(t, "bin", entries[0].header.Name)
	assert.Equal(t, "bin/sh", entries[1].header.Name)
	assert.Equal(t, []byte("shellsh"), entries[1].data)
	assert.Equal(t, "link", entries[2].header.Name)
	assert.Equal(t, "bin/sh", entries[2].header.Linkname)

	// Verify Windows-specific PAX records were removed
	for _, e := range entries {
		assert.NotContains(t, e.header.PAXRecords, keyFileAttr, "entry %s should not have fileattr", e.header.Name)
		assert.NotContains(t, e.header.PAXRecords, keySDRaw, "entry %s should not have security descriptor", e.header.Name)
		assert.NotContains(t, e.header.PAXRecords, keyCreationTime, "entry %s should not have creation time", e.header.Name)
	}
}

func TestRoundTripLinuxToWindowsAndBack(t *testing.T) {
	// Start with a Linux tar
	originalEntries := []tarEntry{
		{header: &tar.Header{Name: "bin", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "bin/sh", Typeflag: tar.TypeReg, Size: 7}, data: []byte("shellsh")},
		{header: &tar.Header{Name: "etc", Typeflag: tar.TypeDir}},
	}
	linuxTar := makeTar(t, originalEntries)
	ctx := context.Background()

	// Linux → Windows
	winR, winDiscard, winDone := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))
	var winBuf bytes.Buffer
	_, err := io.Copy(&winBuf, winR)
	require.NoError(t, err)
	winDiscard(nil)
	<-winDone

	// Windows → Linux (via stripWindowsLayer)
	var linuxBuf bytes.Buffer
	linuxW, _, linuxDone := stripWindowsLayer(ctx, &linuxBuf)

	_, err = io.Copy(linuxW, &winBuf)
	require.NoError(t, err)
	require.NoError(t, <-linuxDone)

	resultEntries := readTar(t, &linuxBuf)

	// Verify round-trip preserves the original entries
	require.Len(t, resultEntries, len(originalEntries))
	for i, orig := range originalEntries {
		result := resultEntries[i]
		assert.Equal(t, orig.header.Name, result.header.Name)
		assert.Equal(t, orig.header.Typeflag, result.header.Typeflag)
		assert.Equal(t, orig.data, result.data)
	}
}
