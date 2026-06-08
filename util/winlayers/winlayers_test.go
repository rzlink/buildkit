package winlayers

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"io"
	"runtime"
	"testing"
	"time"

	"github.com/containerd/containerd/v2/core/diff"
	"github.com/containerd/containerd/v2/core/mount"
	ocispecs "github.com/opencontainers/image-spec/specs-go/v1"
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
		if errors.Is(err, io.EOF) {
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

// findEntry returns the tar entry with the given name, or nil.
func findEntry(entries []tarEntry, name string) *tarEntry {
	for i := range entries {
		if entries[i].header.Name == name {
			return &entries[i]
		}
	}
	return nil
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
	require.GreaterOrEqual(t, len(entries), 6, "expected at least 6 entries, got %d", len(entries))

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
	// Relative linknames are preserved verbatim.
	assert.Equal(t, "usr/lib", entries[5].header.Linkname)

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

func TestWrapLinuxToWindowsSkipsNTFSInvalidNames(t *testing.T) {
	// Debian/Ubuntu base images carry dpkg multiarch metadata with ':' in
	// filenames, which NTFS forbids; such entries are dropped with a warning.
	largeBody := bytes.Repeat([]byte("x"), 4096)
	linuxTar := makeTar(t, []tarEntry{
		{header: &tar.Header{Name: "var", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "var/lib", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "var/lib/dpkg", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "var/lib/dpkg/info", Typeflag: tar.TypeDir}},
		// Should be dropped: colon in filename
		{header: &tar.Header{Name: "var/lib/dpkg/info/gcc-12-base:amd64.list", Typeflag: tar.TypeReg, Size: int64(len(largeBody))}, data: largeBody},
		// Should be dropped: other reserved chars
		{header: &tar.Header{Name: "weird?name.txt", Typeflag: tar.TypeReg, Size: 3}, data: []byte("abc")},
		{header: &tar.Header{Name: "pipe|file", Typeflag: tar.TypeReg, Size: 3}, data: []byte("xyz")},
		// Kept; also confirms the dropped large body was drained from the reader.
		{header: &tar.Header{Name: "etc", Typeflag: tar.TypeDir}},
		{header: &tar.Header{Name: "etc/os-release", Typeflag: tar.TypeReg, Size: 5}, data: []byte("hello")},
	})

	ctx := context.Background()
	r, discard, done := wrapLinuxToWindows(ctx, bytes.NewReader(linuxTar))

	entries := readTar(t, r)
	discard(nil)
	require.NoError(t, <-done)

	// Hives/, Files/, Files/var, Files/var/lib, Files/var/lib/dpkg,
	// Files/var/lib/dpkg/info, Files/etc, Files/etc/os-release
	require.Len(t, entries, 8)

	names := make([]string, len(entries))
	for i, e := range entries {
		names[i] = e.header.Name
	}
	assert.NotContains(t, names, "Files/var/lib/dpkg/info/gcc-12-base:amd64.list")
	assert.NotContains(t, names, "Files/weird?name.txt")
	assert.NotContains(t, names, "Files/pipe|file")

	// Verify the legal entry after the dropped large body survived intact
	osRelease := entries[len(entries)-1]
	assert.Equal(t, "Files/etc/os-release", osRelease.header.Name)
	assert.Equal(t, []byte("hello"), osRelease.data)
}

func TestNTFSInvalidPathReason(t *testing.T) {
	tests := []struct {
		name string
		bad  bool
	}{
		{"plain/path/file.txt", false},
		{"café/données.txt", false},
		{"path with spaces/file name.txt", false},
		{"var/lib/dpkg/info/gcc-12-base:amd64.list", true},
		{"weird?file", true},
		{"<bracket>", true},
		{`pipe|file`, true},
		{`quoted"file`, true},
		{"star*file", true},
		{"ctrl\x01char", true},
	}
	for _, tc := range tests {
		_, got := ntfsInvalidPathReason(tc.name)
		assert.Equal(t, tc.bad, got, "name=%q", tc.name)
	}
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

// mockComparer is a stub diff.Comparer used to verify the dispatch logic in
// winDiffer.Compare(). It records each invocation but performs no I/O.
type mockComparer struct {
	calls      int
	lastLower  []mount.Mount
	lastUpper  []mount.Mount
	lastOptLen int
}

func (m *mockComparer) Compare(ctx context.Context, lower, upper []mount.Mount, opts ...diff.Opt) (ocispecs.Descriptor, error) {
	m.calls++
	m.lastLower = lower
	m.lastUpper = upper
	m.lastOptLen = len(opts)
	return ocispecs.Descriptor{}, nil
}

// TestCompareLinuxLayerDelegates verifies that compareLinuxLayer on a Windows
// host produces a Linux-format tar from a Windows filesystem diff by simply
// delegating to the underlying differ. The snapshotter handles the mapping
// between the Windows on-disk Files/ layout and the mount root, so winlayers
// itself adds no wrapping — no Files/ prefix, no Hives/ entries, and no
// MSWINDOWS.* PAX records — to the output.
//
// Concretely, this guarantees that compareLinuxLayer never accidentally goes
// through makeWindowsLayer (which would wrap entries in Files/ and add
// Windows-specific PAX records).
func TestCompareLinuxLayerDelegates(t *testing.T) {
	mock := &mockComparer{}
	d := &winDiffer{store: nil, d: mock}

	_, err := d.compareLinuxLayer(context.Background(), nil, nil)
	require.NoError(t, err)
	require.Equal(t, 1, mock.calls, "compareLinuxLayer should call the underlying differ exactly once")
}

// TestCompareDispatch verifies winDiffer.Compare() routes to the correct
// internal path based on the layer OS context and the host OS.
func TestCompareDispatch(t *testing.T) {
	t.Run("no layer OS delegates to underlying differ", func(t *testing.T) {
		mock := &mockComparer{}
		d := NewWalkingDiffWithWindows(nil, mock)

		_, err := d.Compare(context.Background(), nil, nil)
		require.NoError(t, err)
		assert.Equal(t, 1, mock.calls)
	})

	t.Run("linux layer OS on windows host delegates", func(t *testing.T) {
		if runtime.GOOS != "windows" {
			t.Skip("hasLinuxLayerMode is true only on Windows hosts")
		}
		mock := &mockComparer{}
		d := NewWalkingDiffWithWindows(nil, mock)

		ctx := SetLayerOS(context.Background(), "linux")
		_, err := d.Compare(ctx, nil, nil)
		require.NoError(t, err)
		assert.Equal(t, 1, mock.calls,
			"linux layer OS on Windows should route through compareLinuxLayer which delegates exactly once")
	})

	t.Run("linux layer OS on linux host is same-platform", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("non-Windows-only")
		}
		mock := &mockComparer{}
		d := NewWalkingDiffWithWindows(nil, mock)

		ctx := SetLayerOS(context.Background(), "linux")
		_, err := d.Compare(ctx, nil, nil)
		require.NoError(t, err)
		assert.Equal(t, 1, mock.calls,
			"linux layer OS on Linux is same-platform; no transformation, underlying differ called directly")
	})

	t.Run("windows layer OS on windows host is same-platform", func(t *testing.T) {
		if runtime.GOOS != "windows" {
			t.Skip("Windows-only")
		}
		mock := &mockComparer{}
		d := NewWalkingDiffWithWindows(nil, mock)

		ctx := SetLayerOS(context.Background(), "windows")
		_, err := d.Compare(ctx, nil, nil)
		require.NoError(t, err)
		assert.Equal(t, 1, mock.calls,
			"windows layer OS on Windows is same-platform; no transformation, underlying differ called directly")
	})

	t.Run("unknown layer OS delegates to underlying differ", func(t *testing.T) {
		mock := &mockComparer{}
		d := NewWalkingDiffWithWindows(nil, mock)

		ctx := SetLayerOS(context.Background(), "darwin")
		_, err := d.Compare(ctx, nil, nil)
		require.NoError(t, err)
		assert.Equal(t, 1, mock.calls,
			"unknown layer OS should not trigger any transformation")
	})
}

func TestRelPath(t *testing.T) {
	for _, tc := range []struct {
		from, to, want string
	}{
		{"Files/etc", "Files/usr/lib/os-release", "../usr/lib/os-release"},
		{"Files/usr/lib", "Files/lib/libc.so.6", "../../lib/libc.so.6"},
		{"Files", "Files/bin/sh", "bin/sh"},
		{"Files/a/b/c", "Files/a/b/c/d", "d"},
		{"Files/a/b/c", "Files/a/b", ".."},
		{"Files/a/b", "Files/a/b", "."},
	} {
		got := relPath(tc.from, tc.to)
		assert.Equal(t, tc.want, got, "from=%q to=%q", tc.from, tc.to)
	}
}

func TestRewriteWrappedLinkname(t *testing.T) {
	for _, tc := range []struct {
		typeflag                    byte
		wrappedName, linkname, want string
	}{
		// Relative symlinks: untouched (regression for ubuntu /etc/os-release).
		{tar.TypeSymlink, "Files/etc/os-release", "../usr/lib/os-release", "../usr/lib/os-release"},
		{tar.TypeSymlink, "Files/usr/bin/python3", "python3.11", "python3.11"},
		{tar.TypeSymlink, "Files/lib/link", "../lib64/target", "../lib64/target"},
		// Non-link entries: untouched.
		{tar.TypeReg, "Files/etc/passwd", "", ""},
		// Absolute symlinks: re-rooted relative to symlink's wrapped dir.
		{tar.TypeSymlink, "Files/etc/os-release", "/usr/lib/os-release", "../usr/lib/os-release"},
		{tar.TypeSymlink, "Files/usr/lib/libc.so.6", "/lib/libc.so.6", "../../lib/libc.so.6"},
		{tar.TypeSymlink, "Files/entrypoint", "/bin/sh", "bin/sh"},
		{tar.TypeSymlink, "Files/bin/sh", "/bin/busybox", "busybox"},
		// Hardlinks: linkname is a tar entry name, must keep Files/ prefix.
		{tar.TypeLink, "Files/usr/bin/perl5.34.0", "usr/bin/perl", "Files/usr/bin/perl"},
		{tar.TypeLink, "Files/bin/sh", "bin/bash", "Files/bin/bash"},
	} {
		got := rewriteWrappedLinkname(tc.typeflag, tc.wrappedName, tc.linkname)
		assert.Equal(t, tc.want, got, "type=%d wrappedName=%q linkname=%q", tc.typeflag, tc.wrappedName, tc.linkname)
	}
}

func TestWrapLinuxToWindowsLinkRewrite(t *testing.T) {
	for _, tc := range []struct {
		name    string
		entries []tarEntry
		lookup  string
		want    string
	}{
		{
			// Regression: ubuntu /etc/os-release -> ../usr/lib/os-release.
			name: "relative symlink preserved",
			entries: []tarEntry{
				{header: &tar.Header{Name: "usr/lib/os-release", Typeflag: tar.TypeReg, Size: 5}, data: []byte("hello")},
				{header: &tar.Header{Name: "etc/os-release", Typeflag: tar.TypeSymlink, Linkname: "../usr/lib/os-release"}},
			},
			lookup: "Files/etc/os-release",
			want:   "../usr/lib/os-release",
		},
		{
			name: "absolute symlink rerooted",
			entries: []tarEntry{
				{header: &tar.Header{Name: "lib/libc.so.6", Typeflag: tar.TypeReg, Size: 3}, data: []byte("abc")},
				{header: &tar.Header{Name: "usr/lib/libc.so.6", Typeflag: tar.TypeSymlink, Linkname: "/lib/libc.so.6"}},
			},
			lookup: "Files/usr/lib/libc.so.6",
			want:   "../../lib/libc.so.6",
		},
		{
			name: "absolute symlink at root",
			entries: []tarEntry{
				{header: &tar.Header{Name: "bin/sh", Typeflag: tar.TypeReg, Size: 3}, data: []byte("xyz")},
				{header: &tar.Header{Name: "entrypoint", Typeflag: tar.TypeSymlink, Linkname: "/bin/sh"}},
			},
			lookup: "Files/entrypoint",
			want:   "bin/sh",
		},
		{
			name: "hardlink keeps prefix",
			entries: []tarEntry{
				{header: &tar.Header{Name: "usr/bin/perl", Typeflag: tar.TypeReg, Size: 3}, data: []byte("abc")},
				{header: &tar.Header{Name: "usr/bin/perl5.34.0", Typeflag: tar.TypeLink, Linkname: "usr/bin/perl"}},
			},
			lookup: "Files/usr/bin/perl5.34.0",
			want:   "Files/usr/bin/perl",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, discard, done := wrapLinuxToWindows(context.Background(), bytes.NewReader(makeTar(t, tc.entries)))
			entries := readTar(t, r)
			discard(nil)
			require.NoError(t, <-done)

			link := findEntry(entries, tc.lookup)
			require.NotNil(t, link, "wrapped entry %q missing", tc.lookup)
			assert.Equal(t, tc.want, link.header.Linkname)
		})
	}
}
