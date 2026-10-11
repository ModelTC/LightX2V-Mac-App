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
shutil.copyfile(Path(__file__).with_name('sample.png'), request['output'])
emit('done', status='completed', duration=14)
'''


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def prepare(source, sample):
    root = Path.home() / 'Library/Caches/LightX2V-APP-UI-Check'
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
    for name in ['source/lightx2v/infer.py', 'model/model_index.json', 'config.json',
                 'bin/llama-completion', 'bin/llama-mtmd-cli', 't2i.gguf', 'i2i.gguf',
                 't2i.txt', 'i2i.txt', 'mmproj.gguf']:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{}' if name.endswith('.json') else 'UI fixture', encoding='utf-8')
        if name.startswith('bin/'): path.chmod(0o755)
    pe = dict(enabled=True, runtimeDirectory=str(root / 'bin'),
              t2iModel=str(root / 't2i.gguf'), t2iSystemPrompt=str(root / 't2i.txt'),
              i2iModel=str(root / 'i2i.gguf'), i2iSystemPrompt=str(root / 'i2i.txt'),
              visionProjector=str(root / 'mmproj.gguf'))
    settings = dict(repository=str(root / 'source'), model=str(root / 'model'), config=str(root / 'config.json'),
                    python=str(executable), workingDirectory=str(root / 'workspace'), promptEnhancement=pe)
    workspace = root / 'workspace'
    for name in ['code', 'outputs', 'logs', 'cache', 'tmp']:
        (workspace / name).mkdir(parents=True, exist_ok=True)
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
        write_json(state_path, dict(settings=settings, generations=[job], hasCompletedGeneralSetup=True))
    else:
        state = json.loads(state_path.read_text(encoding='utf-8'))
        state['settings'] = settings
        write_json(state_path, state)
    write_json(root / 'support/workspace_location.json', dict(workingDirectory=str(workspace)))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/LightX2V APP.app')
    parser.add_argument('--sample', type=Path, required=True, help='PNG fixture copied into the cache before launching')
    args = parser.parse_args()
    prepare(args.app, args.sample)
