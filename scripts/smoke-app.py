#!/usr/bin/env python3
"""Launch the actual release executable without Xcode's DYLD search paths.

The optional negative control removes RoyalVNCKit from a disposable copy and
requires dyld to reject it, reproducing the 0.2.0 startup regression.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def remove_external_rpaths(app):
    """Keep the missing-framework control inside its copied app bundle.

    Debug Swift packages add an absolute PackageFrameworks rpath.  dyld can use
    that original build directory even after the framework is removed from the
    disposable app copy, which makes a missing-framework check meaningless.
    """
    for binary in (app / 'Contents').rglob('*'):
        if not binary.is_file():
            continue
        inspection = subprocess.run(['otool', '-l', str(binary)], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if inspection.returncode != 0:
            continue
        lines = iter(inspection.stdout.splitlines())
        for line in lines:
            if line.strip() != 'cmd LC_RPATH':
                continue
            next(lines, None)  # cmdsize
            path_line = next(lines, '')
            if not path_line.strip().startswith('path /'):
                continue
            path = path_line.strip().split(' (offset ', 1)[0].removeprefix('path ')
            subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def launch(app, should_start=True):
    executable = app / 'Contents/MacOS/FjarrConnect'
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('DYLD_', 'XCTest', 'XCInject'))}
    with tempfile.TemporaryDirectory(prefix='fjarrconnect-launch-') as directory:
        # Foundation ignores HOME on macOS when resolving applicationSupportDirectory.
        # Its per-process home override keeps startup checks away from saved profiles.
        environment['CFFIXED_USER_HOME'] = directory
        with subprocess.Popen([str(executable)], cwd=directory, env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                stdout, stderr = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    stdout, stderr = process.communicate()
                if not should_start:
                    raise AssertionError('Missing-framework control unexpectedly started')
                print('Packaged app stayed running after launch without DYLD overrides.')
                return
            diagnostics = stderr.decode('utf-8', errors='replace')
            if should_start:
                raise AssertionError(f'Packaged app exited during startup ({process.returncode}):\n{diagnostics}')
            assert process.returncode != 0 and 'RoyalVNCKit' in diagnostics and 'Library not loaded' in diagnostics, diagnostics
            print('Negative control reproduced missing RoyalVNCKit and was rejected.')


app = Path(sys.argv[1]).resolve()
if '--check-missing-framework' in sys.argv[2:]:
    with tempfile.TemporaryDirectory(prefix='fjarrconnect-missing-framework-') as directory:
        broken = Path(directory) / 'FjarrConnect.app'
        shutil.copytree(app, broken, symlinks=True)
        remove_external_rpaths(broken)
        shutil.rmtree(broken / 'Contents/Frameworks/RoyalVNCKit.framework')
        # Changing load commands and removing executable code invalidates a
        # copied app's signature on Apple Silicon. Re-sign only this disposable
        # control so dyld, rather than code-signing enforcement, reports the
        # missing framework.
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(broken)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        launch(broken, should_start=False)
launch(app)
