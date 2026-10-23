import contextlib
import io
import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch
import short_eval


class FakeModel:
    name='default'

    def load_adapter(self, *args, **kwargs):
        pass

    def set_adapter(self, name):
        self.name=name

    @contextlib.contextmanager
    def disable_adapter(self):
        previous=self.name
        self.name='base'
        yield
        self.name=previous


class ShortEvaluationTest(unittest.TestCase):
    def test_comparison_identifies_previous_and_current_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            row={'id':'fresh','group_id':'heldout','state':{'command':'help'}}
            old={'id':'policy-contrast-005','group_id':'old','state':{'command':'format'}}
            (root/'locked_test_candidate.jsonl').write_text(json.dumps(row)+'\n')
            (root/'regression.jsonl').write_text(json.dumps(old)+'\n')
            (root/'manifest.json').write_text(json.dumps({'regression_sha256':short_eval.digest(root/'regression.jsonl')}))
            before=[{'id':'fresh','group_id':'heldout','label':1,'probability':.6}]
            after=[dict(before[0],probability=.9)]
            (root/'base-locked_test_candidate.json').write_text(json.dumps(before))
            (root/'adapter-locked_test_candidate.json').write_text(json.dumps(after))
            model=FakeModel()
            def evaluate(current,items,_):
                p={'previous':.2,'default':.9,'base':.6}[current.name]
                return [dict(r,probability=p) for r in items]
            regression=[{'id':'policy-contrast-005','group_id':'old','label':1}]
            args=types.SimpleNamespace(run=root,data=root,upstream=root,previous=root,max_length=1536)
            modules={'src':types.ModuleType('src'),'src.inputs':types.ModuleType('src.inputs'),
                     'src.inputs.schema':types.SimpleNamespace(compile_row=lambda r:r)}
            with patch.dict('sys.modules',modules), patch.object(short_eval,'runtime',return_value=(None,None,model,{'locked_test_candidate':before})), \
                 patch.object(short_eval,'encode',return_value=(regression,[])), patch.object(short_eval,'evaluate',side_effect=evaluate), contextlib.redirect_stdout(io.StringIO()):
                short_eval.main(args)
            result=json.loads((root/'short-comparison.json').read_text())
            self.assertEqual(set(result['new_short_test']),{'base','trial3','trial4'})
            self.assertEqual(result['new_short_test']['trial3']['all']['tp'],0)
            self.assertEqual(result['new_short_test']['trial4']['all']['tp'],1)
            self.assertGreater(json.loads((root/'critical-sentinel.json').read_text())[0]['probability'],.5)


if __name__=='__main__':
    unittest.main()
