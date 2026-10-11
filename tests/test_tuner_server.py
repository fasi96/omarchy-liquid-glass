import importlib.util
import socket
import threading
import time
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tuner', Path(__file__).resolve().parents[1] / 'tuner/tuner.py')
tuner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tuner)


class ServerLimitTests(unittest.TestCase):
    """Connections are bounded before the token check (marketplace review of 1.5.0, #10982)."""

    def setUp(self):
        for target, name, value in [(tuner, 'MAX_CONNS', 2), (tuner, 'READ_DEADLINE', 0.8),
                                    (tuner.H, 'timeout', 0.4)]:
            patcher = patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.srv = tuner.Server(('127.0.0.1', 0), tuner.H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def connect(self):
        s = socket.create_connection(('127.0.0.1', self.port))
        s.settimeout(3)
        self.addCleanup(s.close)
        return s

    def closed_after(self, s):
        """Seconds until the server closes s (reads EOF or a reset)."""
        start = time.monotonic()
        try:
            while s.recv(4096):
                pass
        except ConnectionResetError:
            pass
        return time.monotonic() - start

    def get(self, path='/state'):
        s = self.connect()
        s.sendall(f'GET {path} HTTP/1.0\r\nHost: 127.0.0.1:{tuner.PORT}\r\n\r\n'.encode())
        return s.recv(64).split(b'\r\n')[0]

    def test_extra_connections_are_closed_right_away(self):
        held = [self.connect() for _ in range(2)]
        time.sleep(0.1)
        self.assertLess(self.closed_after(self.connect()), 0.2)
        self.assertGreater(self.closed_after(held[0]), 0.15)   # the first two still had their slots

    def test_idle_connection_times_out_and_frees_its_slot(self):
        held = [self.connect() for _ in range(2)]
        for s in held:
            self.assertLess(self.closed_after(s), 0.7)
        time.sleep(0.1)
        self.assertTrue(self.get().startswith(b'HTTP/1.0 403'))

    def test_trickled_request_is_cut_at_the_deadline(self):
        s = self.connect()
        stop = threading.Event()

        def trickle():
            for b in b'GET /state HTTP/1.0\r\nX-Padding: ' + b'a' * 100:
                if stop.wait(0.1):
                    return
                try:
                    s.send(bytes([b]))
                except OSError:
                    return
        threading.Thread(target=trickle, daemon=True).start()
        self.addCleanup(stop.set)
        self.assertLess(self.closed_after(s), 1.3)

    def test_oversized_body_is_refused(self):
        s = self.connect()
        with patch.object(tuner.H, '_trusted', return_value=True):
            s.sendall(f'POST /apply HTTP/1.0\r\nContent-Length: {tuner.MAX_BODY + 1}\r\n\r\n'.encode())
            self.assertTrue(s.recv(64).startswith(b'HTTP/1.0 413'))


if __name__ == '__main__':
    unittest.main()
