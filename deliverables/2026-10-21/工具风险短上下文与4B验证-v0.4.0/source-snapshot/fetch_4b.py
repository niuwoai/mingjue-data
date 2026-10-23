"""Fetch a pinned public checkpoint; verify against separately captured official metadata."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import time
import urllib.request


def verify(path, item):
    if not path.is_file() or path.stat().st_size != item['size']:
        return False
    if item.get('lfs'):
        with path.open('rb') as handle:
            return hashlib.file_digest(handle,'sha256').hexdigest()==item['lfs']['sha256']
    digest=hashlib.sha1(b'blob '+str(item['size']).encode()+b'\0')
    with path.open('rb') as handle:
        for chunk in iter(lambda:handle.read(4*1024**2),b''):
            digest.update(chunk)
    return digest.hexdigest()==item['blobId']


def download(args, meta, item):
    name=item['rfilename']
    if Path(name).name != name:
        raise ValueError('Unexpected nested checkpoint filename')
    target=args.destination/name
    if verify(target,item):
        return {'file':name,'bytes':item['size'],'verified':True,'cached':True}
    partial=args.destination/(name+'.part')
    opener=urllib.request.build_opener() if args.use_environment_proxy else urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(3):
        try:
            offset=partial.stat().st_size if partial.exists() else 0
            if offset>item['size']:
                raise ValueError('Partial file exceeds expected size')
            if offset<item['size']:
                url=f"{args.endpoint}/{meta['id']}/resolve/{meta['sha']}/{name}?download=true"
                request=urllib.request.Request(url,headers={'Range':f'bytes={offset}-'} if offset else {})
                with opener.open(request,timeout=60) as response:
                    mode='ab' if response.status==206 and offset else 'wb'
                    done=offset if mode=='ab' else 0
                    boundary=done//(256*1024**2)
                    with partial.open(mode) as handle:
                        while chunk:=response.read(4*1024**2):
                            handle.write(chunk)
                            done+=len(chunk)
                            if done//(256*1024**2)>boundary:
                                boundary=done//(256*1024**2)
                                print(json.dumps({'file':name,'downloaded_bytes':done,'expected_bytes':item['size']}),flush=True)
            if not verify(partial,item):
                raise ValueError('Pinned checksum or size mismatch')
            partial.replace(target)
            return {'file':name,'bytes':item['size'],'verified':True,'cached':False}
        except Exception as error:
            # Never print signed redirect URLs or HTTP response headers.
            print(json.dumps({'file':name,'attempt':attempt+1,'error_type':type(error).__name__}),flush=True)
            if attempt==2:
                raise RuntimeError('Checkpoint fetch failed: '+name) from None
            time.sleep(2)


def main(args):
    meta=json.loads(args.metadata.read_text())
    if meta['id'].lower()!='internlm/intern-decision-4b' or meta['sha']!='1e65a988dacbcf00b84aee7366f9e47563407000':
        raise ValueError('Unexpected official checkpoint identity')
    args.destination.mkdir(parents=True,exist_ok=True)
    selected=[r for r in meta['siblings'] if r['rfilename'].endswith(('.json','.safetensors','.jinja','.txt'))
              and r['rfilename']!='requirements.txt']
    results=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures=[executor.submit(download,args,meta,item) for item in selected]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    report={'repo':meta['id'],'revision':meta['sha'],'official_metadata_sha256':hashlib.sha256(args.metadata.read_bytes()).hexdigest(),
            'files':sorted(results,key=lambda r:r['file']),'all_verified':all(r['verified'] for r in results),
            'weight_bytes':sum(r['bytes'] for r in results if r['file'].endswith('.safetensors'))}
    (args.destination/'download-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'download_complete':True,'revision':meta['sha'],'files':len(results)}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--metadata',type=Path,required=True)
    parser.add_argument('--destination',type=Path,required=True)
    parser.add_argument('--endpoint',default='https://hf-mirror.com')
    parser.add_argument('--use-environment-proxy',action='store_true')
    main(parser.parse_args())
