import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import watchdog


class RecoveryTests(unittest.TestCase):
    def test_healthy_resets_failure_count(self):
        state, action = watchdog.recovery_decision(
            {"failures": 2, "last_restart": 0}, True, 1000
        )
        self.assertEqual((state["failures"], action), (0, "healthy"))

    def test_three_consecutive_failures_required(self):
        state = {"failures": 0, "last_restart": 0}
        actions = []
        for now in (1000, 1060, 1120):
            state, action = watchdog.recovery_decision(state, False, now)
            actions.append(action)
        self.assertEqual(actions, ["waiting_for_threshold"] * 2 + ["restart_required"])

    def test_restart_cooldown(self):
        state = {"failures": 2, "last_restart": 1000}
        self.assertEqual(watchdog.recovery_decision(state, False, 1299)[1], "cooldown")
        self.assertEqual(watchdog.recovery_decision(state, False, 1300)[1], "restart_required")

    def test_wrong_host_key_is_not_healthy(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "host.pub"
            key.write_text("ssh-ed25519 EXPECTED comment\n")
            with patch.object(watchdog, "HOST_KEY_PATH", key), patch.object(
                watchdog.subprocess, "run"
            ) as run:
                run.return_value.stdout = "[host]:50022 ssh-ed25519 OTHER\n"
                self.assertFalse(watchdog.public_tunnel_ready())
                run.return_value.stdout = "[host]:50022 ssh-ed25519 EXPECTED\n"
                self.assertTrue(watchdog.public_tunnel_ready())

    def test_local_ssh_failure_does_not_restart(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
            watchdog, "local_ssh_ready", return_value=False
        ), patch.object(watchdog.subprocess, "run") as run:
            self.assertEqual(watchdog.check_and_recover(Path(directory)), 1)
            run.assert_not_called()

    def test_restart_only_designated_service_and_persist_cooldown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            path.write_text(json.dumps({"failures": 2, "last_restart": 0}))
            with patch.object(watchdog, "local_ssh_ready", return_value=True), patch.object(
                watchdog, "public_tunnel_ready", return_value=False
            ), patch.object(watchdog.subprocess, "run") as run:
                run.return_value.returncode = 0
                self.assertEqual(watchdog.check_and_recover(Path(directory)), 0)
                self.assertEqual(
                    run.call_args.args[0],
                    ["/usr/bin/systemctl", "restart", "edge-cli-q4-ssh-h2.service"],
                )
                saved = json.loads(path.read_text())
                self.assertGreater(saved["last_restart"], 0)
                self.assertEqual(saved["failures"], 0)

    def test_dry_run_never_restarts_or_changes_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            content = json.dumps({"failures": 2, "last_restart": 0})
            path.write_text(content)
            with patch.object(watchdog, "local_ssh_ready", return_value=True), patch.object(
                watchdog, "public_tunnel_ready", return_value=False
            ), patch.object(watchdog.subprocess, "run") as run:
                self.assertEqual(watchdog.check_and_recover(Path(directory), True), 1)
                run.assert_not_called()
                self.assertEqual(path.read_text(), content)


if __name__ == "__main__":
    unittest.main()
