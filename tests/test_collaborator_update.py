import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "collaborator"


class UpdateTests(unittest.TestCase):
    def run_update(self, *, changed="1", running="burp", failure="0", args=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy2(SCRIPT, root / "collaborator")
            docker = root / "docker"
            docker.write_text("""#!/usr/bin/env bash
set -eu
echo "$*" >> "$DOCKER_CALLS"
case $1 in
    info|build) ;;
    run)
        if [ "$DOWNLOAD_FAILURE" != 0 ]; then
            echo 'Download failed' >&2
            exit "$DOWNLOAD_FAILURE"
        fi
        echo "BURP_JAR_CHANGED=$JAR_CHANGED"
        ;;
    ps) [ -z "$RUNNING_CONTAINER" ] || echo "$RUNNING_CONTAINER" ;;
    restart) ;;
    *) exit 99 ;;
esac
""")
            docker.chmod(0o755)
            calls = root / "docker-calls"
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       DOCKER_CALLS=str(calls), JAR_CHANGED=changed,
                       RUNNING_CONTAINER=running, DOWNLOAD_FAILURE=failure)
            result = subprocess.run(
                [str(root / "collaborator"), "update", *args],
                env=env, capture_output=True, text=True, timeout=10,
            )
            commands = calls.read_text().splitlines() if calls.exists() else []
            return result, commands

    def test_changed_jar_restarts_running_server(self):
        result, commands = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restart burp", commands)

    def test_current_jar_does_not_restart_server(self):
        result, commands = self.run_update(changed="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command.startswith("restart") for command in commands))

    def test_changed_jar_leaves_stopped_server_stopped(self):
        result, commands = self.run_update(running="burp-other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command.startswith(("restart", "start")) for command in commands))

    def test_failed_download_does_not_restart_server(self):
        result, commands = self.run_update(failure="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command.startswith("restart") for command in commands))

    def test_extra_arguments_fail_before_docker(self):
        result, commands = self.run_update(args=("--typo",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update takes no arguments", result.stderr)
        self.assertEqual(commands, [])
