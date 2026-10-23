"""Frozen new shell holdout plus separately tracked observed regressions."""
import argparse
import json
import sys
from pathlib import Path
from data import digest, evaluate, metrics, save
from full_4b import prepare
from train import runtime
from short_eval import encode, summary


def read(path):
    return json.loads(path.read_text())


def cohort(current,previous,ids):
    a={r['id']:r for r in previous}
    b={r['id']:r for r in current}
    result=[]
    for name in ids:
        before,after=a[name],b[name]
        if before['label']!=after['label']:
            raise ValueError('Cohort label changed')
        result.append({'id':name,'label':after['label'],'previous_probability':before['probability'],
            'current_probability':after['probability'],'current_correct':int(after['probability']>=.5)==after['label']})
    return result


def main(args):
    args.mode='verify'
    prepare(args)
    torch,tokenizer,model,data=runtime(args)
    manifest=read(args.data/'manifest.json')
    if digest(args.data/'regression.jsonl')!=manifest['regression_sha256']:
        raise ValueError('Frozen regression changed')
    sys.path.insert(0,str(args.upstream))
    from src.inputs.schema import compile_row
    raw=list(map(json.loads,(args.data/'regression.jsonl').read_text().splitlines()))
    regression,excluded=encode(raw,tokenizer,compile_row,torch,args.max_length)
    inputs={r['id']:r for r in raw}
    test_inputs={r['id']:r for r in map(json.loads,(args.data/'locked_test_candidate.jsonl').read_text().splitlines())}
    provenance={'current_data_manifest_sha256':digest(args.data/'manifest.json'),'previous_files_sha256':{}}
    for folder,names in ((args.previous,('adapter-locked_test_candidate.json','4b-regression.json','original-26-error-followup.json','adapter/adapter_model.safetensors')),
                         (args.previous2b,('adapter-locked_test_candidate.json','trial4-regression.json'))):
        hashes=read(folder/'artifact-sha256.json')
        for name in names:
            if digest(folder/name)!=hashes[name]:
                raise ValueError('Prior observed artifact changed: '+name)
        provenance['previous_files_sha256'][folder.name]={name:hashes[name] for name in names}
    save(args.run/'comparison-provenance.json',provenance)
    current_test=read(args.run/'adapter-locked_test_candidate.json')
    current_old=evaluate(model,regression,torch)
    save(args.run/'current-regression.json',current_old)
    sentinel=[r for r in current_old if r['id']=='policy-contrast-005']
    if len(sentinel)!=1:
        raise ValueError('Original mkfs missing')
    save(args.run/'critical-sentinel.json',sentinel)
    prior500=read(args.previous/'adapter-locked_test_candidate.json')
    prior_old=read(args.previous/'4b-regression.json')+prior500
    two_old=read(args.previous2b/'trial4-regression.json')+read(args.previous2b/'adapter-locked_test_candidate.json')
    if [(r['id'],r['label']) for r in current_old]!=[(r['id'],r['label']) for r in prior_old] or [(r['id'],r['label']) for r in current_old]!=[(r['id'],r['label']) for r in two_old]:
        raise ValueError('Observed regression populations differ')
    old500_ids={r['id'] for r in prior500}
    now500=[r for r in current_old if r['id'] in old500_ids]
    old15=[r['id'] for r in prior500 if r['label']==1 and r['probability']<.5]
    if len(old15)!=15:
        raise ValueError('Original 15-case cohort changed')
    focus15=cohort(now500,prior500,old15)
    old26=[r['id'] for r in read(args.previous/'original-26-error-followup.json')]
    focus26=cohort(now500,prior500,old26)
    lookup={r['id']:r for r in prior500}
    new_errors=[r for r in now500 if int(lookup[r['id']]['probability']>=.5)==r['label'] and int(r['probability']>=.5)!=r['label']]
    save(args.run/'old15-followup.json',focus15)
    save(args.run/'old26-followup.json',focus26)
    save(args.run/'current-old500.json',now500)
    save(args.run/'new-old500-regressions.json',new_errors)
    focus={'old15_fixed':sum(r['current_correct'] for r in focus15),'old15_remaining':sum(not r['current_correct'] for r in focus15),
           'old26_regressed':sum(not r['current_correct'] for r in focus26),'new_old500_errors':metrics(new_errors),
           'old500_current':summary(now500,inputs),'old500_previous':summary(prior500,inputs)}
    save(args.run/'focus-summary.json',focus)
    model.load_adapter(args.previous/'adapter',adapter_name='previous4b')
    model.set_adapter('previous4b')
    previous_test=evaluate(model,data['locked_test_candidate'],torch)
    save(args.run/'previous4b-new-test.json',previous_test)
    base_test=read(args.run/'base-locked_test_candidate.json')
    save(args.run/'current-new-test.json',current_test)
    if [(r['id'],r['label']) for r in current_test]!=[(r['id'],r['label']) for r in previous_test]:
        raise ValueError('New holdout comparison IDs differ')
    output={'new_600_test':{'base4b':summary(base_test,test_inputs),'previous4b':summary(previous_test,test_inputs),'current4b':summary(current_test,test_inputs)},
            'observed_regression':{'previous2b':summary(two_old,inputs),'previous4b':summary(prior_old,inputs),'current4b':summary(current_old,inputs)},
            'focus':focus,'regression_excluded_overlength':excluded,'fixed_threshold':.5,'human_gold':0,
            'new_test_scope':'held-out shell wrapper/target/task combinations; shared operation semantics and some templates; synthetic, not human gold'}
    save(args.run/'shell-comparison.json',output)
    print(json.dumps({'shell_evaluation_complete':True,'new_test':metrics(current_test),'old15_fixed':focus['old15_fixed'],'old26_regressed':focus['old26_regressed']}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run','previous','previous2b'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--max-length',type=int,default=1536)
    main(parser.parse_args())
