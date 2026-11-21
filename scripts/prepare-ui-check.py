#!/usr/bin/env python3
"""Prepare a persistent native UI fixture outside macOS protected folders.

Run after scripts/build.sh, with --sample pointing to any PNG fixture. Launch
the printed app path through the UI. The default fixture lives in Library/Caches.
Use --root to give a new fixture its own directory.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid


FIXTURE = '''#!/usr/bin/env python3
import json, shutil, sys, time
from pathlib import Path
def emit(kind, **fields): print(json.dumps(dict(type=kind, **fields)), flush=True)
if '-c' in sys.argv:
    environment = Path(__file__).with_name('environment.json').read_text()
    print('LIGHTX2V_ENV:' + json.dumps(json.loads(environment)), flush=True)
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
    root = (root or Path.home() / 'Library/Caches/LightX2V-APP-UI-Check').resolve()
    app = root / 'LightX2V UI Check.app'
    workspace = root / 'workspace'
    state_path = workspace / 'workspace.json'
    state = json.loads(state_path.read_text(encoding='utf-8')) if state_path.exists() else None
    if state is not None and any('request' in job for job in state['generations']):
        raise SystemExit('This fixture uses an obsolete history format. Use --root with a fresh directory.')
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
    requirements = app / 'Contents/Resources/requirements.txt'
    versions = {}
    for line in requirements.read_text(encoding='utf-8').splitlines():
        name, separator, version = line.strip().partition('==')
        if separator and not name.startswith('#'):
            versions[name.lower()] = version
    # Probe keys include both hyphenated and underscored package names.
    versions.update({name.replace('-', '_'): version for name, version in versions.items()})
    versions.update(python='3.11.17', architecture='arm64', mps=True, detail='UI fixture')
    write_json(root / 'environment.json', versions)

    model = root / 'Qwen-Image-2.1-Turbo'
    for folder in ['transformer', 'text_encoder', 'vae', 'scheduler', 'processor']:
        (model / folder).mkdir(parents=True, exist_ok=True)
    write_json(model / 'model_index.json', {})
    t2i = root / 'PE-T2I'
    i2i = root / 'PE-I2I'
    for mode, folder in [('T2I', t2i), ('I2I', i2i)]:
        folder.mkdir(exist_ok=True)
        (folder / 'system_prompt.txt').write_text('UI fixture', encoding='utf-8')
        (folder / ('Qwen-Image-2.1-PE-' + mode + '-Q8_0.gguf')).write_text('UI fixture', encoding='utf-8')
    (i2i / 'mmproj-Qwen-Image-2.1-PE-I2I-BF16.gguf').write_text('UI fixture', encoding='utf-8')
    pe = dict(enabled=True, t2iDirectory=str(t2i), i2iDirectory=str(i2i))
    pe_model = 'Qwen-Image-2.1-PE-T2I-GGUF-Q8_0'
    resources = app / 'Contents/Resources'
    config = resources / 'qwen_image_21_turbo.json'
    bundled = json.loads((resources / 'Bundled/manifest.json').read_text(encoding='utf-8'))
    source_root = next(entry['archive_root'] for entry in bundled.values() if 'archive_root' in entry)
    llama_root = next(name.removesuffix('-bin-macos-arm64.tar.gz') for name in bundled if name.startswith('llama-'))
    runtime = workspace / 'runtimes' / f'bundled-{source_root}-minimal-v2-{llama_root}'
    persisted_settings = dict(python=str(executable), workingDirectory=str(workspace),
        **{'Qwen-Image-2.1-Turbo': dict(modelDirectory=str(model), modelDownloadSource='huggingFace', promptEnhancement=pe)})
    if state is not None:
        state['settings'] = persisted_settings
    else:
        job_id = str(uuid.uuid4()).upper()
        directory = workspace / 'outputs' / job_id
        output = directory / 'image.png'
        directory.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sample, output)
        created = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        job = dict(
            id=job_id, creationID=job_id, createdAt=created, status='completed',
            model=dict(name=model.name, directory=str(model), configFile=str(config)),
            parameters=dict(resolution=1024, aspectRatio='adaptive', width=1024, height=1024, steps=8, seed=42),
            prompt='A quiet glass house in a misty forest',
            promptEnhancement=dict(
                enabled=True, mode='t2i', status='completed', modelName=pe_model, directory=str(t2i),
                modelFile=str(t2i / 'Qwen-Image-2.1-PE-T2I-Q8_0.gguf'),
                systemPromptFile=str(t2i / 'system_prompt.txt'), runtimeDirectory=str(runtime / llama_root),
                thinking='保留构图，补充晨光与材质。\n' * 25,
                output='A quiet glass house in a misty forest, with soft morning light and natural textures.',
                whRatio='1:1', ratioFollow='', durationSeconds=12),
            inputImages=[], outputImages=[str(output)],
            execution=dict(directory=str(directory), sourceDirectory=str(runtime / source_root),
                           python=str(executable), requestFile=str(directory / 'request.json'),
                           logFile=str(directory / 'run.log'), startedAt=created, durationSeconds=14))
        write_json(directory / 'generation.json', job)
        state = dict(settings=persisted_settings, generations=[job], hasCompletedGeneralSetup=True,
                     creationSettings={}, activeCreationID=job_id)
    write_json(state_path, state)
    write_json(root / 'support/workspace_location.json', dict(workingDirectory=str(workspace)))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/LightX2V.app')
    parser.add_argument('--sample', type=Path, required=True, help='PNG fixture copied into the cache before launching')
    parser.add_argument('--root', type=Path, help='A separate cache directory for a fresh UI workspace')
    args = parser.parse_args()
    prepare(args.app, args.sample, args.root)
