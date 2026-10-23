import unittest
from shell_eval import cohort
from balance import balanced_order


class ShellRegressionTest(unittest.TestCase):
    def test_cohort_requires_unchanged_labels_and_tracks_fix(self):
        old=[{'id':'a','label':1,'probability':.1},{'id':'b','label':0,'probability':.1}]
        new=[{'id':'a','label':1,'probability':.9},{'id':'b','label':0,'probability':.9}]
        result=cohort(new,old,['a','b'])
        self.assertTrue(result[0]['current_correct'])
        self.assertFalse(result[1]['current_correct'])
        new[0]['label']=0
        with self.assertRaises(ValueError):
            cohort(new,old,['a'])

    def test_shell_budget_covers_all_6000_with_balanced_batches(self):
        items=[{'label':int(i>=3000)} for i in range(6000)]
        order=balanced_order(items,6016,16,20261021)
        self.assertEqual(len(order),6016)
        self.assertEqual(len(set(order)),6000)
        self.assertTrue(all(sum(items[i]['label'] for i in order[n:n+16])==8 for n in range(0,6016,16)))


if __name__=='__main__':
    unittest.main()
