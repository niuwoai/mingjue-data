import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from fetch_4b import download, verify


class Response:
    def __init__(self, body, status):
        self.body, self.status = body, status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, count):
        result, self.body = self.body[:count], self.body[count:]
        return result


class CheckpointFetchTest(unittest.TestCase):
    def test_resume_and_server_ignoring_range(self):
        payload=b'fixed public checkpoint fixture'
        item={'rfilename':'weight.safetensors','size':len(payload),
              'lfs':{'sha256':hashlib.sha256(payload).hexdigest()}}
        for status in (200,206):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                (root/'weight.safetensors.part').write_bytes(payload[:5])
                response=Response(payload[5:] if status==206 else payload,status)
                opener=SimpleNamespace(open=lambda request,timeout:response)
                args=SimpleNamespace(destination=root,endpoint='https://fixture.invalid',use_environment_proxy=False)
                with patch('fetch_4b.urllib.request.build_opener',return_value=opener):
                    result=download(args,{'id':'fixture','sha':'revision'},item)
                self.assertTrue(result['verified'])
                self.assertEqual((root/'weight.safetensors').read_bytes(),payload)

    def test_small_git_blob_and_corruption(self):
        payload=b'{"model":"fixture"}'
        sha=hashlib.sha1(b'blob '+str(len(payload)).encode()+b'\0'+payload).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'config.json'
            path.write_bytes(payload)
            item={'size':len(payload),'blobId':sha}
            self.assertTrue(verify(path,item))
            path.write_bytes(b'X'+payload[1:])
            self.assertFalse(verify(path,item))


if __name__=='__main__':
    unittest.main()
