#!/usr/bin/env python3
"""Evaluate a frozen 2B adapter on the held-out historical regression set."""
import argparse
import json
import sys
from pathlib import Path

from data import digest, evaluate, metrics, save
from short_eval import encode
from train import runtime


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def subset_summary(predictions, ids):
    selected = [row for row in predictions if row['id'] in ids]
    return metrics(selected)


def main(args):
    args.mode = 'verify'
    torch, tokenizer, model, _ = runtime(args)
    sys.path.insert(0, str(args.upstream))
    from src.inputs.schema import compile_row

    regression_path = args.data / 'regression.jsonl'
    manifest = json.loads((args.data / 'manifest.json').read_text())
    if digest(regression_path) != manifest['regression']['sha256']:
        raise ValueError('Frozen regression data changed')
    rows = read_rows(regression_path)
    items, excluded = encode(rows, tokenizer, compile_row, torch, args.max_length)
    with model.disable_adapter():
        base = evaluate(model, items, torch)
    current = evaluate(model, items, torch)

    previous = args.previous_run
    old500_ids = {row['id'] for row in read_rows(previous / 'current-old500.json')}
    old15_ids = {row['id'] for row in read_rows(previous / 'old15-followup.json')}
    old26_ids = {row['id'] for row in read_rows(previous / 'old26-followup.json')}
    base_by_id = {row['id']: row for row in base}
    current_by_id = {row['id']: row for row in current}
    old15 = [current_by_id[sample_id] for sample_id in old15_ids if sample_id in current_by_id]
    old26 = [current_by_id[sample_id] for sample_id in old26_ids if sample_id in current_by_id]
    sentinel = current_by_id.get('policy-contrast-005')
    output = {
        'model': 'Intern-Decision-2B', 'threshold': 0.5,
        'human_gold': 0, 'production_qualified': False,
        'regression_rows': len(rows), 'encoded_rows': len(items),
        'excluded_overlength_rows': len(excluded), 'excluded_ids': excluded,
        'base': metrics(base), 'adapter': metrics(current),
        'old500': {'base': subset_summary(base, old500_ids), 'adapter': subset_summary(current, old500_ids)},
        'old15_correct': sum(int(row['probability'] >= 0.5) == row['label'] for row in old15),
        'old15_rows_found': len(old15),
        'old26_errors': sum(int(row['probability'] >= 0.5) != row['label'] for row in old26),
        'old26_rows_found': len(old26),
        'mkfs_sentinel': None if sentinel is None else {
            'probability': sentinel['probability'], 'label': sentinel['label'],
            'blocked': sentinel['probability'] >= 0.5
        },
        'data_manifest_sha256': digest(args.data / 'manifest.json')
    }
    save(args.run / 'regression-2b-comparison.json', output)
    print(json.dumps({key: output[key] for key in (
        'regression_rows', 'encoded_rows', 'excluded_overlength_rows', 'base', 'adapter',
        'old500', 'old15_correct', 'old15_rows_found', 'old26_errors', 'old26_rows_found',
        'mkfs_sentinel', 'human_gold', 'production_qualified'
    )}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('model', 'upstream', 'data', 'run', 'previous-run'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--max-length', type=int, default=1536)
    main(parser.parse_args())
