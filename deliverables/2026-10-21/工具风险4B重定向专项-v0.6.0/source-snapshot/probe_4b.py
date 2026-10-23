"""BF16 LoRA engineering probe only; does not measure business-model quality."""
import argparse
import copy
import json
import math
from pathlib import Path
import time
from data import evaluate, save, score
from train import alignment_audit, checkpoint, runtime


def pad_stress(item, length, tokenizer, torch):
    if item['length']>length:
        raise ValueError('Stress source longer than requested length')
    result=copy.deepcopy(item)
    count=length-item['length']
    token=tokenizer.encode(' note',add_special_tokens=False)[0]
    for key,value in result['batch'].items():
        fill=token if key=='input_ids' else (1 if key=='attention_mask' else 0)
        prefix=torch.full((1,count),fill,dtype=value.dtype)
        result['batch'][key]=torch.cat((value[:,:1],prefix,value[:,1:]),dim=1)
    result['position']=result['position']+count
    result['length']=length
    result['id']=f"engineering-padding-{length}-"+item['id']
    return result


def fixtures(data, tokenizer, torch):
    short=min(data['train'],key=lambda r:r['length'])
    longest=max(data['train'],key=lambda r:r['length'])
    return [short,pad_stress(short,512,tokenizer,torch),longest,pad_stress(longest,1536,tokenizer,torch)]


def run(args):
    import torch
    verification=json.loads((args.model/'download-verification.json').read_text())
    if not verification['all_verified'] or verification['revision']!='1e65a988dacbcf00b84aee7366f9e47563407000':
        raise ValueError('Unverified 4B checkpoint')
    requested=args.mode
    if requested=='train' and (args.run/'probe-metrics.json').exists():
        raise ValueError('Refusing to overwrite completed probe')
    args.run.mkdir(parents=True,exist_ok=True)
    torch,tokenizer,model,data=runtime(args)
    items=fixtures(data,tokenizer,torch)
    if requested=='verify':
        reference=json.loads((args.run/'probe-after.json').read_text())
        actual=evaluate(model,items,torch)
        if [r['id'] for r in actual] != [r['id'] for r in reference]:
            raise ValueError('Probe fixtures changed')
        difference=max(abs(a['probability']-b['probability']) for a,b in zip(actual,reference))
        save(args.run/'probe-reload.json',{'fresh_process':True,'rows':len(items),'max_difference':difference,'passed':difference<=0.002})
        if difference>0.002:
            raise ValueError('4B probe reload mismatch')
        print(json.dumps({'probe_reload_passed':True,'difference':difference}),flush=True)
        return
    alignment_audit(model,items[0],torch,args.run)
    parameters=[p for p in model.parameters() if p.requires_grad]
    if any('lora_' not in n for n,p in model.named_parameters() if p.requires_grad):
        raise ValueError('Unexpected base/vision training')
    initial=[p.detach().cpu().clone() for p in parameters]
    optimizer=torch.optim.AdamW(parameters,lr=5e-5)
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant':False})
    model.enable_input_require_grads()
    model.train()
    trace=[]
    start=time.perf_counter()
    for step in range(2):
        optimizer.zero_grad(set_to_none=True)
        for item in items:
            tick=time.perf_counter()
            loss=torch.nn.functional.cross_entropy(score(model,item),item['target'].to('cuda'))
            if not math.isfinite(loss.item()):
                raise ValueError('Non-finite 4B probe loss')
            (loss/len(items)).backward()
            torch.cuda.synchronize()
            trace.append({'step':step+1,'id':item['id'],'tokens':item['length'],'loss':loss.item(),
                          'seconds':time.perf_counter()-tick,'peak_reserved_bytes':torch.cuda.max_memory_reserved()})
        norm=torch.nn.utils.clip_grad_norm_(parameters,1.0)
        if not math.isfinite(norm.item()):
            raise ValueError('Non-finite probe gradient')
        optimizer.step()
        print(json.dumps({'probe_optimizer_step':step+1,'peak_reserved_bytes':torch.cuda.max_memory_reserved()}),flush=True)
    changed=sum(not torch.equal(before,p.detach().cpu()) for before,p in zip(initial,parameters))
    if not changed:
        raise ValueError('No 4B LoRA tensor changed')
    checkpoint(args,model,tokenizer,optimizer,torch,2,8)
    save(args.run/'probe-after.json',evaluate(model,items,torch))
    free,total=torch.cuda.mem_get_info()
    save(args.run/'probe-metrics.json',{'purpose':'engineering_feasibility_only_not_full_training_or_quality_acceptance',
         'repo':verification['repo'],'revision':verification['revision'],'dtype':'bfloat16','lora_rank':8,
         'microbatch':1,'accumulation':4,'optimizer_steps':2,'forward_backward_calls':8,
         'tested_token_lengths':[r['length'] for r in items],'synthetic_padding_is_quality_test':False,
         'trainable_parameters':sum(p.numel() for p in parameters),'updated_adapter_tensors':changed,
         'peak_reserved_bytes':torch.cuda.max_memory_reserved(),'gpu_free_after_bytes':free,'gpu_total_bytes':total,
         'seconds':time.perf_counter()-start,'trace':trace,'completed':True})


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('model','upstream','data','run'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--mode',choices=('train','verify'),default='train')
    parser.add_argument('--max-length',type=int,default=1536)
    args=parser.parse_args()
    try:
        run(args)
    except Exception as error:
        args.run.mkdir(parents=True,exist_ok=True)
        save(args.run/('probe-failure-'+args.mode+'.json'),{'passed':False,'error_type':type(error).__name__,'message':str(error)[:500]})
        raise
