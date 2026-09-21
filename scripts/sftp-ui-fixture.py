#!/usr/bin/env python3
"""Private, real OpenSSH fixture for the file-browser UI test (macOS only)."""
import contextlib
import getpass
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


@contextlib.contextmanager
def fixture():
    # The UI runner does not inherit arbitrary xcodebuild environment variables.
    # A fixed, owner-only manifest locates the random private fixture directory.
    manifest = Path('/tmp/fjarrconnect-sftp-ui-fixture.json')
    descriptor = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    server = None
    try:
        with os.fdopen(descriptor, 'w') as output, tempfile.TemporaryDirectory(prefix='fjarr-sftp-ui-', dir='/tmp') as temporary:
            root = Path(temporary)
            remote = root / 'remote'
            remote.mkdir(mode=0o700)
            (remote / 'first.txt').write_bytes(b'First remote file\n')
            (remote / 'folder').mkdir()
            (remote / 'folder' / 'nested.txt').write_bytes(b'Nested remote file\n')
            source = root / 'upload source.txt'
            source.write_bytes('Uploaded through the real file picker: åäö 日本語\n'.encode())
            for name in ('host', 'client'):
                subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            (root / 'known_hosts').write_text(f'[127.0.0.1]:{port} ' + (root / 'host.pub').read_text())
            configuration = root / 'ssh.conf'
            configuration.write_text(f'''Host *
    UserKnownHostsFile {root}/known_hosts
    GlobalKnownHostsFile /dev/null
    IdentityAgent none
    IdentitiesOnly yes
    IdentityFile {root}/client
    AddKeysToAgent no
    PreferredAuthentications publickey
    StrictHostKeyChecking yes
''')
            server_config = root / 'sshd.conf'
            server_config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers {getpass.getuser()}
Subsystem sftp internal-sftp
LogLevel ERROR
''')
            subprocess.run(['/usr/sbin/sshd', '-t', '-f', str(server_config)], check=True)
            server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(server_config)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            while True:
                if server.poll() is not None:
                    raise RuntimeError('SFTP UI fixture stopped before accepting connections')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.02)
            json.dump(dict(directory=str(root), remote=str(remote), configuration=str(configuration), port=port, username=getpass.getuser(), upload=str(source)), output)
            output.flush()
            try:
                yield
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                server = None
    finally:
        if server is not None and server.poll() is None:
            server.kill()
            server.wait(timeout=5)
        manifest.unlink(missing_ok=True)
