# SMJobBless Scaffold

This folder contains a production-oriented scaffold for migrating PortManager
from AppleScript admin prompts to a signed privileged helper using `SMJobBless`.

It is intentionally isolated from the current `build.sh` flow so the app keeps
working while you complete signing and Xcode setup.

## What This Gives You

- Host-side helper client with bless + XPC command execution
- Root helper service with allowlisted command execution
- Launchd plist template for the helper
- Info.plist templates for host/helper requirement matching
- Script to generate code-signing requirement strings

Files:

- `App/PrivilegedHelperClient.swift`
- `Shared/PrivilegedHelperProtocol.swift`
- `Helper/PrivilegedHelperService.swift`
- `Helper/main.swift`
- `Templates/host-SMPrivilegedExecutables.plist`
- `Templates/helper-Info.plist`
- `Templates/helper-Launchd.plist`
- `scripts/generate-requirements.sh`

## Prerequisites

1. Full Xcode (not just Command Line Tools).
2. A valid signing identity in Keychain for your Team.
3. A real Xcode project with:
   - Host app target
   - Privileged helper target (`Launch Daemon` style executable)

## Integration Steps

0. Optional: generate a starter Xcode project with `xcodegen` from this folder:
   - `xcodegen generate --spec project.yml`
   - Open `PortManagerSMJobBless.xcodeproj`

1. Add `Shared/PrivilegedHelperProtocol.swift` to both host and helper targets.
2. Add `App/PrivilegedHelperClient.swift` to host app target.
3. Add `Helper/main.swift` and `Helper/PrivilegedHelperService.swift` to helper target.
4. Set helper launchd label and bundle IDs:
   - Helper label default in scaffold: `com.erlinhoxha.portmanager.helper`
5. Wire plist requirements:
   - Host `Info.plist`: merge `Templates/host-SMPrivilegedExecutables.plist`
   - Helper `Info.plist`: start from `Templates/helper-Info.plist`
6. Sign both targets with same Team.
7. Generate and paste requirement strings using:
   - `scripts/generate-requirements.sh`
8. Replace current `runPrivilegedShellCommand` implementation in `PortManager.swift`
   to call `PrivilegedHelperClient` first, with fallback only if you still want it.

## Expected Runtime Behavior

- First privileged operation: one authorization interaction to bless/install helper.
- After helper is installed: operations go via XPC to the root helper.
- No repeated AppleScript password prompts for each command.

## Notes

- Whether auth UI shows Touch ID versus password is controlled by macOS policy and
  device settings.
- Do not execute arbitrary shell from helper in production. Keep strict allowlists.
