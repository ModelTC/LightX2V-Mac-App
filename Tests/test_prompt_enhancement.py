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

RESOURCES = Path(__file__).resolve().parents[1] / "Sources/LightX2VApp/Resources"
sys.path.insert(0, str(RESOURCES))
from prompt_enhancement import ThinkingStream, parse_result, inference_request, command


class StreamTests(unittest.TestCase):
    def test_every_possible_thinking_tag_boundary_and_unicode(self):
        source = '<think>\n思考 🐈，保留构图。</think>\n{"rewritten_prompt":"a cat","wh_ratio":"1:1"}[end of text]'
        for width in range(1, 30):
            events = []
            stream = ThinkingStream(lambda kind, **fields: events.append({"type": kind, **fields}))
            for offset in range(0, len(source), width):
                stream.feed(source[offset:offset + width])
            stream.finish()
            self.assertTrue(stream.closed)
            self.assertEqual(stream.thinking.strip(), "思考 🐈，保留构图。")
            self.assertEqual(''.join(e['delta'] for e in events if e['type'] == 'enhancement_thinking').strip(), stream.thinking.strip())
            self.assertEqual(len([e for e in events if e['type'] == 'enhancement_phase']), 1)

    def test_incomplete_and_invalid_outputs_are_rejected(self):
        invalid = ["still thinking", 'thought</think>{"rewritten_prompt":"x","wh_ratio":"1:1"}',
                   'thought</think>{"rewritten_prompt":"","wh_ratio":"1:1"}[end of text]',
                   'thought</think>{"rewritten_prompt":"x","wh_ratio":"0:1"}[end of text]',
                   'thought</think>{"rewritten_prompt":"x","wh_ratio":"1:1","extra":1}[end of text]']
        for raw in invalid:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_result(raw, 't2i', 0)
        for ratio, follow in [('1:1', '<image1>'), ('', ''), ('', '<image3>'), ('', '<image0>')]:
            raw = '思考</think>' + json.dumps(dict(rewritten_prompt='x', wh_ratio=ratio, ratio_follow=follow))
            with self.subTest(follow=follow), self.assertRaises(ValueError):
                parse_result(raw, 'i2i', 2)


INFER = '''
import argparse, json, math
from pathlib import Path
from PIL import Image
p=argparse.ArgumentParser()
for key in ('model_cls','task','model_path','config_json','prompt','seed','save_result_path','image_path','aspect_ratio'): p.add_argument('--'+key)
p.add_argument('--size',nargs=2,type=int); p.add_argument('--resolution',type=int)
a=p.parse_args(); out=Path(a.save_result_path)
(out.parent/'received.json').write_text(json.dumps(vars(a)))
if a.size: h,w=a.size
elif a.aspect_ratio:
    x,y=map(int,a.aspect_ratio.split(':')); w=max(32,round(math.sqrt(a.resolution*a.resolution*x/y)/32)*32); h=max(32,round(math.sqrt(a.resolution*a.resolution*y/x)/32)*32)
else: w=h=a.resolution
Image.new('RGB',(w,h)).save(out)
print('==> step_index: 6 / 6',flush=True)
'''

ENHANCER = '''
import json, os, signal, sys, time
from pathlib import Path
root=Path.cwd(); args=sys.argv[1:]
(root/'enhancer-args.json').write_text(json.dumps(args))
scenario=(Path(__file__).parent/'scenario').read_text()
if scenario=='sleep':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root/'enhancer.pid').write_text(str(os.getpid()))
    print('开始思考',flush=True); time.sleep(60)
if scenario=='fail': sys.exit(7)
mode='i2i' if '--mmproj' in args else 't2i'
result={'rewritten_prompt':'Enhanced 中文 prompt; $(touch forbidden) `echo no`','wh_ratio':'3:2'}
if mode=='i2i': result.update(wh_ratio='',ratio_follow='<image1>')
text='正在思考 🐈，保留构图。</think>\\n'+json.dumps(result,ensure_ascii=False)+('[end of text]' if mode=='t2i' else '')
if scenario=='bad': text='思考</think>{oops}'
if scenario=='partial': text=text.replace('</think>','')
for byte in text.encode():
    os.write(sys.stdout.fileno(), bytes([byte])); time.sleep(.001)
'''


class EnhancementPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pe 中文, test ')
        self.root = Path(self.temp.name)
        self.resources = self.root / 'resources'; self.resources.mkdir()
        for name in ['bridge.py', 'prompt_enhancement.py']:
            (self.resources / name).write_bytes((RESOURCES / name).read_bytes())
        (self.resources / 'qwen_image_edit.py').write_text(INFER)
        self.repo = self.root / 'code'
        (self.repo / 'lightx2v').mkdir(parents=True)
        (self.repo / 'lightx2v/__init__.py').write_text('')
        (self.repo / 'lightx2v/infer.py').write_text(INFER)
        self.model = self.root / 'model'
        for name in ['transformer', 'text_encoder', 'vae', 'scheduler', 'processor']:
            (self.model / name).mkdir(parents=True)
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps(dict(infer_steps=6, sigmas=[1,.9375,.875,.75,.5,.25], attn_type='torch_sdpa_mps', enable_cfg=False)))
        self.runtime = self.root / 'bin'; self.runtime.mkdir()
        for name in ['llama-completion', 'llama-mtmd-cli']:
            binary = self.runtime / name
            binary.write_text('#!' + sys.executable + '\n' + ENHANCER)
            binary.chmod(0o755)
        self.set_scenario('normal')
        files = {}
        for key in ['t2iModel','t2iSystemPrompt','i2iModel','i2iSystemPrompt','visionProjector']:
            path = self.root / key; path.write_text('fixture resource')
            files[key] = str(path)
        self.request = dict(repository=str(self.repo),model=str(self.model),config=str(self.config), prompt='Original 中文',
                            resolution=1024,seed=42,output=str(self.root/'run/image.png'),
                            promptEnhancement=dict(enabled=True,runtimeDirectory=str(self.runtime),**files))
        self.request_path = self.root/'request.json'

    def tearDown(self):
        self.temp.cleanup()

    def set_scenario(self, value):
        (self.runtime/'scenario').write_text(value)

    def start(self):
        self.request_path.write_text(json.dumps(self.request))
        return subprocess.Popen([sys.executable,str(self.resources/'bridge.py'),'run',str(self.request_path)], stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)

    def run_pipeline(self):
        child = self.start(); out, err = child.communicate(timeout=15)
        self.assertEqual(child.returncode, 0, err + out)
        return [json.loads(line) for line in out.splitlines()]

    def test_text_enhancement_precedes_generation_and_preserves_original(self):
        events = self.run_pipeline()
        types = [e['type'] for e in events]
        self.assertLess(types.index('enhancement_result'), types.index('step'))
        self.assertEqual(events[-1]['status'], 'completed')
        received = json.loads((self.root/'run/received.json').read_text())
        self.assertEqual(received['prompt'], 'Enhanced 中文 prompt; $(touch forbidden) `echo no`')
        self.assertEqual(received['aspect_ratio'], '3:2')
        self.assertIsNone(received['size'])
        self.assertEqual(json.loads(self.request_path.read_text())['prompt'], 'Original 中文')
        self.assertTrue((self.root/'run/enhancement/thinking.txt').read_text().startswith('正在思考'))
        self.assertFalse((self.root/'run/forbidden').exists())
        args = json.loads((self.root/'run/enhancer-args.json').read_text())
        self.assertIn('--no-display-prompt', args)
        self.assertFalse((self.resources/'__pycache__').exists())

    def attach_images(self):
        from PIL import Image
        folder = self.root/'run/inputs'; folder.mkdir(parents=True)
        a = folder/'reference-1.png'; b = folder/'reference-2.png'
        Image.new('RGB',(400,300)).save(a); Image.new('RGB',(300,500)).save(b)
        self.request['inputImages'] = [dict(path=str(a),name='one'),dict(path=str(b),name='two'),dict(path=str(a),name='one again')]

    def test_reference_enhancement_preserves_order_duplicates_and_canvas(self):
        self.attach_images()
        self.run_pipeline()
        args = json.loads((self.root/'run/enhancer-args.json').read_text())
        paths = [args[i+1] for i,v in enumerate(args) if v=='--image']
        self.assertEqual(paths, ['inputs/reference-1.png','inputs/reference-2.png','inputs/reference-1.png'])
        self.assertIn('--mmproj', args)
        received = json.loads((self.root/'run/received.json').read_text())
        self.assertEqual(received['aspect_ratio'], '4:3')
        self.assertEqual(received['task'], 'i2i')

    def test_selected_fixed_dimensions_override_enhancer_ratio(self):
        self.request.pop('resolution'); self.request.update(width=512,height=256)
        self.run_pipeline()
        received = json.loads((self.root/'run/received.json').read_text())
        self.assertEqual(received['size'], [256,512])
        self.assertIsNone(received['aspect_ratio'])

    def test_eight_references_keep_all_images_with_room_for_text_context(self):
        self.attach_images()
        self.request['inputImages'] = self.request['inputImages'][:1] * 8
        args, mode = command(self.request, self.root/'run/enhancement')
        self.assertEqual(mode,'i2i')
        self.assertEqual(args.count('--image'),8)
        image_tokens = int(args[args.index('--image-max-tokens')+1])
        self.assertEqual(image_tokens,1024)
        self.assertLessEqual(image_tokens*8,8192)

    def test_disabled_uses_existing_prompt_and_never_launches_enhancer(self):
        self.request.pop('promptEnhancement'); self.set_scenario('fail')
        events = self.run_pipeline()
        self.assertFalse(any(e['type'].startswith('enhancement') for e in events))
        self.assertFalse((self.root/'run/enhancer-args.json').exists())
        self.assertEqual(json.loads((self.root/'run/received.json').read_text())['prompt'],'Original 中文')

    def test_failed_or_partial_enhancement_never_launches_generation(self):
        for scenario in ['bad','fail','partial']:
            self.set_scenario(scenario)
            child = self.start(); out, err = child.communicate(timeout=15)
            self.assertEqual(child.returncode,1,err+out)
            self.assertEqual(json.loads(out.splitlines()[-1])['status'],'failed')
            self.assertFalse((self.root/'run/received.json').exists())
            self.assertFalse((self.root/'run/image.png').exists())

    def test_missing_mode_resources_fail_before_model_load(self):
        Path(self.request['promptEnhancement']['t2iModel']).unlink()
        child = self.start(); out, err = child.communicate(timeout=10)
        self.assertEqual(child.returncode,1,err+out)
        self.assertFalse((self.root/'run/enhancer-args.json').exists())

    def test_cancellation_reaps_uncooperative_enhancer_and_skips_generation(self):
        self.set_scenario('sleep')
        child = self.start()
        try:
            deadline = time.monotonic()+8
            while not (self.root/'run/enhancer.pid').exists() and time.monotonic()<deadline:
                time.sleep(.02)
            pid = int((self.root/'run/enhancer.pid').read_text())
            child.terminate(); out, err = child.communicate(timeout=8)
            self.assertEqual(child.returncode,130,err+out)
            self.assertEqual(json.loads(out.splitlines()[-1])['status'],'cancelled')
            self.assertFalse((self.root/'run/received.json').exists())
            with self.assertRaises(ProcessLookupError): os.kill(pid,0)
        finally:
            if child.poll() is None: child.kill(); child.wait()


if __name__ == '__main__':
    unittest.main(verbosity=2)
