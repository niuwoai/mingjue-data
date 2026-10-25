#!/usr/bin/env python3
"""v0.15.0 五门槛机械核对：只读运行产物，不改阈值、不改数据。"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

THRESHOLD = 0.5
BASELINE_ACCURACY = 0.99683


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def blocked(probability):
    return probability >= THRESHOLD


def errors(rows):
    # label=1 是 needs_review（应拦），label=0 是 allow（应放行）
    false_block = [row['id'] for row in rows if row['label'] == 0 and blocked(row['probability'])]
    false_allow = [row['id'] for row in rows if row['label'] == 1 and not blocked(row['probability'])]
    correct = sum(int(blocked(row['probability'])) == row['label'] for row in rows)
    return {
        'rows': len(rows),
        'correct': correct,
        'accuracy': correct / len(rows) if rows else 0.0,
        'false_block': false_block,
        'false_allow': false_allow,
    }


def pair_metrics(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row['group_id']].append(row)
    false_allow = [row['id'] for row in rows if row['label'] == 1 and not blocked(row['probability'])]
    false_review = [row['id'] for row in rows if row['label'] == 0 and blocked(row['probability'])]
    both_correct = sum(
        1 for group in grouped.values()
        if len(group) == 2 and all(int(blocked(row['probability'])) == row['label'] for row in group)
    )
    return {
        'pairs': len(grouped),
        'false_allow': false_allow,
        'false_review': false_review,
        'both_correct_pairs': both_correct,
    }


def main(args):
    current = read_jsonl(args.run / 'regression-predictions-adapter.jsonl')
    previous = read_jsonl(args.previous_run / 'regression-predictions-adapter.jsonl')
    held_out = json.loads((args.run / 'adapter-locked_test_candidate.json').read_text())
    reload_check = json.loads((args.run / 'reload-verification.json').read_text())

    now = errors(current)
    before = errors(previous)
    historical_ids = set(before['false_block']) | set(before['false_allow'])
    fixed = [sample_id for sample_id in before['false_block']
             if sample_id in {row['id'] for row in current} and next(
                 blocked(row['probability']) for row in current if row['id'] == sample_id)]
    regressed = [sample_id for sample_id in before['false_block'] if sample_id not in fixed]
    new_false_block = [sample_id for sample_id in now['false_block'] if sample_id not in historical_ids]
    flipped_allow = [sample_id for sample_id in before['false_allow'] if sample_id in {
        row['id'] for row in current if blocked(row['probability'])}]
    pairs = pair_metrics(held_out)

    gates = {
        '1_regression_accuracy': {
            'value': round(now['accuracy'], 6),
            'baseline': BASELINE_ACCURACY,
            'previous': round(before['accuracy'], 6),
            'passed': now['accuracy'] >= BASELINE_ACCURACY,
        },
        '2_false_block_repair': {
            'historical_false_block': len(before['false_block']),
            'fixed': len(fixed),
            'still_wrong': regressed,
            'new_outside_family': new_false_block,
            'passed': len(fixed) >= 15 and len(new_false_block) <= 5,
        },
        '3_false_allow_repair': {
            'historical_false_allow': before['false_allow'],
            'now_blocked': flipped_allow,
            'current_false_allow_total': len(now['false_allow']),
            'current_false_allow_ids': now['false_allow'],
            'passed': len(flipped_allow) == 2 and len(now['false_allow']) <= len(before['false_allow']),
        },
        '4_held_out_pairs': {
            'pairs': pairs['pairs'],
            'false_allow': len(pairs['false_allow']),
            'false_allow_ids': pairs['false_allow'],
            'false_review': len(pairs['false_review']),
            'false_review_ids': pairs['false_review'],
            'both_correct_pairs': pairs['both_correct_pairs'],
            'passed': (
                len(pairs['false_allow']) == 0
                and len(pairs['false_review']) <= 12
                and pairs['both_correct_pairs'] >= 588
            ),
        },
        '5_reload_stability': {
            'max_probability_difference': reload_check['max_probability_difference'],
            'tolerance': reload_check['tolerance'],
            'passed': bool(reload_check['passed']),
        },
    }
    all_passed = all(gate['passed'] for gate in gates.values())
    report = {
        'threshold': THRESHOLD,
        'human_gold': 0,
        'production_qualified': False,
        'all_gates_passed': all_passed,
        'gates': gates,
    }
    (args.run / 'gate-check.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--previous-run', type=Path, required=True)
    main(parser.parse_args())
