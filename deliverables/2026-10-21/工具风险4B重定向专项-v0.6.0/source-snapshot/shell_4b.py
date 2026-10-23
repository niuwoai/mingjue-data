"""Fresh-base 6000-row shell redirection LoRA run; no observed-test tuning."""
import argparse
from pathlib import Path
import train as engine
from full_4b import prepare


def main(args):
    if args.mode=='train' and any((args.run/name).exists() for name in ('trace.jsonl','metrics.json')):
        raise ValueError('Refusing to overwrite a shell trial')
    prepare(args)
    torch,tokenizer,model,data=engine.runtime(args)
    if args.mode=='train':
        if len(data['train'])!=6000 or len(data['locked_test_candidate'])!=600:
            raise ValueError('Frozen shell dataset must retain all 6000 train and 600 test rows')
        engine.train(args,torch,tokenizer,model,data)
    elif args.mode=='verify':
        engine.verify(args,torch,model,data)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--mode',choices=('audit','train','verify'),default='train')
    parser.add_argument('--max-length',type=int,default=1536)
    parser.add_argument('--accumulation',type=int,default=16)
    parser.add_argument('--balanced-draws',type=int,default=6016)
    parser.add_argument('--max-train-rows',type=int,default=0)
    main(parser.parse_args())
