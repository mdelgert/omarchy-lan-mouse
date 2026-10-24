"""Regression checks: python -m unittest discover -s tests -v."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ)
        for variable in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            directory = self.root / variable
            directory.mkdir(mode=0o700)
            self.env[variable] = str(directory)

    def test_automatic_subnet_uses_default_interface_and_fails_without_unique_lan(self):
        binaries = self.root / "bin"
        binaries.mkdir()
        ip = binaries / "ip"
        ip.write_text('''#!/bin/sh
case "$*" in
  "-4 route show default") printf '%s\\n' "$TEST_DEFAULT_ROUTES" ;;
  "-4 route show dev wlo1 scope link") printf '%s\\n' "$TEST_LAN_ROUTES" ;;
  *) exit 1 ;;
esac
''')
        ip.chmod(0o755)
        self.env["PATH"] = str(binaries) + os.pathsep + self.env["PATH"]
        for defaults, routes, override, expected in (
            ("default via 192.168.1.1 dev wlo1", "192.168.1.0/24 proto kernel", None, "192.168.1.0/24"),
            ("default via 10.42.0.1 dev wlo1", "10.42.0.0/16 proto kernel", None, "10.42.0.0/16"),
            ("", "", None, ""),
            ("default dev wlo1", "192.168.1.0/24\n10.0.0.0/24", None, ""),
            ("", "", "172.20.0.0/24", "172.20.0.0/24"),
            ("", "", "invalid", ""),
        ):
            with self.subTest(defaults=defaults, routes=routes, override=override):
                self.env["TEST_DEFAULT_ROUTES"] = defaults
                self.env["TEST_LAN_ROUTES"] = routes
                command = [SCRIPTS / "health-check"]
                if override is not None:
                    command.extend(["--subnet", override])
                result = subprocess.run(command, env=self.env, capture_output=True,
                                        text=True, check=True)
                self.assertEqual(result.stderr, "")
                health = json.loads(result.stdout)
                self.assertEqual(health["subnet"], expected)
                self.assertEqual(health["settingsValid"], bool(expected))
                if not expected:
                    self.assertEqual(health["firewall"]["state"], "unknown")

    def test_health_json_with_missing_empty_and_populated_configs(self):
        config = Path(self.env["XDG_CONFIG_HOME"]) / "lan-mouse/config.toml"
        config.parent.mkdir()
        fingerprint = "ab" * 32
        for content, expected in (
            (None, 0),
            ("", 0),
            ("[authorized_fingerprints]\n", 0),
            (f'[authorized_fingerprints]\n"{fingerprint}" = "desktop"\n', 1),
            (f'[authorized_fingerprints]\n{fingerprint} = "desktop"\n', 1),
        ):
            with self.subTest(content=content):
                if content is not None:
                    config.write_text(content)
                result = subprocess.run(
                    [SCRIPTS / "health-check"], env=self.env,
                    capture_output=True, text=True, check=True,
                )
                self.assertEqual(result.stderr, "")
                health = json.loads(result.stdout)
                self.assertEqual(health["config"]["fingerprints"], expected)
                self.assertEqual(health["config"]["state"],
                                 "missing" if content is None else "ok")

    def test_start_refuses_external_daemon_without_recording_ownership(self):
        # Inject discovery in an isolated script copy. No actual input
        # sharing process is launched or signalled by this regression check.
        scripts = self.root / "scripts"
        shutil.copytree(SCRIPTS, scripts)
        with (scripts / "lib.sh").open("a") as library:
            library.write("\nlan_mouse_daemon_pids() { printf '424242\\n'; }\n")
        result = subprocess.run(
            [scripts / "start-daemon"], env=self.env,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("already running outside this plugin", result.stderr)
        runtime = Path(self.env["XDG_RUNTIME_DIR"]) / "omarchy-lan-mouse"
        self.assertFalse((runtime / "lan-mouse.pid").exists())
        self.assertFalse((runtime / "lan-mouse.log").exists())
        self.assertFalse((Path(self.env["XDG_STATE_HOME"]) /
                          "omarchy-lan-mouse/daemon-desired").exists())


if __name__ == "__main__":
    unittest.main()
