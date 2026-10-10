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
p.add_argument('--resolution',type=int)
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
Image.new('RGB',(a.size[1],a.size[0]) if a.size else (a.resolution,a.resolution),(100,150,190)).save(out)
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
        self.assertEqual(json.loads((self.root/'run/invocation.json').read_text())['cwd'], str(self.root/'run'))
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

    def test_all_1k_and_2k_presets_reach_cli_in_height_width_order(self):
        sizes = [(1024, 1024), (1184, 896), (896, 1184), (1248, 832),
                 (832, 1248), (1376, 768), (768, 1376), (2048, 2048),
                 (2400, 1792), (1792, 2400), (2528, 1696), (1696, 2528),
                 (2752, 1536), (1536, 2752)]
        for width, height in sizes:
            with self.subTest(width=width, height=height):
                self.request.update(width=width, height=height)
                args = bridge.arguments(self.request, self.config)
                index = args.index('--size')
                self.assertEqual(args[index + 1:index + 3], [str(height), str(width)])

    def test_2k_landscape_and_portrait_complete_with_exact_dimensions(self):
        for width, height in [(2752, 1536), (1536, 2752)]:
            with self.subTest(width=width, height=height):
                output = self.root / f'run-{width}-{height}/image.png'
                self.request.update(width=width, height=height, output=str(output))
                child = self.start()
                out, err = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 0, err + out)
                self.assertEqual(json.loads(out.splitlines()[-1])['status'], 'completed')
                received = json.loads((output.parent / 'received.json').read_text())
                self.assertEqual(received['size'], [height, width])
                bridge.validate_image(output, width, height)
                self.assertEqual(json.loads((output.parent / 'config.json').read_text()), self.cfg)

    def test_dimension_boundaries_and_types_are_validated(self):
        for value in (224, 2784, 1200, 1024.0, True, '1024'):
            for axis in ('width', 'height'):
                with self.subTest(value=value, axis=axis):
                    request = {**self.request, axis: value}
                    with self.assertRaises(ValueError):
                        bridge.arguments(request, self.config)

    def test_existing_output_is_never_overwritten(self):
        output=Path(self.request['output']); output.parent.mkdir(); output.write_bytes(b'keep me')
        child=self.start(); out,err=child.communicate(timeout=15)
        self.assertEqual(child.returncode,1)
        self.assertEqual(output.read_bytes(),b'keep me')

    def test_automatic_text_resolution_reaches_cli_without_size(self):
        for resolution in (1024, 2048):
            output = self.root / f'auto-{resolution}/image.png'
            self.request.pop('width', None); self.request.pop('height', None)
            self.request.update(resolution=resolution, output=str(output))
            child = self.start(); out, err = child.communicate(timeout=15)
            self.assertEqual(child.returncode, 0, err + out)
            received = json.loads((output.parent / 'received.json').read_text())
            self.assertIsNone(received['size'])
            self.assertEqual(received['resolution'], resolution)
            done = json.loads(out.splitlines()[-1])
            self.assertEqual((done['width'], done['height']), (resolution, resolution))

    def test_automatic_resolution_rejects_ambiguous_or_invalid_sizes(self):
        base = {**self.request, 'width': None, 'height': None}
        for resolution in (True, '1024', 1024.0, 0, 512, 4096):
            with self.subTest(resolution=resolution), self.assertRaises(ValueError):
                bridge.arguments({**base, 'resolution': resolution}, self.config)
        with self.assertRaises(ValueError):
            bridge.arguments({**self.request, 'resolution': 1024}, self.config)

    def test_automatic_output_is_decoded_and_alignment_is_validated(self):
        from PIL import Image
        output = self.root / 'auto.png'
        Image.new('RGB', (896, 1184)).save(output)
        self.assertEqual(bridge.validate_image(output), (896, 1184))
        with self.assertRaises(RuntimeError): bridge.validate_image(output, 1024, 1024)
        Image.new('RGB', (895, 1184)).save(output)
        with self.assertRaises(RuntimeError): bridge.validate_image(output)
        output.write_bytes(b'not an image')
        with self.assertRaises(OSError): bridge.validate_image(output)


if __name__ == '__main__': unittest.main(verbosity=2)
