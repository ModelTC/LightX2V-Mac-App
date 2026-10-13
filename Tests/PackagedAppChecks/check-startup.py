#!/usr/bin/env python3
"""Local regression: launch the real signed APP without SwiftPM resource bundles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
assert app.suffix == '.app'
assert not list(app.rglob('LightX2VAPP_*.bundle'))
with tempfile.TemporaryDirectory(prefix='lightx2v-packaged-startup-') as folder:
    root = Path(folder)

    def launch(package, label, configured=True, expect_probe=True, old_state=False, old_schema=False):
        fixture = root / label
        support = fixture / 'support'
        workspace = fixture / 'workspace'
        support.mkdir(parents=True)
        workspace.mkdir()
        marker = fixture / 'probe-ran'
        python = fixture / 'python'
        python.write_text('#!/bin/sh\nprintf probe > "' + str(marker) + '"\nprintf \'LIGHTX2V_ENV:{"python":"3.11.9","architecture":"arm64","mps":true}\\n\'\n')
        python.chmod(0o755)
        if old_state:
            (support / 'workspace.json').write_text(json.dumps({
                'settings': {'repository': '', 'model': '', 'config': '', 'python': str(python), 'workingDirectory': str(workspace)},
                'generations': [], 'hasCompletedGeneralSetup': True,
            }))
            (support / 'location.json').write_text('invalid old location')
        original_files = {p: p.read_bytes() for p in support.iterdir() if p.is_file()}
        if configured:
            (support / 'workspace_location.json').write_text(json.dumps({'workingDirectory': str(workspace)}))
            (workspace / 'workspace.json').write_text(json.dumps({
                'settings': {'python': str(python), 'workingDirectory': str(workspace), 'Qwen-Image-2.1-Turbo': {'modelDirectory': '', 'modelDownloadSource': 'huggingFace', 'promptEnhancement': {'enabled': True, 't2iDirectory': '', 'i2iDirectory': ''}}},
                'generations': [], 'hasCompletedGeneralSetup': True,
            }))
            if old_schema:
                (workspace / 'workspace.json').write_text(json.dumps({
                    'settings': {'repository': '', 'model': '', 'config': '', 'python': str(python), 'workingDirectory': str(workspace)},
                    'generations': [], 'hasCompletedGeneralSetup': True,
                }))
        original_workspace = (workspace / 'workspace.json').read_bytes() if old_schema else None
        log = fixture / 'startup.log'
        suite = 'local.lightx2v.packaged-startup.' + root.name + '.' + label
        with log.open('wb') as output:
            process = subprocess.Popen([str(package / 'Contents/MacOS/LightX2VApp')],
                env={**os.environ, 'LIGHTX2V_APP_STATE_DIR': str(support), 'LIGHTX2V_APP_PREFERENCES_SUITE': suite}, stdout=output, stderr=output)
            try:
                if configured and expect_probe:
                    for _ in range(400):
                        assert process.poll() is None, log.read_text(errors='replace')
                        if marker.exists():
                            break
                        time.sleep(0.1)
                    assert marker.exists(), 'Packaged APP did not complete offline preparation and reach the Python probe'
                    installed = workspace / 'runtimes/bundled-LightX2V-0.6.0-minimal-v1-llama-b11583'
                    assert (installed / 'LightX2V-0.6.0/lightx2v/infer.py').is_file()
                    assert (installed / 'llama-b11583/llama-completion').is_file()
                time.sleep(3)
                assert process.poll() is None, log.read_text(errors='replace')
                assert 'Fatal error' not in log.read_text(errors='replace')
                if old_schema:
                    assert not marker.exists(), 'Packaged APP accepted the flat model configuration'
                    assert (workspace / 'workspace.json').read_bytes() == original_workspace, 'Packaged APP changed rejected old configuration'
                if old_state:
                    assert not marker.exists(), 'Packaged APP probed an ignored old environment'
                    assert not (workspace / 'outputs').exists(), 'Packaged APP prepared an ignored old workspace'
                    assert not (workspace / 'runtimes').exists(), 'Packaged APP prepared an ignored old workspace'
                    assert all(p.read_bytes() == value for p, value in original_files.items()), 'Packaged APP rewrote ignored old files'
                    assert not (support / 'workspace_location.json').exists(), 'Packaged APP recreated a locator from old files'
                print('PASS packaged APP stays running: ' + label, flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=15)
                subprocess.run(['defaults', 'delete', suite], capture_output=True)

    launch(app, 'first-launch', configured=False)
    launch(app, 'first-launch-with-old-files', configured=False, old_state=True)
    launch(app, 'configured-offline-startup')
    launch(app, 'reject-flat-model-settings', old_schema=True, expect_probe=False)
    broken = root / 'missing-resource.app'
    shutil.copytree(app, broken, symlinks=True)
    (broken / 'Contents/Resources/Bundled/llama-b11583-bin-macos-arm64.tar.gz').unlink()
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(broken)], check=True)
    launch(broken, 'missing-resource-error', expect_probe=False)
