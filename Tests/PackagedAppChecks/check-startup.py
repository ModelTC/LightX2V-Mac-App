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

    def launch(package, label, configured=True, expect_probe=True):
        fixture = root / label
        support = fixture / 'support'
        workspace = fixture / 'workspace'
        support.mkdir(parents=True)
        workspace.mkdir()
        marker = fixture / 'probe-ran'
        python = fixture / 'python'
        python.write_text('#!/bin/sh\nprintf probe > "' + str(marker) + '"\nprintf \'LIGHTX2V_ENV:{"python":"3.11.9","architecture":"arm64","mps":true}\\n\'\n')
        python.chmod(0o755)
        if configured:
            (support / 'workspace_location.json').write_text(json.dumps({'workingDirectory': str(workspace)}))
            (workspace / 'workspace.json').write_text(json.dumps({
                'settings': {'repository': '', 'model': '', 'config': '', 'python': str(python), 'workingDirectory': str(workspace)},
                'generations': [], 'hasCompletedGeneralSetup': True,
            }))
        log = fixture / 'startup.log'
        with log.open('wb') as output:
            process = subprocess.Popen([str(package / 'Contents/MacOS/LightX2VApp')],
                env={**os.environ, 'LIGHTX2V_APP_STATE_DIR': str(support)}, stdout=output, stderr=output)
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
                print('PASS packaged APP stays running: ' + label, flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=15)

    launch(app, 'first-launch', configured=False)
    launch(app, 'configured-offline-startup')
    broken = root / 'missing-resource.app'
    shutil.copytree(app, broken, symlinks=True)
    (broken / 'Contents/Resources/Bundled/llama-b11583-bin-macos-arm64.tar.gz').unlink()
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(broken)], check=True)
    launch(broken, 'missing-resource-error', expect_probe=False)
