package dockerfile

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/containerd/continuity/fs/fstest"
	"github.com/moby/buildkit/client"
	"github.com/moby/buildkit/frontend/dockerui"
	"github.com/moby/buildkit/session"
	"github.com/moby/buildkit/session/sshforward/sshprovider"
	"github.com/moby/buildkit/util/testutil/integration"
	"github.com/stretchr/testify/require"
	"github.com/tonistiigi/fsutil"
)

var sshTests = integration.TestFuncs(
	testSSHSocketParams,
	testSSHFileDescriptorsClosed,
	testSSHWindowsAgentPipe,
)

func init() {
	allTests = append(allTests, sshTests...)
}

func testSSHSocketParams(t *testing.T, sb integration.Sandbox) {
	integration.SkipOnPlatform(t, "windows")
	f := getFrontend(t, sb)

	dockerfile := []byte(`
FROM busybox
RUN --mount=type=ssh,mode=741,uid=100,gid=102 [ "$(stat -c "%u %g %f" $SSH_AUTH_SOCK)" = "100 102 c1e1" ]
`)

	dir := integration.Tmpdir(
		t,
		fstest.CreateFile("Dockerfile", dockerfile, 0600),
	)

	c, err := client.New(sb.Context(), sb.Address())
	require.NoError(t, err)
	defer c.Close()

	k, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)

	dt := pem.EncodeToMemory(
		&pem.Block{
			Type:  "RSA PRIVATE KEY",
			Bytes: x509.MarshalPKCS1PrivateKey(k),
		},
	)

	tmpDir := t.TempDir()

	err = os.WriteFile(filepath.Join(tmpDir, "key"), dt, 0600)
	require.NoError(t, err)

	ssh, err := sshprovider.NewSSHAgentProvider([]sshprovider.AgentConfig{{
		Paths: []string{filepath.Join(tmpDir, "key")},
	}})
	require.NoError(t, err)

	_, err = f.Solve(sb.Context(), c, client.SolveOpt{
		LocalMounts: map[string]fsutil.FS{
			dockerui.DefaultLocalNameDockerfile: dir,
			dockerui.DefaultLocalNameContext:    dir,
		},
		Session: []session.Attachable{ssh},
	}, nil)
	require.NoError(t, err)
}

// sshAgentPipeProbeSource is a tiny standalone Windows program (no external
// dependencies) that connects to the well-known Windows OpenSSH agent named
// pipe and performs an ssh-agent REQUEST_IDENTITIES handshake. It retries
// briefly because the forwarded pipe becomes available a moment after the
// container process starts. It exits 0 only if the agent answers, proving the
// forwarded agent is actually reachable inside the container.
//
// A compiled probe is required because nanoserver ships no ssh client and cmd
// built-ins (dir, if exist, type) cannot open or stat a duplex named pipe.
const sshAgentPipeProbeSource = `package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	const pipe = ` + "`" + `\\.\pipe\openssh-ssh-agent` + "`" + `
	var f *os.File
	var err error
	for i := 0; i < 50; i++ {
		if f, err = os.OpenFile(pipe, os.O_RDWR, 0); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		fmt.Println("PROBE_FAIL open:", err)
		os.Exit(2)
	}
	defer f.Close()

	// SSH_AGENTC_REQUEST_IDENTITIES = 11
	if _, err := f.Write([]byte{0, 0, 0, 1, 11}); err != nil {
		fmt.Println("PROBE_FAIL write:", err)
		os.Exit(3)
	}
	hdr := make([]byte, 5)
	if _, err := readFull(f, hdr); err != nil {
		fmt.Println("PROBE_FAIL read:", err)
		os.Exit(4)
	}
	// SSH_AGENT_IDENTITIES_ANSWER = 12
	if hdr[4] != 12 {
		fmt.Printf("PROBE_FAIL bad type=%d\n", hdr[4])
		os.Exit(5)
	}
	fmt.Println("PROBE_OK agent reachable")
}

func readFull(f *os.File, b []byte) (int, error) {
	total := 0
	for total < len(b) {
		n, err := f.Read(b[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
`

