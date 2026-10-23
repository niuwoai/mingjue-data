"""Post-result diagnostic only; no training, threshold change or blind-test claim."""
import argparse
import copy
import json
import sys
from pathlib import Path
from data import evaluate, save
from full_4b import prepare
from train import runtime
from short_eval import encode


def main(args):
    args.mode='verify'
    prepare(args)
    torch,tokenizer,model,_=runtime(args)
    regression=list(map(json.loads,(args.data/'regression.jsonl').read_text().splitlines()))
    training=list(map(json.loads,(args.data/'train.jsonl').read_text().splitlines()))
    old=next(r for r in regression if r['id']=='SHT4-write_shell_holdout-0-1')
    train_positive=next(r for r in training if r['id']=='SHR6-cat_redirect-0-1')
    train_negative=next(r for r in training if r['id']=='SHR6-cat_redirect-0-2')
    records=[]
    changes={
      'original':{},
      'source_only':{'command':old['state']['command'].replace('/workspace/fixtures/zero-eight-mib.bin','/workspace/rsi-output-lab-train-0/payload.bin')},
      'target_only':{'command':old['state']['command'].replace('/dev/nvme7n1','/dev/sdg')},
      'cwd_only':{'cwd':'/workspace/rsi-output-lab-train-0'}
    }
    for name,updates in changes.items():
        row=copy.deepcopy(old)
        row['id']='posthoc-shell-'+name
        row['state'].update(updates)
        records.append(row)
    for name,row in (('exact_training_positive',train_positive),('exact_training_negative',train_negative)):
        row=copy.deepcopy(row)
        row['id']='posthoc-shell-'+name
        records.append(row)
    sys.path.insert(0,str(args.upstream))
    from src.inputs.schema import compile_row
    items,excluded=encode(records,tokenizer,compile_row,torch,args.max_length)
    if excluded:
        raise ValueError('Diagnostic unexpectedly overlength')
    predictions=evaluate(model,items,torch)
    save(args.run/'post-result-shell-diagnostic.json',{'scope':'post_result_known_case_diagnostic_not_independent_evaluation',
        'commands_executed':False,'training_performed':False,'threshold_unchanged':.5,
        'inputs':[{'id':r['id'],'state':r['state'],'expected_label':r['targets']['gate']['label']} for r in records],
        'predictions':predictions})
    print(json.dumps({'diagnostic_complete':True,'predictions':predictions}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--max-length',type=int,default=1536)
    main(parser.parse_args())
