package winlayers

import (
	"archive/tar"
	"context"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/core/diff"
	"github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/containerd/v2/core/mount"
	"github.com/containerd/containerd/v2/pkg/archive"
	"github.com/containerd/containerd/v2/pkg/archive/compression"
	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/buildkit/util/bklog"
	digest "github.com/opencontainers/go-digest"
	ocispecs "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/pkg/errors"
)

func NewFileSystemApplierWithWindows(cs content.Provider, a diff.Applier) diff.Applier {
	return &winApplier{
		cs: cs,
		a:  a,
	}
}

type winApplier struct {
	cs content.Provider
	a  diff.Applier
}

func (s *winApplier) Apply(ctx context.Context, desc ocispecs.Descriptor, mounts []mount.Mount, opts ...diff.ApplyOpt) (d ocispecs.Descriptor, err error) {
	// HACK:, containerd doesn't know about vnd.docker.image.rootfs.diff.tar.zstd, but that
	// media type is compatible w/ the oci type, so just lie and say it's the oci type
	if desc.MediaType == images.MediaTypeDockerSchema2Layer+".zstd" {
		desc.MediaType = ocispecs.MediaTypeImageLayerZstd
	}

	winMode := hasWindowsLayerMode(ctx)
	linuxMode := hasLinuxLayerMode(ctx)

	if winMode {
		return s.applyWindowsLayer(ctx, desc, mounts, opts...)
	}
	if linuxMode {
		return s.applyLinuxLayer(ctx, desc, mounts, opts...)
	}
	return s.apply(ctx, desc, mounts, opts...)
}

// applyWindowsLayer applies a Windows-format layer on a Linux host by stripping
// the "Files/" prefix from tar entries.
func (s *winApplier) applyWindowsLayer(ctx context.Context, desc ocispecs.Descriptor, mounts []mount.Mount, opts ...diff.ApplyOpt) (d ocispecs.Descriptor, err error) {

	compressed, err := images.DiffCompression(ctx, desc.MediaType)
	if err != nil {
		return ocispecs.Descriptor{}, errors.Wrapf(cerrdefs.ErrNotImplemented, "unsupported diff media type: %v", desc.MediaType)
	}

	var ocidesc ocispecs.Descriptor
	if err := mount.WithTempMount(ctx, mounts, func(root string) error {
		ra, err := s.cs.ReaderAt(ctx, desc)
		if err != nil {
			return errors.Wrap(err, "failed to get reader from content store")
		}
		defer ra.Close()

		r := content.NewReader(ra)
		if compressed != "" {
			ds, err := compression.DecompressStream(r)
			if err != nil {
				return err
			}
			defer ds.Close()
			r = ds
		}

		digester := digest.Canonical.Digester()
		rc := &readCounter{
			r: io.TeeReader(r, digester.Hash()),
		}

		rc2, discard := filter(rc, func(hdr *tar.Header) bool {
			if after, ok := strings.CutPrefix(hdr.Name, "Files/"); ok {
				hdr.Name = after
				hdr.Linkname = strings.TrimPrefix(hdr.Linkname, "Files/")
				// TODO: could convert the windows PAX headers to xattr here to reuse
				// the original ones in diff for parent directories and file modifications
				return true
			}
			return false
		})

		if _, err := archive.Apply(ctx, root, rc2); err != nil {
			discard(err)
			return err
		}

		// Read any trailing data
		if _, err := io.Copy(io.Discard, rc); err != nil {
			discard(err)
			return err
		}

		ocidesc = ocispecs.Descriptor{
			MediaType: ocispecs.MediaTypeImageLayer,
			Size:      rc.c,
			Digest:    digester.Digest(),
		}
		return nil
	}); err != nil {
		return ocispecs.Descriptor{}, err
	}
	return ocidesc, nil
}

// applyLinuxLayer applies a Linux-format layer on a Windows host by wrapping
// the tar with Windows layer structure (Files/ prefix, PAX headers) and
// importing it via HCS (Host Compute Service). This creates a proper Windows
// container layer with VHDs and metadata so the Windows snapshotter can
// mount and manage it.
func (s *winApplier) applyLinuxLayer(ctx context.Context, desc ocispecs.Descriptor, mounts []mount.Mount, opts ...diff.ApplyOpt) (d ocispecs.Descriptor, err error) {
	compressed, err := images.DiffCompression(ctx, desc.MediaType)
	if err != nil {
		return ocispecs.Descriptor{}, errors.Wrapf(cerrdefs.ErrNotImplemented, "unsupported diff media type: %v", desc.MediaType)
	}

	if len(mounts) == 0 {
		return ocispecs.Descriptor{}, errors.New("no mounts provided for linux layer apply")
	}

	// Get the snapshot directory and parent layer paths from mount metadata.
	snapshotDir := mounts[0].Source
	parentPaths := getParentLayerPaths(mounts)

	ra, err := s.cs.ReaderAt(ctx, desc)
	if err != nil {
		return ocispecs.Descriptor{}, errors.Wrap(err, "failed to get reader from content store")
	}
	defer ra.Close()

	r := content.NewReader(ra)
	if compressed != "" {
		ds, err := compression.DecompressStream(r)
		if err != nil {
			return ocispecs.Descriptor{}, err
		}
		defer ds.Close()
		r = ds
	}

	digester := digest.Canonical.Digester()
	rc := &readCounter{
		r: io.TeeReader(r, digester.Hash()),
	}

	// Wrap the Linux tar with Windows layer structure: add Hives/ and Files/
	// directories, prefix all entries with "Files/", and add Windows PAX
	// headers and security descriptors.
	wrappedTar, discard, done := wrapLinuxToWindows(ctx, rc)

	// Import via HCS which creates Files/, Hives/, blank.vhdx, and all
	// required Windows layer metadata in the snapshot directory.
	if _, err := importLinuxLayerAsWindows(ctx, snapshotDir, wrappedTar, parentPaths); err != nil {
		discard(err)
		return ocispecs.Descriptor{}, errors.Wrap(err, "failed to import linux layer as windows layer")
	}

	if err := <-done; err != nil {
		return ocispecs.Descriptor{}, errors.Wrap(err, "failed wrapping linux tar")
	}

	// Read any trailing data for correct size/digest
	if _, err := io.Copy(io.Discard, rc); err != nil {
		return ocispecs.Descriptor{}, err
	}

	ocidesc := ocispecs.Descriptor{
		MediaType: ocispecs.MediaTypeImageLayer,
		Size:      rc.c,
		Digest:    digester.Digest(),
	}
	return ocidesc, nil
}

