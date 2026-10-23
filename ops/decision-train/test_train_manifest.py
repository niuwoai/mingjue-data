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

    def test_rejects_unknown_experiment(self):
        self.assertFalse(train.is_supported_manifest({"experiment": "unregistered_experiment"}))

    def test_keeps_legacy_label_count_compatibility(self):
        self.assertTrue(train.is_supported_manifest({"labels": 10000}))


if __name__ == "__main__":
    unittest.main()
