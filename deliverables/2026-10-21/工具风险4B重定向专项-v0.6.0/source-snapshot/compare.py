"""Compare independently loaded adapters on identical inputs; old tests are regression."""
import argparse
import json
from pathlib import Path
from data import SPLITS, evaluate, metrics, save
from train import runtime


def subsets(rows, inputs):
    synthetic = [r for r in rows if r['id'].startswith('SYN2-')]
    families = sorted({r['group_id'] for r in synthetic})
    commands = {}
    for row in synthetic:
        commands.setdefault(inputs[row['id']]['state']['command'], []).append(row)
    pairs = [same for same in commands.values() if len({r['label'] for r in same}) == 2]
    complete = sum(all(int(r['probability'] >= 0.5) == r['label'] for r in same) for same in pairs)
    return {'all': metrics(rows),
            'historical_observed': metrics([r for r in rows if not r['id'].startswith('SYN2-')]),
            'new_synthetic': metrics(synthetic),
            'synthetic_by_family': {g: metrics([r for r in synthetic if r['group_id'] == g]) for g in families},
            'counterfactual_commands': len(pairs), 'counterfactual_all_contexts_correct': complete,
            'counterfactual_strict_accuracy': complete/len(pairs) if pairs else None}


def main(args):
    args.mode = 'verify'
    torch, _, model, data = runtime(args)
    model.load_adapter(args.previous / 'adapter', adapter_name='previous')
    model.set_adapter('previous')
    results = {}
    for split in SPLITS[1:]:
        inputs = {r['id']: r for r in map(json.loads, (args.data / (split+'.jsonl')).read_text().splitlines())}
        previous = evaluate(model, data[split], torch)
        save(args.run / ('previous-' + split + '.json'), previous)
        base = json.loads((args.run / ('base-' + split + '.json')).read_text())
        after = json.loads((args.run / ('adapter-' + split + '.json')).read_text())
        if [r['id'] for r in previous] != [r['id'] for r in after]:
            raise ValueError('Comparison ID mismatch')
        results[split] = {'base': subsets(base, inputs), 'trial1': subsets(previous, inputs), 'trial2': subsets(after, inputs)}
    save(args.run / 'comparison.json', results)
    print(json.dumps({'comparison_complete': True, 'test': results['locked_test_candidate']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('model', 'upstream', 'data', 'run', 'previous'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--max-length', type=int, default=1536)
    main(parser.parse_args())
