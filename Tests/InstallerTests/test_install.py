"""Exercise installer orchestration without sudo, launchd, or DisplayLink."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]


class InstallerTests(unittest.TestCase):
    def run_installer(self, permission="created", fail="", locked=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project with spaces"
            (project / "scripts").mkdir(parents=True)
            shutil.copy(REPOSITORY / "scripts/install.sh", project / "scripts/install.sh")
            (project / ".build/release").mkdir(parents=True)
            commands = root / "commands"
            commands.mkdir()
            home = root / "home"
            home.mkdir()
            install_lock = home / "Library/Application Support/DisplayLinkGuard/install.lock"
            if locked:
                install_lock.mkdir(parents=True)
            log = root / "calls"
            programs = {
                "uname": "echo Darwin",
                "id": "echo 501",
                "swift": 'if [ "$1" = --version ]; then echo "Apple Swift version 6.2"; fi',
                "sudo": '''echo "permission:$3" >> "$CALL_LOG"
if [ "$3" = ensure ]; then
    [ "$FAIL_AT" != permission ] || exit 1
    echo "$PERMISSION_STATUS"
fi''',
            }
            for name, body in programs.items():
                path = commands / name
                path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
                path.chmod(0o755)
            binary = project / ".build/release/displaylink-guard"
            binary.write_text('''#!/bin/sh
set -eu
echo "binary:$1" >> "$CALL_LOG"
[ "$FAIL_AT" != "$1" ] || exit 1
''')
            binary.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                       HOME=str(home), CALL_LOG=str(log), FAIL_AT=fail, PERMISSION_STATUS=permission)
            result = subprocess.run(["/bin/bash", str(project / "scripts/install.sh")],
                                    env=env, capture_output=True, text=True)
            calls = log.read_text().splitlines() if log.exists() else []
            lock_exists = install_lock.exists()
            return result, calls, lock_exists

    def test_success_keeps_permission_and_releases_lock(self):
        result, calls, lock = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["binary:preflight", "permission:ensure", "binary:install"])
        self.assertFalse(lock)

    def test_failed_install_removes_only_new_permission(self):
        result, calls, lock = self.run_installer(fail="install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[-1], "permission:remove")
        self.assertFalse(lock)

    def test_failed_update_preserves_existing_permission(self):
        result, calls, lock = self.run_installer(permission="existing", fail="install")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("permission:remove", calls)
        self.assertFalse(lock)

    def test_preflight_failure_never_requests_sudo(self):
        result, calls, lock = self.run_installer(fail="preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["binary:preflight"])
        self.assertFalse(lock)

    def test_permission_failure_does_not_install(self):
        result, calls, lock = self.run_installer(fail="permission")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("binary:install", calls)
        self.assertFalse(lock)

    def test_concurrent_installer_never_changes_permission(self):
        result, calls, lock = self.run_installer(locked=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["binary:preflight"])
        self.assertTrue(lock)


if __name__ == "__main__":
    unittest.main()
