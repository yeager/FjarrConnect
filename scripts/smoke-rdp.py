#!/usr/bin/env python3
"""Verify the packaged FreeRDP executable consumes piped arguments and starts RDP.

The loopback listener intentionally closes after the X.224 request. This checks
launch/linking, stdin argument parsing, networking and failure exit in authentication-only mode, not server
interoperability or a successful remote Windows login.
"""
import socket
import subprocess
import sys
import threading

with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(15)
    packets = []
    failures = []

    def receive():
        try:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                packets.append(connection.recv(4096))
        except OSError as error:
            failures.append(str(error))

    worker = threading.Thread(target=receive, daemon=True)
    worker.start()
    # Test-only dummy credentials; no real server or account is contacted.
    arguments = '\n'.join([
        f'/v:127.0.0.1:{listener.getsockname()[1]}', '/u:local-smoke-test',
        '/p:local-test-only', '/dynamic-resolution', '/size:1280x800',
        '/title:FjärrConnect', '/log-level:ERROR', '/timeout:5000', '+auth-only', '',
    ])
    try:
        result = subprocess.run([sys.argv[1], '/args-from:stdin'], input=arguments,
                                text=True, capture_output=True, timeout=20)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f'RDP timed out: packets={packets!r}, listener errors={failures!r}, '
            f'stderr={error.stderr!r}') from error
    worker.join(timeout=16)
    assert not worker.is_alive(), 'RDP did not contact the local test listener'
    assert not failures, f'RDP test listener failed: {failures}'
    assert packets and packets[0].startswith(b'\x03\x00'), (
        'No RDP TPKT/X.224 negotiation received; client may have failed to start or parse arguments.\n'
        + result.stderr[-2000:])
    assert result.returncode != 0, 'Unexpected success after the test server closed'
print('Packaged RDP client launched, consumed stdin arguments, sent RDP negotiation and handled disconnect.')