// testSSHWindowsAgentPipe verifies end-to-end that on Windows the forwarded SSH
// agent is exposed inside the WCOW container as the well-known OpenSSH named
// pipe (\\.\pipe\openssh-ssh-agent). A small probe is compiled, copied into the
// image, and run under --mount=type=ssh; it connects to the pipe and completes
// an ssh-agent handshake, proving the agent is actually reachable.
func testSSHWindowsAgentPipe(t *testing.T, sb integration.Sandbox) {
	integration.SkipOnPlatform(t, "!windows")

	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("go toolchain required to build the ssh agent pipe probe")
	}

	f := getFrontend(t, sb)

	// Build the probe for windows/amd64 (the worker platform for this test).
	buildDir := t.TempDir()
	srcPath := filepath.Join(buildDir, "main.go")
	require.NoError(t, os.WriteFile(srcPath, []byte(sshAgentPipeProbeSource), 0600))
	probePath := filepath.Join(buildDir, "sshprobe.exe")
	cmd := exec.CommandContext(sb.Context(), goBin, "build", "-o", probePath, srcPath)
	cmd.Env = append(os.Environ(), "GOOS=windows", "GOARCH=amd64", "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "building ssh probe: %s", out)
	probe, err := os.ReadFile(probePath)
	require.NoError(t, err)

	dockerfile := []byte(`
FROM nanoserver
USER ContainerAdministrator
COPY sshprobe.exe C:/sshprobe.exe
RUN --mount=type=ssh C:\sshprobe.exe
`)

	dir := integration.Tmpdir(
		t,
		fstest.CreateFile("Dockerfile", dockerfile, 0600),
		fstest.CreateFile("sshprobe.exe", probe, 0600),
	)

	c, err := client.New(sb.Context(), sb.Address())
	require.NoError(t, err)
	defer c.Close()

	k, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)

	dt := pem.EncodeToMemory(
		&pem.Block{
			Type:  "RSA PRIVATE KEY",
			Bytes: x509.MarshalPKCS1PrivateKey(k),
		},
	)

	tmpDir := t.TempDir()

	err = os.WriteFile(filepath.Join(tmpDir, "key"), dt, 0600)
	require.NoError(t, err)

	ssh, err := sshprovider.NewSSHAgentProvider([]sshprovider.AgentConfig{{
		Paths: []string{filepath.Join(tmpDir, "key")},
	}})
	require.NoError(t, err)

	_, err = f.Solve(sb.Context(), c, client.SolveOpt{
		LocalMounts: map[string]fsutil.FS{
			dockerui.DefaultLocalNameDockerfile: dir,
			dockerui.DefaultLocalNameContext:    dir,
		},
		Session: []session.Attachable{ssh},
	}, nil)
	require.NoError(t, err)
}

func testSSHFileDescriptorsClosed(t *testing.T, sb integration.Sandbox) {
	integration.SkipOnPlatform(t, "windows")
	f := getFrontend(t, sb)

	dockerfile := []byte(`
FROM alpine
RUN --mount=type=ssh apk update \
 && apk add openssh-client-default \
 && mkdir -p -m 0600 ~/.ssh \
 && ssh-keyscan github.com >> ~/.ssh/known_hosts \
 && for i in $(seq 1 3); do \
        ssh -T git@github.com; \
    done; \
    exit 0;
`)

	dir := integration.Tmpdir(
		t,
		fstest.CreateFile("Dockerfile", dockerfile, 0600),
	)

	c, err := client.New(sb.Context(), sb.Address())
	require.NoError(t, err)
	defer c.Close()

	// not using t.TempDir() here because the path ends up longer than the unix socket max length
	tmpDir, err := os.MkdirTemp("", "buildkit-ssh-test-") //nolint:usetesting // see comment above
	require.NoError(t, err)
	t.Cleanup(func() {
		os.RemoveAll(tmpDir)
	})
	sockPath := filepath.Join(tmpDir, "ssh-agent.sock")

	sshAgentCmd := exec.CommandContext(sb.Context(), "ssh-agent", "-s", "-d", "-a", sockPath)
	sshAgentOutputBuf := &bytes.Buffer{}
	sshAgentCmd.Stderr = sshAgentOutputBuf
	require.NoError(t, sshAgentCmd.Start())
	var found bool
	for range 100 {
		_, err := os.Stat(sockPath)
		if err == nil {
			found = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !found {
		sshAgentOutput := sshAgentOutputBuf.String()
		t.Fatalf("ssh-agent failed to start: %s", sshAgentOutput)
	}

	ssh, err := sshprovider.NewSSHAgentProvider([]sshprovider.AgentConfig{{
		Paths: []string{sockPath},
	}})
	require.NoError(t, err)

	_, err = f.Solve(sb.Context(), c, client.SolveOpt{
		LocalMounts: map[string]fsutil.FS{
			dockerui.DefaultLocalNameDockerfile: dir,
			dockerui.DefaultLocalNameContext:    dir,
		},
		Session: []session.Attachable{ssh},
	}, nil)
	require.NoError(t, err)

	sshAgentOutput := sshAgentOutputBuf.String()
	require.Contains(t, sshAgentOutput, "process_message: socket 1")
	require.NotContains(t, sshAgentOutput, "process_message: socket 2")
	require.NotContains(t, sshAgentOutput, "process_message: socket 3")
}
