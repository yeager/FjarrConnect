#!/usr/bin/env python3
"""Run an RDP UI test against a loopback peer that promptly resets TCP."""
import os
import socket
import socketserver
import struct
import subprocess
import sys
import threading
from pathlib import Path


def test_environment():
    """Expose XCTest.framework on Xcode versions without its legacy rpath."""
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


class ResetConnection(socketserver.BaseRequestHandler):
    def handle(self):
        # A reset makes FreeRDP's connection failure deterministic, unlike an
        # unbound port that can be intercepted or filtered by the host runner.
        self.request.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.request.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: with-rdp-test-fixture.py command [arguments ...]")
    # The test profile targets this port. A collision fails instead of testing
    # against an unknown service.
    with Server(("127.0.0.1", 45999), ResetConnection) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.call(sys.argv[1:], env=test_environment())
        finally:
            server.shutdown()
            thread.join()
    sys.exit(result)
