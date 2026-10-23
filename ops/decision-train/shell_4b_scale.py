"""Fresh-base shell redirection LoRA run with a frozen, explicit train-size check."""
import argparse
from pathlib import Path
import train as engine
from full_4b import prepare


def main(args):
    if args.mode == 'train' and any((args.run / name).exists() for name in ('trace.jsonl', 'metrics.json')):
        raise ValueError('Refusing to overwrite an existing scaled shell trial')
    prepare(args)
    torch, tokenizer, model, data = engine.runtime(args)
    if args.mode == 'train':
        if len(data['train']) != args.expected_train_rows or len(data['locked_test_candidate']) != 1_200:
            raise ValueError(f'Expected {args.expected_train_rows} train and 1200 test rows')
        engine.train(args, torch, tokenizer, model, data)
    elif args.mode == 'verify':
        engine.verify(args, torch, model, data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('model', 'upstream', 'data', 'run'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--mode', choices=('audit', 'train', 'verify'), default='train')
    parser.add_argument('--max-length', type=int, default=1536)
    parser.add_argument('--accumulation', type=int, default=16)
    parser.add_argument('--balanced-draws', type=int, default=10_000)
    parser.add_argument('--max-train-rows', type=int, default=0)
    parser.add_argument('--expected-train-rows', type=int, default=10_000)
    main(parser.parse_args())
