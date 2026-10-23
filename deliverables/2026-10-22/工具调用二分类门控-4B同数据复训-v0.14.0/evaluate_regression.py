#!/usr/bin/env python3
"""Frozen historical regression evaluation; accepts JSON array or JSONL reference files."""
import argparse
import json
import sys
from pathlib import Path

from data import digest, evaluate, metrics, save
from short_eval import encode
from train import runtime


def read_rows(path):
    text = Path(path).read_text()
    if text.lstrip().startswith('['):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def subset(predictions, ids):
    return metrics([row for row in predictions if row['id'] in ids])


def write_predictions(path, rows, threshold=0.5):
    lines = []
    for row in rows:
        blocked = row['probability'] >= threshold
        lines.append(json.dumps({
            'id': row['id'], 'group_id': row['group_id'], 'label': row['label'],
            'probability': row['probability'], 'blocked': blocked,
            'correct': int(blocked) == row['label'],
        }, ensure_ascii=False, sort_keys=True))
    path.write_text('\n'.join(lines) + '\n')
    return {'path': path.name, 'rows': len(lines), 'sha256': digest(path)}


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
    old500 = {row['id'] for row in read_rows(args.previous_run / 'current-old500.json')}
    old15 = {row['id'] for row in read_rows(args.previous_run / 'old15-followup.json')}
    old26 = {row['id'] for row in read_rows(args.previous_run / 'old26-followup.json')}
    by_id = {row['id']: row for row in current}
    old15_rows = [by_id[sample_id] for sample_id in old15 if sample_id in by_id]
    old26_rows = [by_id[sample_id] for sample_id in old26 if sample_id in by_id]
    sentinel = by_id.get('policy-contrast-005')
    predictions = {
        'adapter': write_predictions(args.run / 'regression-predictions-adapter.jsonl', current),
        'base': write_predictions(args.run / 'regression-predictions-base.jsonl', base),
    }
    output = {
        'model': args.model_name, 'threshold': 0.5, 'human_gold': 0, 'production_qualified': False,
        'regression_rows': len(rows), 'encoded_rows': len(items),
        'excluded_overlength_rows': len(excluded), 'excluded_ids': excluded,
        'base': metrics(base), 'adapter': metrics(current),
        'always_allow': metrics([dict(row, probability=0.0) for row in current]),
        'old500': {'base': subset(base, old500), 'adapter': subset(current, old500)},
        'old15_correct': sum(int(row['probability'] >= 0.5) == row['label'] for row in old15_rows),
        'old15_rows_found': len(old15_rows),
        'old26_errors': sum(int(row['probability'] >= 0.5) != row['label'] for row in old26_rows),
        'old26_rows_found': len(old26_rows),
        'mkfs_sentinel': None if sentinel is None else {
            'probability': sentinel['probability'], 'label': sentinel['label'],
            'blocked': sentinel['probability'] >= 0.5
        },
        'data_manifest_sha256': digest(args.data / 'manifest.json'),
        'predictions': predictions,
    }
    save(args.run / 'regression-comparison.json', output)
    print(json.dumps({key: output[key] for key in (
        'model', 'regression_rows', 'encoded_rows', 'excluded_overlength_rows', 'base', 'adapter',
        'old500', 'old15_correct', 'old15_rows_found', 'old26_errors', 'old26_rows_found',
        'mkfs_sentinel', 'human_gold', 'production_qualified', 'predictions')}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('model', 'upstream', 'data', 'run', 'previous-run'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--max-length', type=int, default=1536)
    parser.add_argument('--model-name', default='unknown')
    main(parser.parse_args())
