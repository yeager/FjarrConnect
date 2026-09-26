#!/usr/bin/env python3
"""Run tests with loopback VNC discovery and real OpenSSH file-browser fixtures."""
import contextlib
import importlib.util
import os
import socketserver
import subprocess
import sys
import threading
from pathlib import Path


def test_environment():
    """Expose XCTest.framework on Xcode versions that no longer provide its legacy rpath."""
    environment = os.environ.copy()
    try:
        developer_dir = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    except (OSError, subprocess.CalledProcessError):
        return environment

    frameworks = developer_dir / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    if not (frameworks / "XCTest.framework").is_dir():
        return environment

    existing = environment.get("DYLD_FRAMEWORK_PATH", "").split(os.pathsep)
    paths = dict.fromkeys([str(frameworks), *(path for path in existing if path)])
    environment["DYLD_FRAMEWORK_PATH"] = os.pathsep.join(paths)
    return environment


class Banner(socketserver.BaseRequestHandler):
    def handle(self):
        with contextlib.suppress(ConnectionError, TimeoutError):
            self.request.settimeout(3)
            self.request.sendall(b"RFB 003.008\n")
            self.request.recv(1)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: with-vnc-test-fixture.py command [arguments ...]")
    # A collision fails immediately instead of testing against an unknown service.
    spec = importlib.util.spec_from_file_location('sftp_ui_fixture', Path(__file__).with_name('sftp-ui-fixture.py'))
    sftp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sftp)
    with sftp.fixture(), Server(("127.0.0.1", 45905), Banner) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.call(sys.argv[1:], env=test_environment())
        finally:
            server.shutdown()
            thread.join()
    sys.exit(result)
