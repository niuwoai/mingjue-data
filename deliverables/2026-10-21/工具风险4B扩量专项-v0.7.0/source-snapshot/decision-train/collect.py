"""Read-only runtime verification and artifact checksums after service completion."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path('/home/ml-data/rsi-tool-gate-balanced')
RUN = ROOT / 'runs/trial-002'
UNIT = 'rsi-tool-gate-balanced.service'


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    properties = command('systemctl', 'show', UNIT, '-p', 'ActiveState', '-p', 'SubState',
                         '-p', 'Result', '-p', 'ExecMainStatus', '-p', 'ActiveEnterTimestamp',
                         '-p', 'InactiveEnterTimestamp')
    status = dict(line.split('=', 1) for line in properties.splitlines())
    if status['ActiveState'] != 'inactive' or status['Result'] != 'success':
        raise ValueError('Trial unit has not successfully completed')
    status['qwen_service'] = command('systemctl', 'is-active', 'llama-qwen38-cuda.service')
    status['watchdog_timer'] = command('systemctl', 'is-active', 'q4-tunnel-watchdog.timer')
    with urllib.request.urlopen('http://127.0.0.1:11435/health', timeout=10) as response:
        status['health_http'] = response.status
        status['health_body'] = json.load(response)
    status['gpu_after_restore'] = command('nvidia-smi', '--query-gpu=name,memory.used,memory.total', '--format=csv')
    status['packages'] = {name: importlib.metadata.version(name) for name in ('torch', 'transformers', 'peft', 'accelerate')}
    status['remote_source_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'src').glob('*') if p.is_file()}
    (RUN/'service-verification.json').write_text(json.dumps(status, ensure_ascii=False, indent=2)+'\n')
    journal = command('journalctl', '-u', UNIT, '--no-pager', '-o', 'json')
    (RUN/'training-journal.jsonl').write_text(journal+'\n')
    hashes = {str(p.relative_to(RUN)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in RUN.rglob('*') if p.is_file() and p.name != 'artifact-sha256.json'}
    (RUN/'artifact-sha256.json').write_text(json.dumps(hashes, indent=2)+'\n')
    print(json.dumps({'files': len(hashes), 'unit': status['Result'], 'health_http': status['health_http'],
                      'adapter_sha256': hashes['adapter/adapter_model.safetensors']}))


if __name__ == '__main__':
    main()
