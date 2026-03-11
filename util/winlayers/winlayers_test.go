package winlayers

import (
	"archive/tar"
	"bytes"
	"context"
	"io"
	"runtime"
	"testing"
	"time"

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

func TestContextAPIOnWindows(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows-only test")
	}
	ctx := context.Background()

	// On Windows host, "linux" layer OS means cross-platform (needs transformation)
	ctxLinux := SetLayerOS(ctx, "linux")
	assert.True(t, hasLinuxLayerMode(ctxLinux))
	assert.False(t, hasWindowsLayerMode(ctxLinux))
	assert.True(t, needsTransformation(ctxLinux))

	// On Windows host, "windows" layer OS is same-platform (no transformation)
	ctxWin := SetLayerOS(ctx, "windows")
	assert.False(t, hasWindowsLayerMode(ctxWin))
	assert.False(t, hasLinuxLayerMode(ctxWin))
	assert.False(t, needsTransformation(ctxWin))
}

func TestWrapLinuxToWindowsEmptyTar(t *testing.T) {
	emptyTar := makeTar(t, nil)
	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(emptyTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Empty Linux tar should still produce Hives/ and Files/ directories
	require.Len(t, entries, 2)
	assert.Equal(t, "Hives", entries[0].header.Name)
	assert.Equal(t, byte(tar.TypeDir), entries[0].header.Typeflag)
	assert.Equal(t, "Files", entries[1].header.Name)
	assert.Equal(t, byte(tar.TypeDir), entries[1].header.Typeflag)
}

func TestStripWindowsLayerEmptyFilesDir(t *testing.T) {
	// Windows tar with only Hives/ and Files/ dirs, no actual file entries
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
	})

	ctx := context.Background()
	var outBuf bytes.Buffer
	w, _, done := stripWindowsLayer(ctx, &outBuf)

	_, err := io.Copy(w, bytes.NewReader(windowsTar))
	require.NoError(t, err)
	require.NoError(t, <-done)

	entries := readTar(t, &outBuf)
	require.Len(t, entries, 0, "stripping a Windows tar with no Files/ children should produce empty tar")
}

func TestWrapLinuxToWindowsWhiteoutFiles(t *testing.T) {
	// OCI whiteout files (.wh.) should be preserved and prefixed
	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "etc", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "etc/.wh.resolv.conf", Typeflag: tar.TypeReg, Size: 0}},
		{header: &tar.Header{Name: "etc/.wh..wh..opq", Typeflag: tar.TypeReg, Size: 0}},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Hives/, Files/, then 3 entries
	require.Len(t, entries, 5)
	assert.Equal(t, "Files/etc", entries[2].header.Name)
	assert.Equal(t, "Files/etc/.wh.resolv.conf", entries[3].header.Name)
	assert.Equal(t, "Files/etc/.wh..wh..opq", entries[4].header.Name)
}

func TestStripWindowsLayerNoFilesEntries(t *testing.T) {
	// A tar with only Hives/ entries and no Files/ entries should produce empty output
	windowsTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "Hives", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Hives/DefaultUser_Delta", Typeflag: tar.TypeReg, Size: 8}, data: []byte("registry")},
		{header: &tar.Header{Name: "Hives/Sam_Delta", Typeflag: tar.TypeReg, Size: 3}, data: []byte("sam")},
	})

	ctx := context.Background()
	var outBuf bytes.Buffer
	w, _, done := stripWindowsLayer(ctx, &outBuf)

	_, err := io.Copy(w, bytes.NewReader(windowsTar))
	require.NoError(t, err)
	require.NoError(t, <-done)

	entries := readTar(t, &outBuf)
	require.Len(t, entries, 0, "Hives-only tar should produce empty Linux tar")
}

func TestWrapLinuxToWindowsDeeplyNested(t *testing.T) {
	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "a", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "a/b", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "a/b/c", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "a/b/c/d", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "a/b/c/d/file.txt", Typeflag: tar.TypeReg, Size: 5}, data: []byte("hello")},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Hives/, Files/, then 5 entries
	require.Len(t, entries, 7)
	assert.Equal(t, "Files/a/b/c/d/file.txt", entries[6].header.Name)
	assert.Equal(t, []byte("hello"), entries[6].data)
}

func TestWrapLinuxToWindowsSpecialChars(t *testing.T) {
	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "path with spaces", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "path with spaces/file name.txt", Typeflag: tar.TypeReg, Size: 3}, data: []byte("abc")},
		{header: &tar.Header{Name: "café", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "café/données.txt", Typeflag: tar.TypeReg, Size: 4}, data: []byte("data")},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Hives/, Files/, then 4 entries
	require.Len(t, entries, 6)
	assert.Equal(t, "Files/path with spaces", entries[2].header.Name)
	assert.Equal(t, "Files/path with spaces/file name.txt", entries[3].header.Name)
	assert.Equal(t, "Files/café", entries[4].header.Name)
	assert.Equal(t, "Files/café/données.txt", entries[5].header.Name)
}

