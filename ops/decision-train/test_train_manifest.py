import unittest

import train


class SupportedManifestTest(unittest.TestCase):
    def test_accepts_current_frozen_shell_dialect_experiment(self):
        self.assertTrue(train.is_supported_manifest({"experiment": "tool_gate_shell_dialect_16000_v9"}))

    def test_accepts_frozen_literal_execution_experiment(self):
        self.assertTrue(train.is_supported_manifest({"experiment": "tool_gate_literal_execution_20000_v10"}))

    def test_accepts_frozen_shell_authorization_experiment(self):
        self.assertTrue(train.is_supported_manifest({"experiment": "tool_gate_shell_authorization_24000_v11"}))

    def test_accepts_targeted_shell_contrast_experiment(self):
        self.assertTrue(train.is_supported_manifest({"experiment": "tool_gate_shell_contrast_28000_v12"}))

    def test_accepts_combo_pair_29760_experiment(self):
        self.assertTrue(train.is_supported_manifest({"experiment": "tool_gate_shell_combo_pairs_29760_v15"}))

    def test_rejects_unknown_experiment(self):
        self.assertFalse(train.is_supported_manifest({"experiment": "unregistered_experiment"}))

    def test_keeps_legacy_label_count_compatibility(self):
        self.assertTrue(train.is_supported_manifest({"labels": 10000}))


class ResumeManifestTest(unittest.TestCase):
    def test_legacy_state_without_sessions_counts_aborted_run(self):
        self.assertEqual(train.session_number({"optimizer_step": 1500}, True), 2)

    def test_recorded_sessions_advance_on_resume(self):
        self.assertEqual(train.session_number({"sessions": 2}, True), 3)

    def test_fresh_run_is_first_session(self):
        self.assertEqual(train.session_number({}, False), 1)

    def test_offset_must_land_on_accumulation_boundary(self):
        self.assertEqual(train.resume_offset({"microsteps": 24000}, list(range(29760)), 16), 24000)
        with self.assertRaises(ValueError):
            train.resume_offset({"microsteps": 24008}, list(range(29760)), 16)

    def test_offset_cannot_exceed_recorded_order(self):
        with self.assertRaises(ValueError):
            train.resume_offset({"microsteps": 29776}, list(range(29760)), 16)


if __name__ == "__main__":
    unittest.main()
