#!/usr/bin/env python3
"""Launch the actual release executable without Xcode's DYLD search paths.

The optional negative control removes RoyalVNCKit from a disposable copy and
requires dyld to reject it, reproducing the 0.2.0 startup regression.
"""
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


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


def launched_application_pid(executable, token):
    """Find only the app process started for this smoke run."""
    ps = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    for line in ps.splitlines():
        pid, _, command = line.strip().partition(' ')
        executable_argument = command.split(' ', 1)[0]
        if token not in command:
            continue
        try:
            same_executable = Path(executable_argument).resolve() == executable
        except OSError:
            same_executable = False
        if same_executable:
            return int(pid)
    return None


def stop_launched_application(executable, token):
    """Clean up the app itself; terminating `open -W` alone leaves it running."""
    pid = launched_application_pid(executable, token)
    if pid is None:
        return
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass


def launch(app, should_start=True):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('DYLD_', 'XCTest', 'XCInject'))}
    with tempfile.TemporaryDirectory(prefix='fjarrconnect-launch-bundle-') as bundle_directory:
        # Keep the bundle outside protected folders such as Documents. dyld
        # must be able to load every embedded framework before AppKit starts.
        runnable_app = Path(bundle_directory) / app.name
        subprocess.run(['ditto', str(app), str(runnable_app)], check=True)
        copied_signature = subprocess.run(
            ['codesign', '--verify', '--deep', '--strict', str(runnable_app)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if copied_signature.returncode != 0:
            raise AssertionError(f'Copied app signature is invalid: {copied_signature.stderr.strip()}')
        executable = (runnable_app / 'Contents/MacOS/FjarrConnect').resolve()
        with tempfile.TemporaryDirectory(prefix='fjarrconnect-launch-home-') as directory:
            # Foundation ignores HOME on macOS when resolving applicationSupportDirectory.
            # Its per-process home override keeps startup checks away from saved profiles.
            environment['CFFIXED_USER_HOME'] = directory
            environment['TMPDIR'] = directory
            token = str(uuid.uuid4())
            marker_name = f'fjarrconnect-smoke-{token.upper()}'
            # Launch Services can replace TMPDIR with the user's normal temp
            # directory instead of preserving the isolated launch environment.
            markers = [Path(directory) / marker_name,
                       Path(tempfile.gettempdir()) / marker_name]
            if should_start:
                # Launch through Launch Services. Executing an app-bundle binary
                # directly can fail macOS's app-to-process sandbox extension
                # checks even when the bundle itself is valid and signed.
                process = subprocess.Popen(
                    ['/usr/bin/open', '-n', '-W', str(runnable_app), '--args',
                     '--fc-smoke-ready', token], cwd=directory, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            else:
                process = subprocess.Popen([str(executable)], cwd=directory, env=environment,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with process:
                if should_start:
                    deadline = time.monotonic() + 12
                    while not any(marker.exists() for marker in markers) and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if any(marker.exists() for marker in markers):
                        # Find only the app process started with this unique
                        # marker token; never terminate another FjarrConnect.
                        launched_pid = launched_application_pid(executable, token)
                        if launched_pid is None:
                            raise AssertionError('Launch Services reported success but the app process was not found')
                        os.kill(launched_pid, 15)
                        try:
                            stdout, stderr = process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            stdout, stderr = process.communicate()
                        print('Packaged app completed launch and displayed its window content.')
                        return
                    process.terminate()
                    try:
                        stdout, stderr = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        stdout, stderr = process.communicate()
                    stop_launched_application(executable, token)
                    diagnostics = stderr.decode('utf-8', errors='replace')
                    raise AssertionError(
                        f'Packaged app did not reach its window content (exit {process.returncode}):\n{diagnostics}')
                try:
                    stdout, stderr = process.communicate(timeout=8)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        stdout, stderr = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        stdout, stderr = process.communicate()
                    raise AssertionError('Missing-framework control unexpectedly stayed running')
                diagnostics = stderr.decode('utf-8', errors='replace')
                assert process.returncode != 0 and 'RoyalVNCKit' in diagnostics and 'Library not loaded' in diagnostics, diagnostics
                print('Negative control reproduced missing RoyalVNCKit and was rejected.')


app = Path(sys.argv[1]).resolve()
signature = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if signature.returncode != 0:
    raise AssertionError(f'Packaged app signature is invalid before runtime load: {signature.stderr.strip()}')
rdp_runtime = app / 'Contents/Frameworks/libFjarrRDP.dylib'
if not rdp_runtime.is_file():
    raise AssertionError(f'Packaged app is missing its embedded RDP component: {rdp_runtime}')
runtime_architectures = subprocess.check_output(['lipo', '-archs', str(rdp_runtime)], text=True).split()
if len(runtime_architectures) != 1:
    raise AssertionError(f'Packaged RDP component must be single-architecture: {runtime_architectures}')
runtime_architecture = runtime_architectures[0]
if (runtime_architecture != platform.machine() and
        os.environ.get('FC_SMOKE_APP_ARCH_WRAPPED') != '1'):
    environment = dict(os.environ, FC_SMOKE_APP_ARCH_WRAPPED='1')
    result = subprocess.run(['arch', f'-{runtime_architecture}', sys.executable,
                             str(Path(__file__).resolve()), str(app), *sys.argv[2:]], env=environment)
    raise SystemExit(result.returncode)
symbols = subprocess.check_output(['nm', '-gU', str(rdp_runtime)], text=True)
if '_fc_rdp_abi' not in symbols:
    raise AssertionError('Packaged RDP component is missing its versioned ABI entry point')
print(f'Packaged RDP component has an architecture-matched ABI entry point ({runtime_architecture}).')
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
