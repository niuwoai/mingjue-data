#!/usr/bin/env python3
"""Join per-row regression predictions with the frozen regression rows and list errors."""
import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

FEATURES = [
    ('sudo', re.compile(r'(^|[\s;&|])sudo\s')),
    ('pipe_or_chain', re.compile(r'\|\||&&|[|;]')),
    ('redirect', re.compile(r'(?<![0-9])>{1,2}(?!&)')),
    ('rm', re.compile(r'(^|[\s;&|])rm\s')),
    ('remote', re.compile(r'(^|[\s;&|])(ssh|scp|rsync|curl|wget|git\s+(push|clone|fetch))\s')),
    ('disk', re.compile(r'\b(mkfs|fdisk|sfdisk|parted|mkswap|wipefs)\b')),
    ('write_word', re.compile(r'(^|[\s;&|])(tee|dd|install|cp|mv|truncate|touch|mkdir|ln)\s')),
]


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def primary_token(command):
    text = command.strip()
    while True:
        match = re.match(r'^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+|cd\s+\S+\s*&&\s*)', text)
        if not match:
            break
        text = text[match.end():]
    head = re.split(r'[\s|;&]', text.strip())[0] if text.strip() else ''
    return Path(head).name if head else 'empty'


def flags(command):
    return [name for name, pattern in FEATURES if pattern.search(command)]


def context_text(row):
    state = row.get('state', {})
    candidates = state.get('visible_user_context_candidates') or []
    return candidates[0] if candidates else ''


def describe(row, probability, base_probability):
    state = row.get('state', {})
    command = state.get('command', '')
    return {
        'id': row['id'], 'group_id': row['group_id'], 'label': row['targets']['gate']['label'],
        'probability': probability, 'base_probability': base_probability,
        'primary_token': primary_token(command), 'flags': flags(command),
        'command': command, 'cwd': state.get('cwd', ''),
        'context': context_text(row),
    }


def main(args):
    rows = {row['id']: row for row in read_jsonl(args.data / 'regression.jsonl')}
    adapter = {row['id']: row for row in read_jsonl(args.predictions)}
    base = {row['id']: row for row in read_jsonl(args.base_predictions)}
    threshold = args.threshold
    false_block, false_allow, pairs, missing = [], [], [], []
    for sample_id, prediction in adapter.items():
        label = prediction['label']
        blocked = prediction['probability'] >= threshold
        base_probability = base[sample_id]['probability'] if sample_id in base else None
        source = rows.get(sample_id)
        if source is None:
            missing.append(sample_id)
        elif blocked and label == 0:
            false_block.append(describe(source, prediction['probability'], base_probability))
        elif not blocked and label == 1:
            false_allow.append(describe(source, prediction['probability'], base_probability))
        if sample_id in base:
            base_blocked = base_probability >= threshold
            if base_blocked != blocked:
                pairs.append({'id': sample_id, 'label': label, 'adapter_blocked': blocked,
                              'base_blocked': base_blocked})
    output = {
        'threshold': threshold, 'evaluated_rows': len(adapter),
        'data_regression_sha256': sha256(args.data / 'regression.jsonl'),
        'predictions_sha256': sha256(args.predictions),
        'base_predictions_sha256': sha256(args.base_predictions),
        'false_block': false_block, 'false_allow': false_allow,
        'false_block_by_primary_token': dict(Counter(r['primary_token'] for r in false_block).most_common()),
        'false_allow_by_primary_token': dict(Counter(r['primary_token'] for r in false_allow).most_common()),
        'adapter_vs_base_disagreements': len(pairs),
        'missing_source_rows': sorted(missing),
    }
    Path(args.out).write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'false_block': len(false_block), 'false_allow': len(false_allow),
                      'disagreements': len(pairs)}))
    for name in ('false_block', 'false_allow'):
        print('\n== ' + name + ' ==')
        for row in output[name]:
            print(json.dumps({key: row[key] for key in
                              ('id', 'label', 'probability', 'base_probability', 'primary_token', 'flags', 'command')},
                             ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('data', 'predictions', 'base-predictions', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--threshold', type=float, default=0.5)
    main(parser.parse_args())
