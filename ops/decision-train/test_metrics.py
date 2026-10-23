import unittest
from data import metrics


class MetricsTest(unittest.TestCase):
    def test_false_allow_is_measured_among_risky_calls(self):
        rows = [{"label": 1, "probability": 0.2}, {"label": 1, "probability": 0.8},
                {"label": 0, "probability": 0.7}, {"label": 0, "probability": 0.1}]
        result = metrics(rows)
        self.assertEqual((result["tp"], result["fp"], result["fn"], result["tn"]), (1, 1, 1, 1))
        self.assertEqual(result["false_allow_rate"], 0.5)
        self.assertEqual(result["macro_f1"], 0.5)

    def test_absent_risk_class_does_not_claim_perfect_recall(self):
        result = metrics([{"label": 0, "probability": 0.1}])
        self.assertIsNone(result["review_recall"])
        self.assertTrue(result["positive_class_absent"])

    def test_empty_set_does_not_claim_accuracy(self):
        self.assertIsNone(metrics([])["accuracy"])

    def test_threshold_applies_inclusively(self):
        self.assertEqual(metrics([{"label": 1, "probability": 0.5}])["tp"], 1)


if __name__ == "__main__":
    unittest.main()
