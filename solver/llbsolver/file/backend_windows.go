package file

import (
	"context"

	"github.com/Microsoft/go-winio"
	"github.com/moby/buildkit/util/windows"
	"github.com/moby/sys/user"
	copy "github.com/tonistiigi/fsutil/copy"
)

func mapUserToChowner(user *copy.User, _ *user.IdentityMapping) (copy.Chowner, error) {
	if user == nil || user.SID == "" {
		return func(old *copy.User) (*copy.User, error) {
			if old == nil || old.SID == "" {
				old = &copy.User{
					SID: windows.ContainerAdministratorSidString,
				}
			}
			return old, nil
		}, nil
	}
	return func(*copy.User) (*copy.User, error) {
		return user, nil
	}, nil
}

// doCopyWithAccessDeniedHandling wraps copy.Copy to handle Windows protected system folders.
// On Windows, container snapshots mounted to the host filesystem include protected folders
// ("System Volume Information" and "WcSandboxState") at the mount root, which cause "Access is denied"
// errors when attempting to read their metadata. This function uses SeBackupPrivilege to allow
// reading these protected files.
//
// SeBackupPrivilege must be enabled process-wide (not thread-local) because copy.Copy spawns
// goroutines that may execute in different OS threads.
func doCopyWithAccessDeniedHandling(ctx context.Context, srcRoot string, src string, destRoot string, dest string, opt ...copy.Opt) error {
	// Enable SeBackupPrivilege process-wide to allow reading protected files
	// This privilege allows reading files and metadata even when ACLs deny access
	privileges := []string{winio.SeBackupPrivilege}

	if err := winio.EnableProcessPrivileges(privileges); err != nil {
		// Continue even if privilege elevation fails - it may already be enabled
		// or the process may not have permission to enable it
		_ = err
	}
	defer func() {
		// Restore previous privilege state
		_ = winio.DisableProcessPrivileges(privileges)
	}()

	// Perform copy with elevated privileges
	return copy.Copy(ctx, srcRoot, src, destRoot, dest, opt...)
}
