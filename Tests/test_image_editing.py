"""Editing argument and streaming adapter contracts, without loading GPU weights."""
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

from PIL import Image
import test_bridge

bridge, BRIDGE = test_bridge.bridge, test_bridge.BRIDGE


class ImageArgumentsTests(unittest.TestCase):
    setUp = test_bridge.BridgeTests.setUp
    tearDown = test_bridge.BridgeTests.tearDown
    def references(self, count=2):
        folder = Path(self.request['output']).parent / 'inputs'
        folder.mkdir(parents=True, exist_ok=True)
        result = []
        for i in range(count):
            path = folder / f'reference-{i + 1}.png'
            Image.new('RGBA', (32, 64), (i * 20, 50, 100, 128)).save(path)
            result.append({'path': str(path), 'name': f'原图, {i + 1}.png'})
        self.request['inputImages'] = result
        return result

    def test_order_and_comma_workspace_preserve_one_cli_argument(self):
        self.request['output'] = str(self.root / 'job, 中文 spaces/image.png')
        self.references()
        args = bridge.arguments(self.request, self.config)
        self.assertEqual(args[args.index('--task') + 1], 'i2i')
        self.assertEqual(args[args.index('--image_path') + 1], 'inputs/reference-1.png,inputs/reference-2.png')
        self.assertIn(str(BRIDGE.with_name('qwen_image_edit.py')), args)
        self.request['inputImages'] = []
        args = bridge.arguments(self.request, self.config)
        self.assertEqual(args[args.index('--task') + 1], 't2i')
        self.assertNotIn('--image_path', args)

    def test_missing_corrupt_external_and_excessive_images_rejected(self):
        references = self.references()
        valid = references[0]
        for images in (None, 'bad', [{}], [valid] * 9,
                       [{'path': 'relative.png'}], [{'path': str(self.root / 'outside.png')}],
                       [{'path': str(Path(valid['path']).with_name('bad,name.png'))}]):
            with self.subTest(images=images), self.assertRaises(ValueError):
                bridge.arguments({**self.request, 'inputImages': images}, self.config)
        Path(valid['path']).write_text('broken')
        with self.assertRaises(OSError):
            bridge.arguments(self.request, self.config)
        Path(valid['path']).unlink()
        with self.assertRaises(FileNotFoundError):
            bridge.arguments(self.request, self.config)

    def test_automatic_editing_retains_all_references_without_forcing_dimensions(self):
        self.references(3)
        self.request.pop('width'); self.request.pop('height')
        for resolution in (1024, 2048):
            self.request['resolution'] = resolution
            args = bridge.arguments(self.request, self.config)
            self.assertNotIn('--size', args)
            self.assertNotIn('--aspect_ratio', args)
            self.assertEqual(args[args.index('--resolution') + 1], str(resolution))
            self.assertEqual(args[args.index('--image_path') + 1], 'inputs/reference-1.png,inputs/reference-2.png,inputs/reference-3.png')



class AdapterTests(unittest.TestCase):
    def test_native_vision_weights_and_all_streaming_constraints_are_retained(self):
        events = []
        modules = {}
        def module(name, **attrs):
            value = types.ModuleType(name)
            value.__dict__.update(attrs)
            modules[name] = value
            return value
        class Tensor:
            def to(self, **kwargs):
                events.append(('to', kwargs)); return self
        class Checkpoint:
            def __init__(self, path):
                self.weight_map = {'model.visual.pos_embed.weight': 1, 'model.visual.blocks.0.weight': 2, 'model.language_model.weight': 3}
            def load_tensors(self, names):
                events.append(('names', names)); return dict.fromkeys(names, Tensor())
        class Vision:
            def __init__(self, config): self.config = config
            def load(self, weights): events.append(('load', set(weights)))
            def forward(self, pixels, grid): return (pixels, grid)
        class Native:
            def infer(self, prompt, images): return (prompt, images)
        class Streaming:
            model_config = {'vision_config': {'native': True}}
            def _load_weights(self, path, config): events.append(('language_streaming', path))
            def add_module(self, name, value): setattr(self, name, value)
        class Runner:
            @staticmethod
            def _validate_mps_streaming_config(config):
                events.append(('validation', config.copy()))
                if config.get('task') != 't2i' or not config.get('cpu_offload'):
                    raise ValueError('unsupported config')
        for name in ('lightx2v', 'lightx2v.common', 'lightx2v.common.offload', 'lightx2v.models',
                     'lightx2v.models.input_encoders', 'lightx2v.models.input_encoders.hf',
                     'lightx2v.models.runners', 'lightx2v.models.runners.qwen_image_21', 'lightx2v.utils'):
            module(name)
        module('torch', inference_mode=lambda: lambda f: f, mps=types.SimpleNamespace(empty_cache=lambda: events.append(('release',))))
        module('lightx2v.common.offload.safetensors_checkpoint', SafetensorsCheckpoint=Checkpoint)
        streaming = module('lightx2v.models.input_encoders.hf.qwen_image_21.qwen3vl_mps', QwenImage21MpsTextEncoder=Streaming)
        module('lightx2v.models.input_encoders.hf.qwen_image_21', qwen3vl_mps=streaming)
        module('lightx2v.models.input_encoders.hf.qwen_image_21.qwen3vl', Qwen3VLVision=Vision, QwenImage21TextEncoder=Native)
        module('lightx2v.models.runners.qwen_image_21.qwen_image_21_runner', QwenImage21Runner=Runner)
        module('lightx2v.utils.envs', GET_DTYPE=lambda: 'bf16')
        spec = importlib.util.spec_from_file_location('edit_adapter', BRIDGE.with_name('qwen_image_edit.py'))
        adapter = importlib.util.module_from_spec(spec); spec.loader.exec_module(adapter)
        with patch.dict(sys.modules, modules):
            adapter.enable_mps_editing()
            config = {'task': 'i2i', 'cpu_offload': True, 'dit_disk_streaming': True}
            Runner._validate_mps_streaming_config(config)
            self.assertEqual(config['task'], 'i2i')
            self.assertEqual(events[-1][1], {**config, 'task': 't2i'})
            with self.assertRaises(ValueError): Runner._validate_mps_streaming_config({**config, 'cpu_offload': False})
            encoder = streaming.QwenImage21MpsTextEncoder()
            encoder._load_weights('checkpoint', config)
            self.assertEqual(encoder.infer('combine', ['first', 'second']), ('combine', ['first', 'second']))
            self.assertEqual(encoder.vision.forward('pixels', 'grid'), ('pixels', 'grid'))
            self.assertIn(('language_streaming', 'checkpoint'), events)
            self.assertIn(('names', {'model.visual.pos_embed.weight', 'model.visual.blocks.0.weight'}), events)
            self.assertIn(('to', {'device': 'mps', 'dtype': 'bf16'}), events)
            self.assertEqual(events[-1], ('release',))
            with patch.object(Vision, 'forward', side_effect=RuntimeError('fixture')):
                with self.assertRaises(RuntimeError): encoder.vision.forward('pixels', 'grid')
            self.assertEqual(events[-1], ('release',))
