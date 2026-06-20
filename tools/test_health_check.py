import io
import socket
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import health_check


class HealthCheckRetryTests(unittest.TestCase):
    def test_tcp_retries_until_success(self):
        attempts = []
        sleeps = []

        class FakeSocket:
            def close(self):
                pass

        def connect(address, timeout):
            attempts.append((address, timeout))
            if len(attempts) < 3:
                raise ConnectionRefusedError("not ready")
            return FakeSocket()

        with patch.object(socket, "create_connection", side_effect=connect), patch.object(
            health_check.time, "sleep", side_effect=sleeps.append
        ):
            with redirect_stderr(io.StringIO()) as stderr:
                status, detail, _ = health_check.check_tcp_port(
                    "localhost", 5432, timeout=1, retries=3, backoff=0.25, json_output=False
                )

        self.assertEqual(status, "OK")
        self.assertIn("after 3 attempts", detail)
        self.assertEqual(len(attempts), 3)
        self.assertEqual(sleeps, [0.25, 0.5])
        self.assertIn("Retrying TCP check localhost:5432", stderr.getvalue())

    def test_tcp_json_output_suppresses_retry_logs(self):
        sleeps = []

        with patch.object(
            socket, "create_connection", side_effect=ConnectionRefusedError("not ready")
        ), patch.object(health_check.time, "sleep", side_effect=sleeps.append):
            with redirect_stderr(io.StringIO()) as stderr:
                status, detail, _ = health_check.check_tcp_port(
                    "localhost", 5432, timeout=1, retries=2, backoff=0.1, json_output=True
                )

        self.assertEqual(status, "CRITICAL")
        self.assertIn("after 2 attempts", detail)
        self.assertEqual(sleeps, [0.1])
        self.assertEqual(stderr.getvalue(), "")

    def test_http_retries_after_server_error(self):
        attempts = []
        sleeps = []

        class FakeResponse:
            def __init__(self, status, body):
                self.status = status
                self.body = body

            def read(self):
                return self.body

        class FakeConnection:
            def __init__(self, host, port, timeout):
                self.host = host
                self.port = port
                self.timeout = timeout

            def request(self, method, path):
                attempts.append((method, path))

            def getresponse(self):
                if len(attempts) == 1:
                    return FakeResponse(503, b"warming")
                return FakeResponse(200, b"ok")

            def close(self):
                pass

        with patch("http.client.HTTPConnection", FakeConnection), patch.object(
            health_check.time, "sleep", side_effect=sleeps.append
        ):
            with redirect_stderr(io.StringIO()) as stderr:
                status, detail, code = health_check.check_http_service(
                    "localhost", 8080, "/health", timeout=1, retries=2, backoff=0.2
                )

        self.assertEqual(status, "OK")
        self.assertEqual(code, 200)
        self.assertIn("after 2 attempts", detail)
        self.assertEqual(sleeps, [0.2])
        self.assertIn("Retrying HTTP check localhost:8080/health", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
