"""Protocol integration tests with a tiny isolated CLI fixture; no GPU weights loaded."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BRIDGE = Path(__file__).resolve().parents[1] / "Sources/LightX2VApp/Resources/bridge.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("bridge", BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

FIXTURE = '''
import argparse, json, os, signal, sys, time
from pathlib import Path
from PIL import Image
p=argparse.ArgumentParser()
for name in ('model_cls','task','model_path','config_json','prompt','seed','save_result_path'): p.add_argument('--'+name)
p.add_argument('--size',nargs=2,type=int)
a=p.parse_args()
out=Path(a.save_result_path)
(out.parent/'received.json').write_text(json.dumps(vars(a)))
print('中文日志 🖼️',flush=True)
if a.prompt=='FAIL':
    print('deliberate fixture failure',flush=True)
    sys.exit(7)
if a.prompt=='SLEEP':
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    (out.parent/'pid').write_text(str(os.getpid()))
    print('fixture ready',flush=True)
    time.sleep(30)
for i in range(1,7): print(f'==> step_index: {i} / 6',flush=True)
Image.new('RGB',(a.size[1],a.size[0]),(100,150,190)).save(out)
'''


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lightx2v test ")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repository"
        (self.repo / "lightx2v").mkdir(parents=True)
        (self.repo / "lightx2v/__init__.py").write_text("")
        (self.repo / "lightx2v/infer.py").write_text(FIXTURE)
        self.model = self.root / "model"
        for folder in ("transformer", "text_encoder", "vae", "scheduler", "processor"):
            (self.model / folder).mkdir(parents=True)
        self.config = self.root / "source.json"
        self.cfg = {"infer_steps":6,"sigmas":[1,.9375,.875,.75,.5,.25],"attn_type":"torch_sdpa_mps","enable_cfg":False,"cpu_offload":True,"dit_disk_streaming":True}
        self.config.write_text(json.dumps(self.cfg))
        self.request = {"repository":str(self.repo),"model":str(self.model),"config":str(self.config),
                        "prompt":"A picture; $(touch should-not-exist) `echo test` 中文\nnew line",
                        "width":512,"height":256,"seed":4294967295,"output":str(self.root/"run/image.png")}
        self.request_path = self.root / "request.json"

    def tearDown(self):
        self.temp.cleanup()

    def start(self):
        self.request_path.write_text(json.dumps(self.request))
        return subprocess.Popen([sys.executable,str(BRIDGE),'run',str(self.request_path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)

    def test_real_protocol_preserves_arguments_config_and_dimensions(self):
        child = self.start()
        out, err = child.communicate(timeout=15)
        self.assertEqual(child.returncode,0,err + out)
        events = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(events[-1]['status'],'completed')
        self.assertEqual([e['step'] for e in events if e['type']=='step'],list(range(1,7)))
        received = json.loads((self.root/'run/received.json').read_text())
        self.assertEqual(received['prompt'],self.request['prompt'])
        self.assertEqual(received['size'],[256,512])
        self.assertEqual(received['seed'],'4294967295')
        self.assertEqual(json.loads((self.root/'run/config.json').read_text()),self.cfg)
        self.assertIn('中文日志',(self.root/'run/inference.log').read_text())
        self.assertFalse((self.repo/'should-not-exist').exists())

    def test_failure_is_not_reported_as_completion(self):
        self.request['prompt']='FAIL'
        child=self.start(); out,err=child.communicate(timeout=15)
        self.assertEqual(child.returncode,1)
        event=json.loads(out.splitlines()[-1])
        self.assertEqual(event['status'],'failed')
        self.assertIn('deliberate fixture failure',event['message'])

    def test_cancel_kills_an_uncooperative_inference_process(self):
        self.request['prompt']='SLEEP'
        child=self.start()
        try:
            deadline=time.monotonic()+8
            while not (self.root/'run/pid').exists() and time.monotonic()<deadline: time.sleep(.05)
            pid=int((self.root/'run/pid').read_text())
            child.terminate()
            out,err=child.communicate(timeout=8)
            self.assertEqual(child.returncode,130,err+out)
            self.assertEqual(json.loads(out.splitlines()[-1])['status'],'cancelled')
            with self.assertRaises(ProcessLookupError): os.kill(pid,0)
        finally:
            if child.poll() is None: child.kill(); child.wait()

    def test_invalid_schedule_and_dimensions_are_rejected(self):
        self.request['width']=720
        with self.assertRaises(ValueError): bridge.arguments(self.request,self.config)
        self.cfg['infer_steps']=4
        self.config.write_text(json.dumps(self.cfg))
        self.request_path.write_text(json.dumps(self.request))
        with self.assertRaises(ValueError): bridge.load_request(self.request_path)

    def test_existing_output_is_never_overwritten(self):
        output=Path(self.request['output']); output.parent.mkdir(); output.write_bytes(b'keep me')
        child=self.start(); out,err=child.communicate(timeout=15)
        self.assertEqual(child.returncode,1)
        self.assertEqual(output.read_bytes(),b'keep me')


if __name__ == '__main__': unittest.main(verbosity=2)
