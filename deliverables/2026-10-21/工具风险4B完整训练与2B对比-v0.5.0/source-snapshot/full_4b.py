"""Full frozen-data 4B LoRA run using the same training implementation as 2B."""
import argparse
import json
from pathlib import Path
import train as engine
from data import digest, save

REVISION='1e65a988dacbcf00b84aee7366f9e47563407000'


def prepare(args):
    provenance=json.loads((args.model/'download-verification.json').read_text())
    if not provenance['all_verified'] or provenance['revision']!=REVISION or provenance['repo'].lower()!='internlm/intern-decision-4b':
        raise ValueError('Expected the verified pinned 4B base')
    engine.VERSION='0.7.0'
    engine.BASE_REVISION=REVISION
    args.run.mkdir(parents=True,exist_ok=True)
    save(args.run/'model-provenance.json',{'repo':provenance['repo'],'revision':REVISION,
         'download_verification_sha256':digest(args.model/'download-verification.json'),
         'start_from_original_base_not_probe_adapter':True,'training_engine_version':engine.VERSION})


def main(args):
    if args.mode=='train' and any((args.run/name).exists() for name in ('trace.jsonl','metrics.json')):
        raise ValueError('Refusing to overwrite an existing full 4B run')
    prepare(args)
    torch,tokenizer,model,data=engine.runtime(args)
    if args.mode=='train':
        if len(data['train'])!=4000 or len(data['locked_test_candidate'])!=500:
            raise ValueError('Expected all frozen 4000 train and 500 test rows')
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
    parser.add_argument('--balanced-draws',type=int,default=4096)
    parser.add_argument('--max-train-rows',type=int,default=0)
    main(parser.parse_args())
