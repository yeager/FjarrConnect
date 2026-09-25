#!/usr/bin/env python3
"""Exercise packaged clipboard paths and localized certificate rejection.

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
architectures = subprocess.check_output(['lipo', '-archs', str(library)], text=True).split()
assert len(architectures) == 1, f'Expected one runtime architecture, found {architectures}'
architecture = architectures[0]
linked_symbols = subprocess.check_output(['nm', '-a', str(library)], text=True)
required_crypto_symbols = {
    '_SSL_CTX_new', '_TLS_client_method', '_EVP_aes_128_gcm', '_EVP_aes_256_gcm',
    '_EVP_sha256', '_EVP_sha384'
}
missing_crypto_symbols = sorted(
    symbol for symbol in required_crypto_symbols
    if not re.search(rf'\s{re.escape(symbol)}$', linked_symbols, re.MULTILINE)
)
assert not missing_crypto_symbols, (
    f'{architecture} FreeRDP runtime is missing statically linked OpenSSL symbols: '
    f'{", ".join(missing_crypto_symbols)}')
print(f'RDP {architecture}: static OpenSSL TLS, AES-128/256-GCM, and SHA-256/384 symbols are linked.')
artifact_headers = ROOT / f'build/rdp-artifacts/rdp-{architecture}/SmokeHeaders'
if (artifact_headers / 'freerdp/include/freerdp/error.h').is_file():
    freerdp = artifact_headers / 'freerdp'
    freerdp_build = artifact_headers / 'build'
else:
    # Local runtime builds keep their source checkout and generated headers
    # under build/rdp-ARCH; release jobs consume the header subset above.
    freerdp = ROOT / f'build/rdp-{architecture}/FreeRDP'
    freerdp_build = ROOT / f'build/rdp-{architecture}/FreeRDP-build'
assert (freerdp / 'include/freerdp/error.h').is_file(), f'Pinned FreeRDP headers not found: {freerdp}'
assert (freerdp_build / 'freerdp/winpr/include/winpr/config.h').is_file(), (
    f'Generated FreeRDP headers not found: {freerdp_build}')
version_header = freerdp_build / 'freerdp/include/freerdp/version.h'
if not version_header.is_file():  # Build artifacts from older CI runs omitted this generated header.
    version_header = freerdp / 'include/freerdp/version.h'
assert version_header.is_file(), f'FreeRDP version header not found: {version_header}'
version = re.search(r'^#define FREERDP_VERSION "([^"]+)"', version_header.read_text(), re.MULTILINE)
assert version and version.group(1) == '3.32.0', (
    f'{architecture} runtime was built from unexpected FreeRDP version: '
    f'{version.group(1) if version else "unknown"}')
openssl_header = freerdp_build / 'openssl/include/openssl/opensslv.h'
if openssl_header.is_file():
    openssl_version = re.search(r'^#\s*define OPENSSL_VERSION_TEXT "OpenSSL ([^" ]+)',
                                openssl_header.read_text(), re.MULTILINE)
    assert openssl_version, f'Bundled OpenSSL version not found in {openssl_header}'
    print(f'RDP {architecture}: FreeRDP {version.group(1)} with OpenSSL {openssl_version.group(1)}.')
else:
    print(f'RDP {architecture}: FreeRDP {version.group(1)}; OpenSSL version header unavailable in this artifact.')


def translations(language):
    source = (ROOT / f'Resources/{language}.lproj/Localizable.strings').read_text()
    quoted = r'"(?:[^"\\]|\\.)*"'
    return {json.loads(key): json.loads(value) for key, value in
            re.findall(f'({quoted})\\s*=\\s*({quoted})\\s*;', source)}


with tempfile.TemporaryDirectory(prefix='fjarr-rdp-smoke-') as temporary:
    directory = Path(temporary)
    probe = directory / 'FjarrRDPProbe'
    subprocess.run(['xcrun', 'clang', '-arch', architecture, '-fobjc-arc', '-framework', 'AppKit',
                    '-I', str(ROOT / 'NativeRDP'), '-I', str(freerdp / 'include'),
                    '-I', str(freerdp / 'winpr/include'), '-I', str(freerdp_build / 'freerdp/include'),
                    '-I', str(freerdp_build / 'freerdp/winpr/include'), str(ROOT / 'NativeRDP/Tests/Probe.m'),
                    str(library), '-Wl,-rpath,' + str(library.parent), '-o', str(probe)], check=True)
    empty_translations = directory / 'empty-translations.json'
    empty_translations.write_text('{}')
    keyboard_check = subprocess.run([str(probe), str(empty_translations), str(directory / 'desktop.png')],
                                    input='', text=True, capture_output=True, timeout=15,
                                    env=dict(os.environ, FC_TEST_KEYBOARD_INPUT='1'))
    assert keyboard_check.returncode == 0, (
        f'RDP Unicode keyboard input encoding failed (exit {keyboard_check.returncode}): '
        f'{keyboard_check.stdout}\n{keyboard_check.stderr}')
    print(f'RDP {architecture}: Unicode keyboard input passed (@, Swedish, Euro, CJK, supplementary scalar).')
    image_check = subprocess.run([str(probe), str(empty_translations), str(directory / 'desktop.png')],
                                 input='', text=True, capture_output=True, timeout=15,
                                 env=dict(os.environ, FC_TEST_CLIPBOARD_IMAGE='1'))
    assert image_check.returncode == 0, f'RDP image clipboard round-trip failed: {image_check.stdout}\n{image_check.stderr}'
    activation_check = subprocess.run([str(probe), str(empty_translations), str(directory / 'desktop.png')],
                                      input='', text=True, capture_output=True, timeout=15,
                                      env=dict(os.environ, FC_TEST_CLIPBOARD_ACTIVATION='1'))
    assert activation_check.returncode == 0, (
        f'RDP clipboard activation isolation failed: {activation_check.stdout}\n{activation_check.stderr}')
    print(f'RDP {architecture}: active-session clipboard capture and inactive-session clearing passed.')
    files_check = subprocess.run([str(probe), str(empty_translations), str(directory / 'desktop.png')],
                                 input='', text=True, capture_output=True, timeout=15,
                                 env=dict(os.environ, FC_TEST_CLIPBOARD_FILES='1'))
    assert files_check.returncode == 0, (
        f'RDP file clipboard manifest validation failed: {files_check.stdout}\n{files_check.stderr}')
    print(f'RDP {architecture}: local file-descriptor validation passed; network file clipboard remains disabled.')
    failure_check = subprocess.run([str(probe), str(empty_translations), str(directory / 'desktop.png')],
                                   input='', text=True, capture_output=True, timeout=15,
                                   env=dict(os.environ, FC_TEST_FAILURE_CATEGORIES='1'))
    assert failure_check.returncode == 0, (
        f'RDP failure-category mapping failed (exit {failure_check.returncode}): '
        f'{failure_check.stdout}\n{failure_check.stderr}')
    print(f'RDP {architecture}: {failure_check.stdout.strip()}')
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
                                   '/size:1280x800', '/dynamic-resolution', '/kbd:layout:0x0000041D',
                                   '+clipboard', '/sec:tls', ''])
            result = subprocess.run([str(probe), str(locale_file), str(directory / 'desktop.png')],
                                    input=arguments, text=True, capture_output=True, timeout=30, env=environment)
            worker.join(timeout=16)
            assert not worker.is_alive() and not failures, f'{language}: TLS fixture failed: {failures}'
            assert received, f'{language}: library did not start RDP negotiation'
            assert result.returncode == 0 and 'certificate=1 rejected=1 status=3' in result.stdout, (
                f'{language}: certificate rejection failed: {result.stdout}\n{result.stderr[-1500:]}')
            print(f'{language}: embedded NSView connected, displayed the localized certificate dialog and rejected it.')
print('Packaged RDP library: certificate rejection passed in all nine languages.')
