#!/usr/bin/env python3
"""
Local mock server to demonstrate retry behavior.
Starts a server that fails on first N requests, then succeeds.
"""
import http.server
import threading
import time
import sys

class RetryMockHandler(http.server.BaseHTTPRequestHandler):
    request_count = 0
    
    def do_GET(self):
        RetryMockHandler.request_count += 1
        if RetryMockHandler.request_count <= 2:
            # Simulate transient failure (5xx)
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Service temporarily unavailable")
        else:
            # Success after retries
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
    
    def log_message(self, format, *args):
        pass  # Suppress logs

def run_mock_server(port=9999):
    server = http.server.HTTPServer(("localhost", port), RetryMockHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server

if __name__ == "__main__":
    print("Starting mock server on port 9999...")
    print("First 2 requests will return 503, then 200")
    print()
    
    server = run_mock_server(9999)
    
    # Run health check with retries
    import subprocess
    result = subprocess.run(
        ["python3", "tools/health_check.py", 
         "--service", "backend",
         "--retries", "3",
         "--backoff-secs", "0.5",
         "--json"],
        capture_output=True, text=True, cwd="/opt/lilim-wallet/zeroeye"
    )
    
    print("Health check output:")
    print(result.stdout)
    if result.stderr:
        print(" stderr:", result.stderr)
    
    print(f"\nTotal requests to mock server: {RetryMockHandler.request_count}")
    print("Expected: 3 (2 failures + 1 success)")
    
    server.shutdown()
