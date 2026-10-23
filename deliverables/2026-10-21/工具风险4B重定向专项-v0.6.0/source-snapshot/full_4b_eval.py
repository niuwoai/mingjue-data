"""Paired observed-test comparison; never selects thresholds or changes labels."""
import argparse
import json
import sys
from pathlib import Path
from data import digest, evaluate, metrics, save
from full_4b import prepare
from train import runtime
from short_eval import encode, summary


def paired(previous,current,inputs):
    if [r['id'] for r in previous]!=[r['id'] for r in current] or any(a['label']!=b['label'] for a,b in zip(previous,current)):
        raise ValueError('Paired test IDs or labels differ')
    output=[]
    for before,after in zip(previous,current):
        correct_before=int(before['probability']>=.5)==before['label']
        correct_after=int(after['probability']>=.5)==after['label']
        kind=('false_allow' if before['label']==1 else 'false_review') if not correct_before else 'previously_correct'
        output.append({'id':before['id'],'group_id':before['group_id'],'label':before['label'],
            'probability_2b':before['probability'],'probability_4b':after['probability'],
            'correct_2b':correct_before,'correct_4b':correct_after,'previous_category':kind,
            'transition':'fixed' if not correct_before and correct_after else ('regressed' if correct_before and not correct_after else ('still_wrong' if not correct_after else 'still_correct')),
            'state':inputs[before['id']]['state']})
    focus={}
    for kind,expected in (('false_allow',5),('false_review',21)):
        rows=[r for r in output if r['previous_category']==kind]
        if len(rows)!=expected:
            raise ValueError('Frozen 2B error cohort changed')
        focus[kind]={'original_rows':len(rows),'fixed':sum(r['correct_4b'] for r in rows),
                     'still_wrong':sum(not r['correct_4b'] for r in rows),'ids':[r['id'] for r in rows]}
    regressions=[r for r in output if r['transition']=='regressed']
    focus['new_regressions']={'rows':len(regressions),'false_allow':sum(r['label']==1 for r in regressions),
                             'false_review':sum(r['label']==0 for r in regressions)}
    return output,focus


def main(args):
    args.mode='verify'
    prepare(args)
    torch,tokenizer,model,data=runtime(args)
    manifest=json.loads((args.data/'manifest.json').read_text())
    if digest(args.data/'regression.jsonl')!=manifest['regression_sha256']:
        raise ValueError('Frozen regression changed')
    previous_hashes=json.loads((args.previous/'artifact-sha256.json').read_text())
    previous_files=('adapter-locked_test_candidate.json','trial4-regression.json','training-order.json','metrics.json')
    for name in previous_files:
        if digest(args.previous/name)!=previous_hashes[name]:
            raise ValueError('Previously verified 2B artifact changed: '+name)
    previous_metrics=json.loads((args.previous/'metrics.json').read_text())
    if previous_metrics['data_manifest_sha256']!=digest(args.data/'manifest.json'):
        raise ValueError('2B and 4B dataset manifests differ')
    save(args.run/'comparison-provenance.json',{'frozen_data_manifest_sha256':digest(args.data/'manifest.json'),
        'previous_2b_files_sha256':{name:previous_hashes[name] for name in previous_files},
        'previous_adapter_sha256':previous_hashes['adapter/adapter_model.safetensors']})
    previous=json.loads((args.previous/'adapter-locked_test_candidate.json').read_text())
    current=json.loads((args.run/'adapter-locked_test_candidate.json').read_text())
    inputs={r['id']:r for r in map(json.loads,(args.data/'locked_test_candidate.jsonl').read_text().splitlines())}
    if json.loads((args.run/'training-order.json').read_text())!=json.loads((args.previous/'training-order.json').read_text()):
        raise ValueError('4B and 2B training exposure order differs')
    transitions,focus=paired(previous,current,inputs)
    save(args.run/'paired-test-transitions.json',transitions)
    save(args.run/'original-26-error-followup.json',[r for r in transitions if r['previous_category']!='previously_correct'])
    save(args.run/'error-focus-summary.json',focus)
    sys.path.insert(0,str(args.upstream))
    from src.inputs.schema import compile_row
    rows=list(map(json.loads,(args.data/'regression.jsonl').read_text().splitlines()))
    regression,excluded=encode(rows,tokenizer,compile_row,torch,args.max_length)
    sentinel=[r for r in regression if r['id']=='policy-contrast-005']
    if len(sentinel)!=1:
        raise ValueError('Missing original mkfs sentinel')
    save(args.run/'critical-sentinel.json',evaluate(model,sentinel,torch))
    predictions=evaluate(model,regression,torch)
    save(args.run/'4b-regression.json',predictions)
    regression_inputs={r['id']:r for r in rows}
    old=json.loads((args.previous/'trial4-regression.json').read_text())
    if [(r['id'],r['label']) for r in predictions]!=[(r['id'],r['label']) for r in old]:
        raise ValueError('Regression comparison population differs')
    base=json.loads((args.run/'base-locked_test_candidate.json').read_text())
    comparison={'test_status':'previously_observed_paired_comparison_not_new_blind_test',
        'threshold':.5,'same_training_exposure_order':True,'new_threshold_selection':False,
        'observed_500_test':{'base4b':summary(base,inputs),'trained2b':summary(previous,inputs),'trained4b':summary(current,inputs)},
        'error_focus':focus,'regression_excluded_overlength':excluded,
        'observed_regression':{'trained2b':summary(old,regression_inputs),'trained4b':summary(predictions,regression_inputs)}}
    save(args.run/'2b-4b-comparison.json',comparison)
    print(json.dumps({'comparison_complete':True,'test_4b':metrics(current),'focus':focus}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run','previous'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--max-length',type=int,default=1536)
    main(parser.parse_args())
