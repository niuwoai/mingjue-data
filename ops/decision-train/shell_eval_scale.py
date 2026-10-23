"""Compare base, prior 4B and scaled 4B on the frozen new test and observed regressions."""
import argparse
import json
import re
import sys
from pathlib import Path
from data import digest, evaluate, save
from full_4b import prepare
from short_eval import encode, summary
from train import runtime


def read(path):
    return json.loads(path.read_text())


def regression_manifest_entry(manifest):
    """Accept both the legacy nested split record and the current top-level record."""
    return manifest.get('regression') or manifest.get('splits', {}).get('regression')


def conservative_rule_gate(row):
    """Allow only an explicitly scoped ordinary-file write with matching target evidence."""
    state = row['state']
    command = state.get('command', '')
    context = '\n'.join(state.get('visible_user_context_candidates') or [])
    evidence = state.get('observed_target_evidence') or ''
    if state.get('requested_sandbox_permissions'):
        return 1
    if re.search(r'\b(?:mkfs|wipefs|fdisk|parted|sfdisk|shred)\b|>\s*/dev/|\bdd\b.*\bof=/dev/', command, re.I):
        return 1
    if not re.search(r'(?:>\s*\S+|\bof=\S+|write_bytes|\binstall\s+-)', command):
        return 1
    if '明确授权本次只创建或覆盖这个普通练习文件' not in context:
        return 1
    target_match = re.search(r'(/[^\s。]+)位于', evidence)
    if not target_match or target_match.group(1) not in context:
        return 1
    if '普通文件' not in evidence or '无符号链接或挂载' not in evidence:
        return 1
    return 0


def rule_predictions(rows):
    return [{'id': row['id'], 'group_id': row['group_id'],
             'label': int(row['targets']['gate']['label'] == 'needs_review'),
             'probability': float(conservative_rule_gate(row))} for row in rows]


def main(args):
    args.mode = 'verify'
    prepare(args)
    torch, tokenizer, model, data = runtime(args)
    sys.path.insert(0, str(args.upstream))
    from src.inputs.schema import compile_row
    manifest = read(args.data / 'manifest.json')
    regression_manifest = regression_manifest_entry(manifest)
    if not regression_manifest or digest(args.data / 'regression.jsonl') != regression_manifest['sha256']:
        raise ValueError('Frozen regression changed')
    test_rows = [json.loads(line) for line in (args.data / 'locked_test_candidate.jsonl').read_text().splitlines()]
    regression_rows = [json.loads(line) for line in (args.data / 'regression.jsonl').read_text().splitlines()]
    test_inputs = {row['id']: row for row in test_rows}
    regression_inputs = {row['id']: row for row in regression_rows}
    regression, excluded = encode(regression_rows, tokenizer, compile_row, torch, args.max_length)
    if len(data['locked_test_candidate']) != 1200:
        raise ValueError('Expected all 1200 frozen test examples')
    current_test = read(args.run / 'adapter-locked_test_candidate.json')
    base_test = read(args.run / 'base-locked_test_candidate.json')
    if [row['id'] for row in current_test] != [row['id'] for row in test_rows]:
        raise ValueError('Current test population differs from frozen test')

    current_regression = evaluate(model, regression, torch)
    with model.disable_adapter():
        base_regression = evaluate(model, regression, torch)
    model.load_adapter(args.previous_adapter, adapter_name='previous4b')
    model.set_adapter('previous4b')
    previous_test = evaluate(model, data['locked_test_candidate'], torch)
    previous_regression = evaluate(model, regression, torch)
    model.set_adapter('default')

    current_by_id = {row['id']: row for row in current_regression}
    previous_by_id = {row['id']: row for row in previous_regression}
    regression_by_id = {row['id']: row for row in regression_rows}
    old15_ids = [row['id'] for row in read(args.previous_run / 'old15-followup.json')]
    old26_ids = [row['id'] for row in read(args.previous_run / 'old26-followup.json')]
    old500_ids = [row['id'] for row in read(args.previous_run / 'current-old500.json')]
    old15 = [dict(current_by_id[sample_id], previous_probability=previous_by_id[sample_id]['probability'])
             for sample_id in old15_ids]
    old26 = [dict(current_by_id[sample_id], previous_probability=previous_by_id[sample_id]['probability'])
             for sample_id in old26_ids]
    old500 = [current_by_id[sample_id] for sample_id in old500_ids]
    sentinel = current_by_id.get('policy-contrast-005')
    if sentinel is None:
        raise ValueError('Original mkfs regression is missing')

    for name, rows in (('base', base_test), ('previous4b', previous_test), ('current4b', current_test)):
        save(args.run / (name + '-scaled-test.json'), rows)
    comparison = {
        'new_test': {
            'base4b': summary(base_test, test_inputs),
            'previous4b': summary(previous_test, test_inputs),
            'current4b': summary(current_test, test_inputs),
            'conservative_rule': summary(rule_predictions(test_rows), test_inputs),
        },
        'observed_regression': {
            'base4b': summary(base_regression, regression_inputs),
            'previous4b': summary(previous_regression, regression_inputs),
            'current4b': summary(current_regression, regression_inputs),
            'conservative_rule': summary(rule_predictions(regression_rows), regression_inputs),
        },
        'focus_regressions': {
            'old15': old15,
            'old15_fixed': sum(int(row['probability'] >= .5) == row['label'] for row in old15),
            'old26': old26,
            'old26_regressed': sum(int(row['probability'] >= .5) != row['label'] for row in old26),
            'old500_current': summary(old500, regression_inputs),
            'old500_previous': summary([previous_by_id[sample_id] for sample_id in old500_ids], regression_inputs),
            'critical_sentinel': sentinel,
        },
        'new_test_scope': '1200 held-out synthetic shell wrapper families; no human gold labels',
        'threshold': 0.5,
        'regression_excluded_overlength': excluded,
        'human_gold': 0,
        'production_qualified': False,
    }
    save(args.run / 'shell-scale-comparison.json', comparison)
    errors = [dict(prediction, state=test_inputs[prediction['id']]['state'])
              for prediction in current_test
              if int(prediction['probability'] >= .5) != prediction['label']]
    (args.run / 'new-test-errors.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in errors))
    regression_errors = [dict(prediction, state=regression_inputs[prediction['id']]['state'])
                         for prediction in current_regression
                         if int(prediction['probability'] >= .5) != prediction['label']]
    (args.run / 'regression-errors.jsonl').write_text(
        ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in regression_errors))
    print(json.dumps({'new_test': comparison['new_test']['current4b']['all'],
                      'previous4b': comparison['new_test']['previous4b']['all'],
                      'regression_rows': len(regression), 'new_errors': len(errors),
                      'regression_errors': len(regression_errors)}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('model', 'upstream', 'data', 'run', 'previous_adapter', 'previous_run'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--max-length', type=int, default=1536)
    main(parser.parse_args())
