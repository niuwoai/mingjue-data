"""Frozen new disk test plus previously observed regression, with two adapters."""
import argparse
import json
import sys
from pathlib import Path
from data import digest, evaluate, metrics, save
from train import runtime


def encode(rows, tokenizer, compile_row, torch, max_length):
    items, excluded = [], []
    for row in rows:
        compiled = compile_row(row)
        text = tokenizer.apply_chat_template(compiled.messages, tokenize=False,
            add_generation_prompt=False, enable_thinking=False, add_vision_id=True)
        batch = tokenizer(text, add_special_tokens=False, return_tensors='pt')
        if batch.input_ids.shape[1] > max_length:
            excluded.append(row['id'])
            continue
        position = (batch.input_ids[0] == tokenizer.convert_tokens_to_ids('<decision>')).nonzero().flatten()-1
        tokens = [tokenizer.encode(s, add_special_tokens=False) for s in compiled.symbols['gate']]
        if len(position) != 1 or any(len(t) != 1 for t in tokens):
            raise ValueError('Invalid native decision encoding')
        items.append({'id':row['id'],'group_id':row['group_id'],'batch':batch,'position':position,
                      'candidates':[t[0] for t in tokens],'label':int(row['targets']['gate']['label']=='needs_review')})
    return items, excluded


def summary(predictions, inputs):
    by_command = {}
    for r in predictions:
        key = inputs[r['id']]['state']['command']
        by_command.setdefault(key, []).append(r)
    pairs = [v for v in by_command.values() if len({r['label'] for r in v}) == 2]
    passed = sum(all(int(r['probability'] >= .5)==r['label'] for r in v) for v in pairs)
    groups = sorted({r['group_id'] for r in predictions})
    return {'all':metrics(predictions),'counterfactual_commands':len(pairs),
            'counterfactual_passed':passed,'counterfactual_accuracy':passed/len(pairs) if pairs else None,
            'families':{g:metrics([r for r in predictions if r['group_id']==g]) for g in groups},
            'historical':metrics([r for r in predictions if r['id'].startswith('CDX10-')]),
            'old_policy':metrics([r for r in predictions if r['id'].startswith('policy-contrast-')]),
            'prior_rich_disk':metrics([r for r in predictions if r['id'].startswith('DSK3-')]),
            'no_observation_field':metrics([r for r in predictions if 'observed_target_evidence' not in inputs[r['id']]['state']]),
            'empty_user_context':metrics([r for r in predictions if not inputs[r['id']]['state'].get('visible_user_context_candidates')]),
            'old_synthetic':metrics([r for r in predictions if r['id'].startswith('SYN2-')])}


def main(args):
    args.mode='verify'
    torch, tokenizer, model, data = runtime(args)
    sys.path.insert(0,str(args.upstream))
    from src.inputs.schema import compile_row
    manifest=json.loads((args.data/'manifest.json').read_text())
    if digest(args.data/'regression.jsonl') != manifest['regression_sha256']:
        raise ValueError('Regression data changed')
    regression_rows=[json.loads(l) for l in (args.data/'regression.jsonl').read_text().splitlines()]
    regression, excluded=encode(regression_rows,tokenizer,compile_row,torch,args.max_length)
    test_inputs={r['id']:r for r in map(json.loads,(args.data/'locked_test_candidate.jsonl').read_text().splitlines())}
    regression_inputs={r['id']:r for r in regression_rows}
    sentinel=[r for r in regression if r['id']=='policy-contrast-005']
    if len(sentinel)!=1:
        raise ValueError('Missing original mkfs regression')
    save(args.run/'critical-sentinel.json',evaluate(model,sentinel,torch))
    model.load_adapter(args.previous/'adapter',adapter_name='previous')
    model.set_adapter('previous')
    previous_test=evaluate(model,data['locked_test_candidate'],torch)
    previous_regression=evaluate(model,regression,torch)
    model.set_adapter('default')
    current_regression=evaluate(model,regression,torch)
    with model.disable_adapter():
        base_regression=evaluate(model,regression,torch)
    base_test=json.loads((args.run/'base-locked_test_candidate.json').read_text())
    current_test=json.loads((args.run/'adapter-locked_test_candidate.json').read_text())
    output={'new_short_test':{},'observed_regression':{},'regression_excluded_overlength':excluded}
    for name, test, old in [('base',base_test,base_regression),('trial3',previous_test,previous_regression),('trial4',current_test,current_regression)]:
        if [r['id'] for r in test] != [r['id'] for r in current_test]:
            raise ValueError('Test comparison IDs differ')
        save(args.run/(name+'-new-test.json'),test)
        save(args.run/(name+'-regression.json'),old)
        output['new_short_test'][name]=summary(test,test_inputs)
        output['observed_regression'][name]=summary(old,regression_inputs)
    save(args.run/'short-comparison.json',output)
    print(json.dumps({'disk_comparison_complete':True,'trial4_test':output['new_short_test']['trial4']['all'],
                      'trial4_old_policy':output['observed_regression']['trial4']['old_policy']}),flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run','previous'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--max-length',type=int,default=1536)
    main(parser.parse_args())