func TestStripWindowsLayerPreservesNonWindowsPAX(t *testing.T) {
	// PAX records that aren't Windows-specific should survive stripping
	windowsTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "Hives", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "Files", Typeflag: tar.TypeDir}},
		{header: &tar.Header{
			Name:     "Files/myfile",
			Typeflag: tar.TypeReg,
			Size:     3,
			PAXRecords: map[string]string{
				keyFileAttr:        "32",
				keySDRaw:           "abc",
				keyCreationTime:    "123.456",
				"SCHILY.xattr.key": "custom-value",
			},
		}, data: []byte("abc")},
	})

	ctx := context.Background()
	var outBuf bytes.Buffer
	w, _, done := stripWindowsLayer(ctx, &outBuf)

	_, err := io.Copy(w, bytes.NewReader(windowsTar))
	require.NoError(t, err)
	require.NoError(t, <-done)

	entries := readTar(t, &outBuf)
	require.Len(t, entries, 1)
	assert.Equal(t, "myfile", entries[0].header.Name)

	// Windows-specific PAX records removed
	assert.NotContains(t, entries[0].header.PAXRecords, keyFileAttr)
	assert.NotContains(t, entries[0].header.PAXRecords, keySDRaw)
	assert.NotContains(t, entries[0].header.PAXRecords, keyCreationTime)

	// Non-Windows PAX record preserved
	assert.Equal(t, "custom-value", entries[0].header.PAXRecords["SCHILY.xattr.key"])
}

func TestRoundTripWithSymlinksAndWhiteouts(t *testing.T) {
	originalEntries := []tarEntry{
		{header: &tar.Header{Name: "bin", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "bin/sh", Typeflag: tar.TypeReg, Size: 4}, data: []byte("bash")},
		{header: &tar.Header{Name: "usr", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "usr/bin", Typeflag: tar.TypeSymlink, Linkname: "bin"}},
		{header: &tar.Header{Name: "tmp", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "tmp/.wh.old_file", Typeflag: tar.TypeReg, Size: 0}},
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

	// Windows → Linux
	var linuxBuf bytes.Buffer
	linuxW, _, linuxDone := stripWindowsLayer(ctx, &linuxBuf)
	_, err = io.Copy(linuxW, &winBuf)
	require.NoError(t, err)
	require.NoError(t, <-linuxDone)

	resultEntries := readTar(t, &linuxBuf)
	require.Len(t, resultEntries, len(originalEntries))
	for i, orig := range originalEntries {
		result := resultEntries[i]
		assert.Equal(t, orig.header.Name, result.header.Name, "entry %d name mismatch", i)
		assert.Equal(t, orig.header.Typeflag, result.header.Typeflag, "entry %d typeflag mismatch", i)
		assert.Equal(t, orig.data, result.data, "entry %d data mismatch", i)
		if orig.header.Typeflag == tar.TypeSymlink {
			assert.Equal(t, orig.header.Linkname, result.header.Linkname, "entry %d linkname mismatch", i)
		}
	}
}

func TestWrapLinuxToWindowsLargeFile(t *testing.T) {
	// Verify data integrity through transformation for a non-trivial file
	fileData := make([]byte, 64*1024) // 64KB
	for i := range fileData {
		fileData[i] = byte(i % 256)
	}

	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "largefile.bin", Typeflag: tar.TypeReg, Size: int64(len(fileData))}, data: fileData},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Hives/, Files/, then 1 entry
	require.Len(t, entries, 3)
	assert.Equal(t, "Files/largefile.bin", entries[2].header.Name)
	assert.Equal(t, fileData, entries[2].data)
}

func TestPrepareWinHeader(t *testing.T) {
	tests := []struct {
		name     string
		typeflag byte
		wantAttr string
	}{
		{"directory", tar.TypeDir, "16"},
		{"regular file", tar.TypeReg, "32"},
		{"symlink", tar.TypeSymlink, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := &tar.Header{
				Name:     "test",
				Typeflag: tt.typeflag,
				ModTime:  time.Now(),
			}
			prepareWinHeader(h)
			assert.Equal(t, tar.FormatPAX, h.Format)
			if tt.wantAttr != "" {
				assert.Equal(t, tt.wantAttr, h.PAXRecords[keyFileAttr])
				assert.Contains(t, h.PAXRecords, keyCreationTime)
			} else {
				assert.NotContains(t, h.PAXRecords, keyFileAttr)
			}
		})
	}
}

func TestAddSecurityDescriptor(t *testing.T) {
	tests := []struct {
		name     string
		typeflag byte
		wantSD   bool
	}{
		{"directory gets SD", tar.TypeDir, true},
		{"regular file gets SD", tar.TypeReg, true},
		{"symlink no SD", tar.TypeSymlink, false},
		{"hardlink no SD", tar.TypeLink, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := &tar.Header{
				Name:       "test",
				Typeflag:   tt.typeflag,
				PAXRecords: map[string]string{},
			}
			addSecurityDescriptor(h)
			if tt.wantSD {
				assert.Contains(t, h.PAXRecords, keySDRaw, "expected security descriptor for %s", tt.name)
				assert.NotEmpty(t, h.PAXRecords[keySDRaw])
			} else {
				assert.NotContains(t, h.PAXRecords, keySDRaw, "unexpected security descriptor for %s", tt.name)
			}
		})
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
