#!/usr/bin/env python3
"""Prepare a persistent native UI fixture outside macOS protected folders.

Run after scripts/build.sh, with --sample pointing to any PNG fixture. Launch
the printed app path through the UI. All runtime files live in Library/Caches;
the user's real workspace, configuration and permissions are never changed.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid


FIXTURE = '''#!/usr/bin/env python3
import json, shutil, sys, time
from pathlib import Path
def emit(kind, **fields): print(json.dumps(dict(type=kind, **fields)), flush=True)
if '-c' in sys.argv:
    print('LIGHTX2V_ENV:' + json.dumps(dict(python='3.11.17', architecture='arm64', mps=True,
          torch='2.14.1', torchvision='0.29.1', torchaudio='2.11.0', transformers='5.19.0', detail='UI fixture')), flush=True)
    sys.exit(0)
if sys.argv[-2] == 'check':
    emit('check', ok=True, message='UI fixture ready'); sys.exit(0)
request = json.load(open(sys.argv[-1]))
if request.get('promptEnhancement'):
    emit('enhancement_phase', phase='thinking', mode='i2i' if request.get('inputImages') else 't2i')
    for _ in range(30):
        emit('enhancement_thinking', delta='先确认主体与构图，再补充光线和环境细节。\\n'); time.sleep(.1)
    emit('enhancement_phase', phase='rewriting')
    text = ('A quiet glass house stands in a misty forest, surrounded by tall trees and soft morning light. '
            'Natural materials, delicate reflections and a calm composition create an intimate woodland scene. '
            'Fine texture in the moss, glass and bark adds depth, with a warm glow filtering through the canopy. '
            'The house remains the focal point, while the background falls gently out of focus. ')
    text *= 3
    for offset in range(0, len(text), 14):
        emit('enhancement_prompt', delta=text[offset:offset + 14]); time.sleep(.1)
    emit('enhancement_result', prompt=text.strip(), whRatio='1:1', ratioFollow='', duration=12)
    time.sleep(2)
for step in range(1, 9):
    emit('step', step=step, total=8); time.sleep(.5)
shutil.copyfile(Path(__file__).with_name('sample.png'), request['output'])
emit('done', status='completed', duration=14)
'''


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def prepare(source, sample, root=None):
    root = root or Path.home() / 'Library/Caches/LightX2V-APP-UI-Check'
    app = root / 'LightX2V UI Check.app'
    if not (source / 'Contents/MacOS/LightX2VApp').is_file():
        raise SystemExit('Build the app with scripts/build.sh first.')
    root.mkdir(parents=True, exist_ok=True)
    # One stable bundle ID/path; rebuilding never points the UI at Documents.
    shutil.copytree(source, app, dirs_exist_ok=True)
    plist_path = app / 'Contents/Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    info.update(CFBundleIdentifier='app.lightx2v.uicheck', CFBundleName='LightX2V UI Check',
                CFBundleDisplayName='LightX2V UI Check',
                LSEnvironment={'LIGHTX2V_APP_STATE_DIR': str(root / 'support')})
    plist_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(sample, root / 'sample.png')
    executable = root / 'fixture-python'
    executable.write_text(FIXTURE, encoding='utf-8'); executable.chmod(0o755)
    for name in ['source/lightx2v/infer.py', 'Qwen-Image-2.1-Turbo/model_index.json', 'qwen_image_21_turbo.json',
                 'bin/llama-completion', 'bin/llama-mtmd-cli', 't2i.gguf', 'i2i.gguf',
                 't2i.txt', 'i2i.txt', 'mmproj.gguf']:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{}' if name.endswith('.json') else 'UI fixture', encoding='utf-8')
        if name.startswith('bin/'): path.chmod(0o755)
    t2i = root / 'PE-T2I'
    i2i = root / 'PE-I2I'
    for mode, folder in [('T2I', t2i), ('I2I', i2i)]:
        folder.mkdir(exist_ok=True)
        (folder / 'system_prompt.txt').write_text('UI fixture', encoding='utf-8')
        (folder / ('Qwen-Image-2.1-PE-' + mode + '-Q8_0.gguf')).write_text('UI fixture', encoding='utf-8')
    (i2i / 'mmproj-Qwen-Image-2.1-PE-I2I-BF16.gguf').write_text('UI fixture', encoding='utf-8')
    pe = dict(enabled=True, t2iDirectory=str(t2i), i2iDirectory=str(i2i))
    settings = dict(repository=str(root / 'source'), model=str(root / 'Qwen-Image-2.1-Turbo'), config=str(root / 'qwen_image_21_turbo.json'),
                    python=str(executable), workingDirectory=str(root / 'workspace'), promptEnhancement=pe)
    workspace = root / 'workspace'
    for name in ['code', 'outputs', 'logs', 'cache', 'tmp']:
        (workspace / name).mkdir(parents=True, exist_ok=True)
    persisted_settings = dict(python=str(executable), workingDirectory=str(workspace),
        **{'Qwen-Image-2.1-Turbo': dict(modelDirectory=settings['model'], modelDownloadSource='huggingFace', promptEnhancement=pe)})
    state_path = workspace / 'workspace.json'
    if not state_path.exists():
        job_id = str(uuid.uuid4()).upper()
        output = workspace / 'outputs' / job_id / 'image.png'
        output.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(sample, output)
        request = dict(repository=settings['repository'], model=settings['model'], config=settings['config'],
                       prompt='A quiet glass house in a misty forest', resolution=1024, seed=42,
                       output=str(output), inputImages=[], promptEnhancement=pe)
        job = dict(id=job_id, creationID=job_id, createdAt=time.time() - 978307200,
                   request=request, status='completed', duration=14,
                   enhancement=dict(mode='t2i', status='completed', thinking='保留构图，补充晨光与材质。\n' * 25,
                                    prompt='A quiet glass house in a misty forest, with soft morning light and natural textures.',
                                    whRatio='1:1', ratioFollow='', duration=12))
        write_json(output.parent / 'generation.json', job)
        write_json(state_path, dict(settings=persisted_settings, generations=[job], hasCompletedGeneralSetup=True))
    else:
        state = json.loads(state_path.read_text(encoding='utf-8'))
        state['settings'] = persisted_settings
        write_json(state_path, state)
    write_json(root / 'support/workspace_location.json', dict(workingDirectory=str(workspace)))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/LightX2V APP.app')
    parser.add_argument('--sample', type=Path, required=True, help='PNG fixture copied into the cache before launching')
    parser.add_argument('--root', type=Path, help='A separate cache directory for a fresh UI workspace')
    args = parser.parse_args()
    prepare(args.app, args.sample, args.root)
