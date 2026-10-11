"""Native Turbo reference-image argument contracts, without loading GPU weights."""
from pathlib import Path
import unittest

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
        self.assertEqual(args[2:4], ['-m', 'lightx2v.infer'])
        self.assertEqual(args[args.index('--model_cls') + 1], 'qwen_image_21')
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
