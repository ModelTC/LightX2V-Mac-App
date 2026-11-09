#!/usr/bin/env python3
"""Run the packaged helper against disposable application and data fixtures."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

package = Path(sys.argv[1]).resolve()
helper = package / 'Contents/Helpers/LightX2VMaintenance'
assert helper.is_file() and os.access(helper, os.X_OK)

with tempfile.TemporaryDirectory(prefix='lightx2v-helper-check-') as directory:
    root = Path(directory).resolve()
    application = root / 'installed/LightX2V.app'
    binary = application / 'Contents/MacOS/fixture'
    binary.parent.mkdir(parents=True)
    shutil.copyfile('/bin/sleep', binary)
    binary.chmod(0o755)
    (application / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'app.lightx2v.desktop',
        'CFBundleExecutable': 'fixture',
        'CFBundlePackageType': 'APPL',
    }))
    workspace = root / 'workspace'
    cache = workspace / 'cache'
    kept_model = cache / 'kept-model'
    kept_model.mkdir(parents=True)
    (kept_model / 'weights.bin').write_bytes(b'kept model')
    deleted = cache / 'remove.bin'
    deleted.write_bytes(b'remove cache')
    unrelated = root / 'unrelated.txt'
    unrelated.write_bytes(b'unrelated user data')

    job = root / ('lightx2v-maintenance-' + str(uuid.uuid4()))
    job.mkdir(mode=0o700)
    (job / '.lightx2v-maintenance-job').write_text(str(uuid.uuid4()))
    executable = job / 'LightX2VMaintenance'
    shutil.copy2(helper, executable)
    executable.chmod(0o700)
    parent = subprocess.Popen(['/bin/sleep', '2'])

    def item(path, category, selected=True):
        return {'path': str(path), 'category': category, 'isExternal': False,
                'defaultSelected': selected}

    uninstall = {
        'items': [item(application, 'application'), item(cache, 'caches'), item(kept_model, 'models', False)],
        'workspaceRoots': [workspace.as_uri()],
        'applicationURL': application.as_uri(),
        'supportRoot': (root / 'support').as_uri(),
        'homeDirectory': Path.home().as_uri(),
        'preferenceDomains': [],
    }
    plan = {
        'operation': 'uninstall', 'parentPID': parent.pid,
        'applicationURL': application.as_uri(), 'uninstallPlan': uninstall,
        'selectedIDs': [str(application), str(cache)], 'jobDirectory': job.as_uri(),
    }
    request = job / 'plan.json'
    request.write_text(json.dumps(plan))
    log = root / 'helper.log'
    process = None
    try:
        with log.open('wb') as output:
            process = subprocess.Popen([str(executable), str(request)], cwd=job,
                                       stdout=output, stderr=subprocess.STDOUT)
            time.sleep(0.5)
            assert parent.poll() is None and process.poll() is None, log.read_text(errors='replace')
            assert application.exists() and deleted.exists(), 'Helper modified files before the parent exited'
            late = cache / 'created-during-shutdown.bin'
            late.write_bytes(b'late cache')
            parent.wait(timeout=10)
            assert process.wait(timeout=30) == 0, log.read_text(errors='replace')
        assert not application.exists(), 'Helper retained the selected application'
        assert not deleted.exists() and not late.exists(), 'Helper retained selected cache data'
        assert (kept_model / 'weights.bin').read_bytes() == b'kept model', 'Helper removed the retained model'
        assert unrelated.read_bytes() == b'unrelated user data', 'Helper changed an unrelated file'
        assert not job.exists(), 'Helper retained its maintenance files'
        print('PASS packaged native helper waits for exit, uninstalls selected files, keeps models and removes its job')
    finally:
        if parent.poll() is None:
            parent.terminate()
        parent.wait(timeout=10)
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)

    # Keep the app and configuration while clearing data, then verify the
    # production helper starts the retained bundle after completing cleanup.
    retained_app = root / 'retained/LightX2V.app'
    retained_binary = retained_app / 'Contents/MacOS/fixture'
    retained_binary.parent.mkdir(parents=True)
    launch_marker = root / 'retained-app-launched'
    fixture_source = root / 'retained-app.c'
    fixture_source.write_text(
        '#include <stdio.h>\n'
        'int main(void) {\n'
        '    FILE *output = fopen(' + json.dumps(str(launch_marker)) + ', "w");\n'
        '    if (output == NULL) return 1;\n'
        '    fputs("restarted", output);\n'
        '    fclose(output);\n'
        '    return 0;\n'
        '}\n')
    subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-Os', '-mmacosx-version-min=14.0',
                    str(fixture_source), '-o', str(retained_binary)], check=True)
    (retained_app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'app.lightx2v.desktop',
        'CFBundleExecutable': 'fixture',
        'CFBundleName': 'LightX2V',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1',
        'LSUIElement': True,
    }))
    subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(retained_app)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    retained_workspace = root / 'retained-workspace'
    removable_cache = retained_workspace / 'cache'
    removable_cache.mkdir(parents=True)
    removable_file = removable_cache / 'remove.bin'
    removable_file.write_bytes(b'remove data while retaining app')
    state = retained_workspace / 'workspace.json'
    state.write_text(json.dumps({'settings': {'workingDirectory': str(retained_workspace),
                                             'python': '/fixture/bin/python'}, 'generations': []}))
    support = root / 'retained-support'
    support.mkdir()
    locator = support / 'workspace_location.json'
    locator.write_text(json.dumps({'workingDirectory': str(retained_workspace)}))
    saved_state = state.read_bytes()
    saved_locator = locator.read_bytes()
    retained_job = root / ('lightx2v-maintenance-' + str(uuid.uuid4()))
    retained_job.mkdir(mode=0o700)
    (retained_job / '.lightx2v-maintenance-job').write_text(str(uuid.uuid4()))
    retained_helper = retained_job / 'LightX2VMaintenance'
    shutil.copy2(helper, retained_helper)
    retained_helper.chmod(0o700)
    retained_parent = subprocess.Popen(['/bin/sleep', '2'])
    retained_uninstall = {
        'items': [item(retained_app, 'application', False), item(removable_cache, 'caches'),
                  item(state, 'settings', False), item(support, 'settings', False)],
        'workspaceRoots': [retained_workspace.as_uri()],
        'applicationURL': retained_app.as_uri(),
        'supportRoot': support.as_uri(),
        'homeDirectory': Path.home().as_uri(),
        'preferenceDomains': [],
    }
    retained_plan = {
        'operation': 'uninstall', 'parentPID': retained_parent.pid,
        'applicationURL': retained_app.as_uri() + '/', 'uninstallPlan': retained_uninstall,
        'selectedIDs': [str(removable_cache)], 'jobDirectory': retained_job.as_uri(),
    }
    retained_request = retained_job / 'plan.json'
    retained_request.write_text(json.dumps(retained_plan))
    retained_log = root / 'retained-helper.log'
    retained_process = None
    try:
        with retained_log.open('wb') as output:
            retained_process = subprocess.Popen([str(retained_helper), str(retained_request)], cwd=retained_job,
                                               stdout=output, stderr=subprocess.STDOUT)
            time.sleep(0.5)
            assert retained_parent.poll() is None and retained_process.poll() is None, retained_log.read_text(errors='replace')
            assert removable_file.exists() and not launch_marker.exists(), 'Helper restarted or removed data before the parent exited'
            retained_parent.wait(timeout=10)
            assert retained_process.wait(timeout=30) == 0, retained_log.read_text(errors='replace')
        for _ in range(100):
            if launch_marker.exists():
                break
            time.sleep(0.1)
        assert launch_marker.read_text() == 'restarted', 'Helper did not relaunch the exact retained application bundle'
        assert retained_app.is_dir() and not removable_cache.exists(), 'Helper did not honor the app/data selection'
        assert state.read_bytes() == saved_state and locator.read_bytes() == saved_locator, 'Helper changed retained settings'
        assert not retained_job.exists(), 'Data-only uninstall retained its maintenance job'
        assert unrelated.read_bytes() == b'unrelated user data', 'Data-only uninstall changed unrelated user data'
        print('PASS packaged native helper keeps app/settings, clears selected data, relaunches and removes its job')
    finally:
        if retained_parent.poll() is None:
            retained_parent.terminate()
        retained_parent.wait(timeout=10)
        if retained_process is not None and retained_process.poll() is None:
            retained_process.terminate()
            retained_process.wait(timeout=10)
        registrar = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
        if registrar.is_file():
            subprocess.run([str(registrar), '-u', str(retained_app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # A valid, signed update can still fail to launch. Require a future macOS
    # version to exercise replacement followed by restoration of the old app.
    launch_marker.unlink()
    original_binary = retained_binary.read_bytes()
    original_info = (retained_app / 'Contents/Info.plist').read_bytes()
    rollback_job = root / ('lightx2v-maintenance-' + str(uuid.uuid4()))
    rollback_job.mkdir(mode=0o700)
    (rollback_job / '.lightx2v-maintenance-job').write_text(str(uuid.uuid4()))
    rollback_helper = rollback_job / 'LightX2VMaintenance'
    shutil.copy2(helper, rollback_helper)
    rollback_helper.chmod(0o700)
    prepared = retained_app.parent / ('.LightX2V-update-' + str(uuid.uuid4()) + '.app')
    shutil.copytree(retained_app, prepared)
    incompatible_info = plistlib.loads(original_info)
    incompatible_info['LSMinimumSystemVersion'] = '99.0'
    (prepared / 'Contents/Info.plist').write_bytes(plistlib.dumps(incompatible_info))
    subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(prepared)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(prepared)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rollback_parent = subprocess.Popen(['/bin/sleep', '2'])
    rollback_plan = {
        'operation': 'update', 'parentPID': rollback_parent.pid,
        'applicationURL': retained_app.as_uri(), 'selectedIDs': [],
        'jobDirectory': rollback_job.as_uri(), 'preparedApplicationURL': prepared.as_uri(),
        'originalApplicationDigest': hashlib.sha256(original_binary).hexdigest(),
    }
    rollback_request = rollback_job / 'plan.json'
    rollback_request.write_text(json.dumps(rollback_plan))
    rollback_log = root / 'rollback-helper.log'
    rollback_process = None
    try:
        with rollback_log.open('wb') as output:
            rollback_process = subprocess.Popen([str(rollback_helper), str(rollback_request)], cwd=rollback_job,
                                               stdout=output, stderr=subprocess.STDOUT)
            time.sleep(0.5)
            assert rollback_parent.poll() is None and rollback_process.poll() is None, rollback_log.read_text(errors='replace')
            assert retained_binary.read_bytes() == original_binary and prepared.is_dir(), 'Update replaced the app before the parent exited'
            rollback_parent.wait(timeout=10)
            assert rollback_process.wait(timeout=30) != 0, 'Incompatible update did not report its launch failure'
        for _ in range(100):
            if launch_marker.exists():
                break
            time.sleep(0.1)
        assert launch_marker.read_text() == 'restarted', 'Helper did not relaunch the restored application'
        assert retained_binary.read_bytes() == original_binary, 'Rollback changed the original executable'
        assert (retained_app / 'Contents/Info.plist').read_bytes() == original_info, 'Rollback changed the original Info.plist'
        assert not prepared.exists(), 'Rollback left its prepared application behind'
        assert not any(path.name.startswith('.LightX2V-backup-') for path in retained_app.parent.iterdir()), 'Rollback left an old application backup'
        result = json.loads((rollback_job / 'result.json').read_text())
        assert result['success'] is False and result['message'], 'Rollback did not retain an actionable failure report'
        assert 'kLSIncompatibleSystemVersionErr' in result['message'] or '-10825' in result['message'], 'Update failed before attempting the incompatible application launch'
        assert state.read_bytes() == saved_state and locator.read_bytes() == saved_locator, 'Failed update changed workspace settings'
        assert unrelated.read_bytes() == b'unrelated user data', 'Failed update changed unrelated user data'
        print('PASS packaged native helper replaces incompatible app, restores original bytes, relaunches and retains its failure report')
    finally:
        if rollback_parent.poll() is None:
            rollback_parent.terminate()
        rollback_parent.wait(timeout=10)
        if rollback_process is not None and rollback_process.poll() is None:
            rollback_process.terminate()
            rollback_process.wait(timeout=10)
        if registrar.is_file():
            subprocess.run([str(registrar), '-u', str(retained_app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
