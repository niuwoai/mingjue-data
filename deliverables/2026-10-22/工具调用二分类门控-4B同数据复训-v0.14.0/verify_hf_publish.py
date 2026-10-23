#!/usr/bin/env python3
"""Load a published Hugging Face adapter through the training repo's own verify path
and re-score frozen regression rows, asserting the recorded probabilities reproduce."""
import argparse
import json
import sys
from pathlib import Path

THRESHOLD = 0.5
TOLERANCE = 1e-6
SENTINELS = ('policy-contrast-005', 'SHT4-write_shell_holdout-5-0')


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def pick_ids(rows, count=3):
    allow = [r['id'] for r in rows if r['targets']['gate']['label'] == 'allow'][:count]
    review = [r['id'] for r in rows if r['targets']['gate']['label'] == 'needs_review'][:count]
    return allow + review


def main(args):
    sys.path.insert(0, str(args.repo))
    sys.path.insert(0, str(args.upstream))
    from train import runtime
    from data import score
    from short_eval import encode
    from src.inputs.schema import compile_row

    class RuntimeArgs:
        mode = 'verify'
        model = args.base
        upstream = args.upstream
        data = args.data
        run = args.adapter_run
        max_length = args.max_length

    torch, tokenizer, model, _ = runtime(RuntimeArgs)
    model_class = type(model.get_base_model()).__name__

    recorded = {row['id']: row for row in read_jsonl(args.predictions)}
    dataset = read_jsonl(args.regression)
    by_id = {row['id']: row for row in dataset}
    ids = [sid for sid in SENTINELS if sid in by_id]
    ids += [sid for sid in pick_ids(dataset) if sid not in ids]

    items, excluded = encode([by_id[sid] for sid in ids], tokenizer, compile_row, torch, args.max_length)
    if excluded:
        raise ValueError('sample rows must not exceed max length: ' + ','.join(excluded))

    rows, mismatches = [], []
    for item in items:
        with torch.no_grad():
            adapter_p = score(model, item)[0, item['candidates']].softmax(-1)[1].item()
            with model.disable_adapter():
                base_p = score(model, item)[0, item['candidates']].softmax(-1)[1].item()
        expected = recorded[item['id']]
        blocked = adapter_p >= THRESHOLD
        row = {'id': item['id'], 'group_id': item['group_id'], 'label': item['label'],
               'tokens': int(item['batch'].input_ids.shape[1]),
               'recorded_probability': expected['probability'], 'adapter_probability': adapter_p,
               'base_probability': base_p, 'blocked': blocked,
               'matches_recorded': abs(adapter_p - expected['probability']) <= TOLERANCE,
               'matches_recorded_decision': int(blocked) == expected['blocked'],
               'decision_correct': int(blocked) == item['label']}
        rows.append(row)
        if not (row['matches_recorded'] and row['matches_recorded_decision']):
            mismatches.append(item['id'])
        print(json.dumps(row, ensure_ascii=False), flush=True)

    output = {'adapter_dir': str(args.adapter_run), 'base_model_dir': str(args.base),
              'model_class': model_class, 'threshold': THRESHOLD, 'tolerance': TOLERANCE,
              'rows_checked': len(rows), 'mismatches': mismatches, 'reproduced': not mismatches,
              'rows': rows}
    Path(args.out).write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'reproduced': output['reproduced'], 'rows_checked': len(rows),
                      'model_class': model_class, 'mismatches': mismatches}), flush=True)
    return 0 if not mismatches else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('repo', 'base', 'upstream', 'data', 'adapter-run', 'regression', 'predictions', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--max-length', type=int, default=1536)
    sys.exit(main(parser.parse_args()))
