package integration

import (
	"fmt"
	"net"
	"os"
	"runtime"

	"github.com/Microsoft/go-winio"

	// include npipe connhelper for windows tests
	_ "github.com/moby/buildkit/client/connhelper/npipe"
)

var socketScheme = "npipe://"

var windowsImagesMirrorMap = map[string]string{
	// TODO(profnandaa): currently, amd64 only, to revisit for other archs.
	"nanoserver:latest": "mcr.microsoft.com/windows/nanoserver:ltsc2022",
	"servercore:latest": "mcr.microsoft.com/windows/servercore:ltsc2022",
	"busybox:latest":    "registry.k8s.io/e2e-test-images/busybox@sha256:6d854ffad9666d2041b879a1c128c9922d77faced7745ad676639b07111ab650",
	// nanoserver with extra binaries, like fc.exe
	// TODO(profnandaa): get an approved/compliant repo, placeholder for now
	// see dockerfile here - https://github.com/microsoft/windows-container-tools/pull/178
	"nanoserver:plus":         "docker.io/wintools/nanoserver:ltsc2022",
	"nanoserver:plus-busybox": "docker.io/wintools/nanoserver:ltsc2022",
}

func init() {
	// Auto-detect ARM64 and use architecture-specific image tags.
	// nanoserver:ltsc2022 and wintools/nanoserver:ltsc2022 lack ARM64 manifests.
	// nanoserver:ltsc2025 is also amd64-only (not multi-arch), so we must use
	// the explicit ltsc2025-arm64 tag for ARM64.
	if runtime.GOARCH == "arm64" {
		windowsImagesMirrorMap["nanoserver:latest"] = "mcr.microsoft.com/windows/nanoserver:ltsc2025-arm64"
		windowsImagesMirrorMap["servercore:latest"] = "mcr.microsoft.com/windows/servercore:ltsc2025-arm64"
		windowsImagesMirrorMap["nanoserver:plus"] = "mcr.microsoft.com/windows/nanoserver:ltsc2025-arm64"
		windowsImagesMirrorMap["nanoserver:plus-busybox"] = "mcr.microsoft.com/windows/nanoserver:ltsc2025-arm64"
	}

	// Allow env var overrides for manual control (e.g., local testing, custom images).
	if v := os.Getenv("BUILDKIT_TEST_NANOSERVER_IMAGE"); v != "" {
		prev := windowsImagesMirrorMap["nanoserver:latest"]
		windowsImagesMirrorMap["nanoserver:latest"] = v
		fmt.Fprintf(os.Stderr, "buildkit integration: BUILDKIT_TEST_NANOSERVER_IMAGE set, overriding nanoserver:latest (%q -> %q)\n", prev, v)
	}
	if v := os.Getenv("BUILDKIT_TEST_SERVERCORE_IMAGE"); v != "" {
		prev := windowsImagesMirrorMap["servercore:latest"]
		windowsImagesMirrorMap["servercore:latest"] = v
		fmt.Fprintf(os.Stderr, "buildkit integration: BUILDKIT_TEST_SERVERCORE_IMAGE set, overriding servercore:latest (%q -> %q)\n", prev, v)
	}
	if v := os.Getenv("BUILDKIT_TEST_NANOSERVER_PLUS_IMAGE"); v != "" {
		prev := windowsImagesMirrorMap["nanoserver:plus"]
		windowsImagesMirrorMap["nanoserver:plus"] = v
		windowsImagesMirrorMap["nanoserver:plus-busybox"] = v
		fmt.Fprintf(os.Stderr, "buildkit integration: BUILDKIT_TEST_NANOSERVER_PLUS_IMAGE set, overriding nanoserver:plus (%q -> %q)\n", prev, v)
	}
}

// abstracted function to handle pipe dialing on windows.
// some simplification has been made to discard timeout param.
func dialPipe(address string) (net.Conn, error) {
	return winio.DialPipe(address, nil)
}
