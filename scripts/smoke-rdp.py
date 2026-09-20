#!/usr/bin/env python3
"""Exercise the packaged embedded RDP library and localized certificate rejection.

A disposable TLS server speaks the RDP negotiation, then presents a self-signed
certificate. The test-only Cocoa probe checks the real certificate dialog and
rejects it. No credentials reach a remote account and no trust entry is saved.
"""
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
library = Path(sys.argv[1]).resolve()
assert library.is_file(), library


def translations(language):
    source = (ROOT / f'Resources/{language}.lproj/Localizable.strings').read_text()
    quoted = r'"(?:[^"\\]|\\.)*"'
    return {json.loads(key): json.loads(value) for key, value in
            re.findall(f'({quoted})\\s*=\\s*({quoted})\\s*;', source)}


with tempfile.TemporaryDirectory(prefix='fjarr-rdp-smoke-') as temporary:
    directory = Path(temporary)
    probe = directory / 'FjarrRDPProbe'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'AppKit',
                    '-I', str(ROOT / 'NativeRDP'), str(ROOT / 'NativeRDP/Tests/Probe.m'),
                    str(library), '-Wl,-rpath,' + str(library.parent), '-o', str(probe)], check=True)
    certificate, key = directory / 'certificate.pem', directory / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-keyout', str(key), '-out', str(certificate), '-subj', '/CN=FjarrConnect local test'],
                   check=True, capture_output=True)
    key.chmod(0o600)
    fingerprint = subprocess.check_output(['openssl', 'x509', '-in', str(certificate),
                                          '-noout', '-fingerprint', '-sha256'], text=True).strip().split('=', 1)[1]
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certificate, key)
    for language in ['en', 'sv', 'da', 'nb', 'de', 'fi', 'fr', 'es', 'ja']:
        strings = translations(language)
        locale_file = directory / 'translations.json'
        locale_file.write_text(json.dumps(strings, ensure_ascii=False))
        received = []
        failures = []
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.settimeout(15)
            port = listener.getsockname()[1]

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(10)
                        packet = connection.recv(4096)
                        received.append(packet)
                        assert packet.startswith(b'\x03\x00'), 'Expected TPKT/X.224'
                        connection.sendall(bytes.fromhex('030000130ed000000000000200080001000000'))
                        try:
                            with tls.wrap_socket(connection, server_side=True) as secure:
                                secure.recv(4096)
                        except (ssl.SSLError, ConnectionResetError):
                            pass  # Rejecting the untrusted certificate closes TLS.
                except Exception as error:
                    failures.append(str(error))

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            environment = dict(os.environ, FC_TEST_CERT_FINGERPRINT=fingerprint,
                               FC_TEST_CERT_TITLE=strings['rdp.cert.title'], FC_TEST_CERT_REJECT='1')
            arguments = '\n'.join([f'/v:127.0.0.1:{port}', '/u:fixture', '/p:local-test-only',
                                   '/size:1280x800', '/dynamic-resolution', '+clipboard', '/sec:tls', ''])
            result = subprocess.run([str(probe), str(locale_file), str(directory / 'desktop.png')],
                                    input=arguments, text=True, capture_output=True, timeout=30, env=environment)
            worker.join(timeout=16)
            assert not worker.is_alive() and not failures, f'{language}: TLS fixture failed: {failures}'
            assert received, f'{language}: library did not start RDP negotiation'
            assert result.returncode == 0 and 'certificate=1 rejected=1 status=3' in result.stdout, (
                f'{language}: certificate rejection failed: {result.stdout}\n{result.stderr[-1500:]}')
            print(f'{language}: embedded NSView connected, displayed the localized certificate dialog and rejected it.')
print('Packaged RDP library: certificate rejection passed in all nine languages.')