// wrapLinuxToWindows transforms a Linux-format tar stream into a Windows-format
// tar stream by adding "Hives/" and "Files/" directories, prefixing all entries
// with "Files/", and adding Windows PAX headers and security descriptors.
func wrapLinuxToWindows(ctx context.Context, in io.Reader) (io.Reader, func(error), chan error) {
	pr, pw := io.Pipe()
	rc := &readCanceler{Reader: in}
	done := make(chan error, 1)

	go func() {
		tarReader := tar.NewReader(rc)
		tarWriter := tar.NewWriter(pw)

		err := func() error {
			h := &tar.Header{
				Name:     "Hives",
				Typeflag: tar.TypeDir,
				ModTime:  time.Now(),
			}
			prepareWinHeader(h)
			if err := tarWriter.WriteHeader(h); err != nil {
				return err
			}

			h = &tar.Header{
				Name:     "Files",
				Typeflag: tar.TypeDir,
				ModTime:  time.Now(),
			}
			prepareWinHeader(h)
			if err := tarWriter.WriteHeader(h); err != nil {
				return err
			}

			for {
				h, err := tarReader.Next()
				if err == io.EOF {
					break
				}
				if err != nil {
					return err
				}
				h.Name = "Files/" + h.Name
				if h.Linkname != "" {
					h.Linkname = "Files/" + h.Linkname
				}
				prepareWinHeader(h)
				addSecurityDescriptor(h)
				if err := tarWriter.WriteHeader(h); err != nil {
					return err
				}
				if h.Size > 0 {
					//nolint:gosec // never read into memory
					if _, err := io.Copy(tarWriter, tarReader); err != nil {
						return err
					}
				}
			}
			return tarWriter.Close()
		}()
		if err != nil {
			bklog.G(ctx).Errorf("wrapLinuxToWindows %+v", err)
		}
		pw.CloseWithError(err)
		done <- err
	}()

	discard := func(err error) {
		rc.cancel(err)
		pw.CloseWithError(err)
	}

	return pr, discard, done
}

type readCounter struct {
	r io.Reader
	c int64
}

func (rc *readCounter) Read(p []byte) (n int, err error) {
	n, err = rc.r.Read(p)
	rc.c += int64(n)
	return
}

func filter(in io.Reader, f func(*tar.Header) bool) (io.Reader, func(error)) {
	pr, pw := io.Pipe()

	rc := &readCanceler{Reader: in}

	go func() {
		tarReader := tar.NewReader(rc)
		tarWriter := tar.NewWriter(pw)

		pw.CloseWithError(func() error {
			for {
				h, err := tarReader.Next()
				if err == io.EOF {
					break
				}
				if err != nil {
					return err
				}
				if f(h) {
					if err := tarWriter.WriteHeader(h); err != nil {
						return err
					}
					if h.Size > 0 {
						//nolint:gosec // never read into memory
						if _, err := io.Copy(tarWriter, tarReader); err != nil {
							return err
						}
					}
				} else if h.Size > 0 {
					//nolint:gosec // never read into memory
					if _, err := io.Copy(io.Discard, tarReader); err != nil {
						return err
					}
				}
			}
			return tarWriter.Close()
		}())
	}()

	discard := func(err error) {
		rc.cancel(err)
		pw.CloseWithError(err)
	}

	return pr, discard
}

type readCanceler struct {
	mu sync.Mutex
	io.Reader
	err error
}

func (r *readCanceler) Read(b []byte) (int, error) {
	r.mu.Lock()
	if r.err != nil {
		r.mu.Unlock()
		return 0, r.err
	}
	n, err := r.Reader.Read(b)
	r.mu.Unlock()
	return n, err
}

func (r *readCanceler) cancel(err error) {
	r.mu.Lock()
	r.err = err
	r.mu.Unlock()
}
