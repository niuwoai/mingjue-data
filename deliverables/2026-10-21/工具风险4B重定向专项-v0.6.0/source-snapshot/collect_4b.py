"""Collect engineering-probe evidence after GPU inference has been restored."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT=Path('/home/ml-data/rsi-tool-gate-short')
RUN=ROOT/'runs/probe-4b-001'


def command(*args):
    return subprocess.check_output(args,text=True).strip()


def main():
    status={}
    for unit in ('rsi-model-4b-download.service','rsi-tool-gate-4b-probe.service'):
        raw=command('systemctl','show',unit,'-p','ActiveState','-p','SubState','-p','Result','-p','ExecMainStatus')
        properties=dict(line.split('=',1) for line in raw.splitlines())
        if properties['ActiveState'] not in ('inactive','failed'):
            raise ValueError('Job is still running: '+unit)
        status[unit]=properties
        (RUN/(unit+'.journal.jsonl')).write_text(command('journalctl','-u',unit,'--no-pager','-o','json')+'\n')
    status['qwen_service']=command('systemctl','is-active','llama-qwen38-cuda.service')
    status['watchdog_timer']=command('systemctl','is-active','q4-tunnel-watchdog.timer')
    with urllib.request.urlopen('http://127.0.0.1:11435/health',timeout=10) as response:
        status['health_http']=response.status
        status['health_body']=json.load(response)
    if status['qwen_service']!='active' or status['health_http']!=200:
        raise ValueError('Original inference has not recovered')
    status['gpu_after_restore']=command('nvidia-smi','--query-gpu=name,memory.used,memory.total','--format=csv')
    model=Path('/home/ml-data/rsi-smoke/model-4b')
    for name in ('download-verification.json','config.json'):
        (RUN/name).write_bytes((model/name).read_bytes())
    (RUN/'service-verification.json').write_text(json.dumps(status,indent=2)+'\n')
    hashes={str(p.relative_to(RUN)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in RUN.rglob('*') if p.is_file() and p.name!='artifact-sha256.json'}
    (RUN/'artifact-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
    print(json.dumps({'files':len(hashes),'probe_result':status['rsi-tool-gate-4b-probe.service']['Result'],'inference_restored':True}))


if __name__=='__main__':
    main()
