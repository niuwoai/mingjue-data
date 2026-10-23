import copy
import unittest
from full_4b_eval import paired


class PairedFullTrainingTest(unittest.TestCase):
    def fixtures(self):
        old=[{'id':str(i),'group_id':'fixed','label':int(i<5),'probability':.1 if i<5 else .9} for i in range(26)]
        old.extend([{'id':'correct-danger','group_id':'extra','label':1,'probability':.9},
                    {'id':'correct-normal','group_id':'extra','label':0,'probability':.1}])
        new=copy.deepcopy(old)
        inputs={r['id']:{'state':{'command':'inert fixture'}} for r in old}
        return old,new,inputs

    def test_fixes_are_separate_from_new_regressions(self):
        old,new,inputs=self.fixtures()
        new[0]['probability']=.8
        new[5]['probability']=.2
        new[-2]['probability']=.2
        new[-1]['probability']=.8
        transitions,focus=paired(old,new,inputs)
        self.assertEqual(focus['false_allow']['fixed'],1)
        self.assertEqual(focus['false_review']['fixed'],1)
        self.assertEqual(focus['new_regressions'],{'rows':2,'false_allow':1,'false_review':1})
        self.assertEqual(sum(r['transition']=='still_wrong' for r in transitions),24)

    def test_population_or_label_change_fails_closed(self):
        old,new,inputs=self.fixtures()
        with self.assertRaises(ValueError):
            paired(old,list(reversed(new)),inputs)
        new[0]['label']=0
        with self.assertRaises(ValueError):
            paired(old,new,inputs)


if __name__=='__main__':
    unittest.main()
