# DisplayLink Guard

A small macOS utility that restarts `DisplayLinkPrivilegedHelper` when its memory footprint reaches **750 MiB**. It checks every **15 minutes**, using a per-user LaunchAgent. Nothing runs between checks.

This is a temporary workaround for growing helper memory usage, not a driver fix. It does not reboot the Mac, quit DisplayLink Manager, or terminate WindowServer. A helper restart can briefly interrupt DisplayLink displays or move windows, depending on the setup.

## When to use it

Use this if **DisplayLinkPrivilegedHelper** steadily consumes more memory on your Mac and restarting that helper releases it. This tool does not address leaks in `DisplayLinkUserAgent`, `CrashRestartHelper`, or other processes.

The linked forum thread describes different affected processes: the original report concerns `DisplayLinkUserAgent` and `CrashRestartHelper`, while later reports concern `DisplayLinkPrivilegedHelper`. This guard targets the latter workaround only. Check the process name in Activity Monitor before installing; restarting the privileged helper is not evidence that memory retained by the other processes will be released.

On October 20, 2026, [DisplayLink support acknowledged the reported issue](https://www.displaylink.org/forum/printthread.php?t=69953) and said a fix was expected in the next software update. **Last checked: November 10, 2026.** The [official download page](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) still listed 17.0 as the latest release, and the thread did not confirm a shipped fix. This project is independent of Synaptics/DisplayLink.

Check the official release notes before installing. Once an update fixes the leak on your Mac, uninstall the guard using the instructions below. There is no automatic driver-version check or update service.

## Requirements

- macOS 13 or later is the build target. **Live-tested on macOS 27.0.1, Apple Silicon, DisplayLink Manager 17.0.24.** Other macOS/DisplayLink combinations are not hardware-validated.
- **For source builds only:** Swift 6.0 or newer, supplied by a recent Xcode or Xcode Command Line Tools installation. Check with `swift --version`. The packaged desktop app does not require developer tools.
- DisplayLink Manager installed at `/Applications/DisplayLink Manager.app`, with its privileged helper running.
- An active local login and administrator credentials for the one-time permission setup.

The CI builds and runs simulated tests on macOS 15 for Apple Silicon and Intel. CI does not have a DisplayLink dock and cannot verify actual display recovery.

## Desktop app

[Download DisplayLink Guard for macOS](https://github.com/Florian-Cullmann/displaylink-guard/releases/download/v0.2.0/DisplayLink-Guard-0.2.0.dmg) — a universal app for Apple Silicon and Intel, Developer ID signed and notarized by Apple.

The app includes the compiled guard, displays current memory use, and provides **Enable protection**, **Refresh** and **Remove protection** buttons. You do not need Swift, Xcode, Python or Terminal. Closing its window does not stop the installed monitor.

To install:

1. Open the downloaded DMG and drag **DisplayLink Guard** to **Applications**.
2. Open the app and choose **Enable protection**.
3. Approve the administrator prompt. The app checks every 15 minutes after setup.

To uninstall, choose **Remove protection**, approve removal of the restart permission, then move the app to Trash. Settings and logs remain for inspection. Removing only the app does not uninstall the monitor.

## Install from source

```sh
git clone https://github.com/Florian-Cullmann/displaylink-guard.git
cd displaylink-guard
bash scripts/install.sh
```

Run the installer as your normal user, **not with `sudo`**. Review the scripts before running them. It builds from source, checks the helper and configuration, then asks for administrator authentication to install the restricted restart permission. The source installer builds locally; it does not download an executable.

The program is copied to `~/Library/Application Support/DisplayLinkGuard/`. Its LaunchAgent is `~/Library/LaunchAgents/de.fcullmann.displaylink-guard.plist`. The checkout is not needed after installation.

For an update, run `git pull --ff-only` and `bash scripts/install.sh` from the checkout. Existing settings and the last restart attempt are retained. Legacy port-monitor settings are migrated with `*.v1-backup` copies. Handled installation failures restore the previous files and LaunchAgent state; a newly created restart permission is removed if installation fails. An abrupt power loss or forced process termination can still require manual recovery.

## Permissions

The monitor runs as your user. Only this exact command is permitted as root, without a password:

```sh
/bin/launchctl kickstart -k system/com.displaylink.DisplayLinkManager.PrivilegedHelper
```

The installer writes a root-owned, mode-0440 rule to `/private/etc/sudoers.d/displaylink-guard-<uid>` and checks it with `visudo`. It does not grant root access to the guard executable, installation scripts, a shell, or other `launchctl` commands.

**Any process running as your user can use this permission to restart that helper.** The memory threshold and cooldown are enforced by the guard, not by sudo. Use this only on accounts where that limited permission is acceptable. An existing permission file with unexpected contents is left untouched and installation stops.

## Check status

```sh
GUARD="$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard"
"$GUARD" status
"$GUARD" check --dry-run
```

`status` shows the last saved observation. `check --dry-run` takes a fresh measurement and shows the decision without changing state or restarting anything. To run a normal check immediately, use `"$GUARD" check`; the same threshold and cooldown apply.

State and settings are in the installation directory. Logs are at `~/Library/Logs/DisplayLinkGuard/events.log`, rotated once at 1 MiB. The guard makes no network requests and records no screen contents.

## Restart policy

- Check when the LaunchAgent loads, then every 900 seconds. Sleep delays checks; the guard does not wake the Mac.
- Restart after one measurement at or above the configured threshold. Memory is read from `top`'s `MEM` field, including compressed memory, rather than RSS alone.
- Wait at least 15 minutes between attempts, including failed attempts. There is no daily limit. A manual check or scheduling delay can cause the next scheduled check to fall inside this cooldown.
- Allow five minutes after the first check or a new WindowServer, and two minutes after a measurement gap longer than 22.5 minutes or a backward clock change. A skipped check is retried at the next regular interval.
- Require the helper to be at least one minute old, DisplayLink Manager to be running in the active user's session, and an external display to be active.
- Resolve the helper PID from its fixed system service and check UID 0 and its executable path again before restarting.
- Save the attempt before requesting a restart. Concurrent checks are locked out.
- After restarting, check for a new helper PID, lower memory usage, and the previous active display modes for up to 90 seconds. Log the before/after values. Incomplete verification is reported without repeating the restart.

750 MiB is a configurable policy choice, not an official DisplayLink recommendation or a universal leak detector.

## Configuration

Edit `~/Library/Application Support/DisplayLinkGuard/settings.json`. Changes are read on the next check; all fields are required.

```json
{
  "thresholdMemoryMiB": 750,
  "cooldownSeconds": 900,
  "startupGraceSeconds": 300,
  "resumeGraceSeconds": 120,
  "minimumHelperAgeSeconds": 60
}
```

| Setting | Allowed range | Unit |
| --- | ---: | --- |
| `thresholdMemoryMiB` | 1–1048576 | MiB |
| `cooldownSeconds` | 900–604800 | seconds |
| `startupGraceSeconds` | 0–86400 | seconds |
| `resumeGraceSeconds` | 0–3600 | seconds |
| `minimumHelperAgeSeconds` | 0–86400 | seconds |

The check interval is fixed at 15 minutes. Very low thresholds are useful only for controlled testing. Upgrading preserves existing settings, including older 2-GiB thresholds and three-hour cooldowns; change them explicitly if desired.

## Uninstall

Stop the monitor and remove its LaunchAgent:

```sh
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" uninstall
```

Remove the separate restart permission as well:

```sh
sudo rm "/private/etc/sudoers.d/displaylink-guard-$(id -u)"
```

Settings, executable and logs remain for inspection. To remove them after uninstalling:

```sh
rm -rf "$HOME/Library/Application Support/DisplayLinkGuard"
rm -rf "$HOME/Library/Logs/DisplayLinkGuard"
```

## Troubleshooting

- **Preflight cannot find the helper:** start DisplayLink Manager and check that its background service is enabled. The guard intentionally refuses unknown service layouts.
- **Permission denied on restart:** rerun `bash scripts/install.sh` and inspect the reported sudoers error. Do not run the guard itself as root.
- **Invalid settings/state:** correct the reported file. Installation validates it before stopping an existing monitor. Do not delete state just to bypass a cooldown.
- **Installation lock after an interrupted install:** first confirm no installer is running, then remove the empty `~/Library/Application Support/DisplayLinkGuard/install.lock` directory with `rmdir` and rerun the installer.
- **Rollback or permission cleanup failed:** follow the exact error, retain the log, and rerun installation after correcting the cause. A force-killed installer cannot run its cleanup handlers.
- **`restart_verification_incomplete`:** the command ran, but the guard could not confirm all recovery conditions. Check the display and log before trying again.

## Development

No external Swift packages are required. Packaging and signing instructions are in [docs/releasing.md](docs/releasing.md).

```sh
swift test
swift build --configuration release
bash -n scripts/install.sh
sh -n scripts/permission.sh
python3 Tests/InstallerTests/test_install.py
```

The Python 3 test harness is only needed for development. It tests installation failure paths using mocked commands. Swift tests cover policy, parsing, process identity, restart verification, migration and rollback. Neither test suite restarts DisplayLink or installs a service.

For bug reports, include macOS and DisplayLink versions, processor architecture, the dry-run result and relevant log lines. Remove any information you do not want public. Do not upload full system diagnostics or credentials.

## License

[MIT](LICENSE).
