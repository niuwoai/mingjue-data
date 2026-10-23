import unittest
from balance import balanced_order


class BalanceTests(unittest.TestCase):
    def test_every_accumulation_batch_has_equal_classes(self):
        items = [{'label': int(i < 3)} for i in range(23)]
        order = balanced_order(items, 64, 16, 42)
        self.assertEqual(order, balanced_order(items, 64, 16, 42))
        for start in range(0, len(order), 16):
            self.assertEqual(sum(items[i]['label'] for i in order[start:start+16]), 8)
        self.assertEqual(len({i for i in order if items[i]['label']}), 3)
        self.assertEqual(len({i for i in order if not items[i]['label']}), 20)

    def test_rejects_incomplete_or_one_class(self):
        for items, draws, accumulation in [([{'label': 0}], 16, 16),
                                           ([{'label': 0}, {'label': 1}], 17, 16),
                                           ([{'label': 0}, {'label': 1}], 15, 15)]:
            with self.assertRaises(ValueError):
                balanced_order(items, draws, accumulation, 42)


if __name__ == '__main__':
    unittest.main()
