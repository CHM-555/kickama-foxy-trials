#!/usr/bin/env python3
"""
Unit tests for health_check.py retry/backoff and circuit breaker features.
"""

import sys
import os
import time
import unittest
from unittest import mock

# Add parent directory for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tools.health_check import (
    RetryPolicy,
    CircuitBreakerState,
    CircuitBreakerRegistry,
    HealthCheckAggregator,
    check_http_service,
    DEFAULT_BACKOFF_FACTOR,
    DEFAULT_BASE_DELAY,
)


class TestRetryPolicy(unittest.TestCase):
    """Tests for RetryPolicy class."""

    def test_default_creation(self):
        """Test that RetryPolicy creates with default values."""
        rp = RetryPolicy()
        self.assertEqual(rp.max_retries, 0)
        self.assertEqual(rp.backoff_factor, DEFAULT_BACKOFF_FACTOR)
        self.assertEqual(rp.base_delay, DEFAULT_BASE_DELAY)
        self.assertTrue(rp.jitter)

    def test_custom_creation(self):
        """Test that RetryPolicy accepts custom values."""
        rp = RetryPolicy(max_retries=3, backoff_factor=2.0, base_delay=0.5, jitter=False)
        self.assertEqual(rp.max_retries, 3)
        self.assertEqual(rp.backoff_factor, 2.0)
        self.assertEqual(rp.base_delay, 0.5)
        self.assertFalse(rp.jitter)

    def test_exponential_backoff_no_jitter(self):
        """Test exponential backoff calculation without jitter."""
        rp = RetryPolicy(backoff_factor=2.0, base_delay=1.0, jitter=False)
        # delay = 1.0 * (2.0 ^ attempt)
        self.assertEqual(rp.get_delay(0), 1.0)
        self.assertEqual(rp.get_delay(1), 2.0)
        self.assertEqual(rp.get_delay(2), 4.0)
        self.assertEqual(rp.get_delay(3), 8.0)

    def test_exponential_backoff_custom_base(self):
        """Test exponential backoff with custom base delay."""
        rp = RetryPolicy(backoff_factor=3.0, base_delay=0.5, jitter=False)
        # delay = 0.5 * (3.0 ^ attempt)
        self.assertEqual(rp.get_delay(0), 0.5)
        self.assertEqual(rp.get_delay(1), 1.5)
        self.assertEqual(rp.get_delay(2), 4.5)
        self.assertEqual(rp.get_delay(3), 13.5)

    def test_jitter_range(self):
        """Test that jitter is within ±25%."""
        rp = RetryPolicy(backoff_factor=2.0, base_delay=1.0, jitter=True)
        for attempt in range(10):
            delay = rp.get_delay(attempt)
            expected_base = 1.0 * (2.0 ** attempt)
            min_delay = expected_base * 0.75
            max_delay = expected_base * 1.25
            self.assertGreaterEqual(delay, min_delay * 0.5)  # with floor
            self.assertLessEqual(delay, max_delay + 0.1)

    def test_jitter_minimum_positive(self):
        """Test that jitter never produces a negative delay."""
        rp = RetryPolicy(backoff_factor=0.1, base_delay=0.01, jitter=True)
        for attempt in range(5):
            delay = rp.get_delay(attempt)
            self.assertGreater(delay, 0.0)

    def test_should_retry_server_error(self):
        """Test that server errors (5xx) trigger retry."""
        rp = RetryPolicy(max_retries=3)
        self.assertTrue(rp.should_retry(0, 500))
        self.assertTrue(rp.should_retry(1, 502))
        self.assertTrue(rp.should_retry(2, 503))

    def test_should_retry_timeout(self):
        """Test that timeouts (status 0) trigger retry."""
        rp = RetryPolicy(max_retries=3)
        self.assertTrue(rp.should_retry(0, 0))

    def test_should_not_retry_client_error(self):
        """Test that client errors (4xx) do NOT trigger retry."""
        rp = RetryPolicy(max_retries=3)
        self.assertFalse(rp.should_retry(0, 400))
        self.assertFalse(rp.should_retry(0, 404))
        self.assertFalse(rp.should_retry(0, 429))

    def test_should_not_retry_success(self):
        """Test that successful status (2xx) does NOT trigger retry."""
        rp = RetryPolicy(max_retries=3)
        self.assertFalse(rp.should_retry(0, 200))

    def test_should_not_retry_exceeded(self):
        """Test that retrying stops after max_retries is exceeded."""
        rp = RetryPolicy(max_retries=2)
        self.assertFalse(rp.should_retry(2, 500))  # attempt >= max_retries

    def test_to_dict(self):
        """Test that to_dict returns expected keys."""
        rp = RetryPolicy(max_retries=3, backoff_factor=2.5, base_delay=0.5)
        d = rp.to_dict()
        self.assertEqual(d["max_retries"], 3)
        self.assertEqual(d["backoff_factor"], 2.5)
        self.assertEqual(d["base_delay"], 0.5)
        self.assertIn("jitter", d)


class TestCircuitBreakerState(unittest.TestCase):
    """Tests for CircuitBreakerState class."""

    def test_initial_state_closed(self):
        """Test that circuit breaker starts in CLOSED state."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        self.assertEqual(cb.state, cb.CLOSED)
        self.assertEqual(cb.failure_count, 0)
        self.assertTrue(cb.can_probe())

    def test_single_failure_below_threshold(self):
        """Test that single failure doesn't open the circuit."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        circuit_opened = cb.record_failure()
        self.assertFalse(circuit_opened)  # circuit should still be closed
        self.assertEqual(cb.failure_count, 1)
        self.assertTrue(cb.can_probe())

    def test_failures_reach_threshold_opens_circuit(self):
        """Test that reaching threshold consecutive failures opens circuit."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        for i in range(2):
            cb.record_failure()
        # Third failure should open the circuit
        circuit_opened = cb.record_failure()
        self.assertTrue(circuit_opened)
        self.assertEqual(cb.state, cb.OPEN)
        self.assertFalse(cb.can_probe())

    def test_success_resets_failure_count(self):
        """Test that a success resets the failure count."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        cb.record_failure()  # count = 1
        cb.record_failure()  # count = 2
        cb.record_success()  # resets count to 0
        self.assertEqual(cb.failure_count, 0)
        self.assertEqual(cb.state, cb.CLOSED)

    def test_cooldown_transitions_to_half_open(self):
        """Test that after cooldown, open circuit moves to HALF_OPEN."""
        cb = CircuitBreakerState(threshold=3, cooldown=0.1)
        for i in range(3):
            cb.record_failure()
        self.assertEqual(cb.state, cb.OPEN)
        self.assertFalse(cb.can_probe())

        # Sleep past cooldown
        time.sleep(0.15)
        self.assertTrue(cb.can_probe())
        self.assertEqual(cb.state, cb.HALF_OPEN)

    def test_half_open_success_closes_circuit(self):
        """Test that a success in HALF_OPEN state closes the circuit."""
        cb = CircuitBreakerState(threshold=3, cooldown=0.1)
        for i in range(3):
            cb.record_failure()

        # Wait for cooldown
        time.sleep(0.15)
        self.assertTrue(cb.can_probe())  # transitions to HALF_OPEN
        cb.record_success()
        self.assertEqual(cb.state, cb.CLOSED)
        self.assertEqual(cb.failure_count, 0)

    def test_half_open_failure_reopens_circuit(self):
        """Test that a failure in HALF_OPEN state re-opens the circuit."""
        cb = CircuitBreakerState(threshold=3, cooldown=0.1)
        for i in range(3):
            cb.record_failure()

        # Wait for cooldown
        time.sleep(0.15)
        self.assertTrue(cb.can_probe())  # transitions to HALF_OPEN
        circuit_opened = cb.record_failure()  # Half-open probe fails
        self.assertTrue(circuit_opened)
        self.assertEqual(cb.state, cb.OPEN)

    def test_reset_clears_state(self):
        """Test that reset() returns breaker to initial state."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        for i in range(3):
            cb.record_failure()
        self.assertEqual(cb.state, cb.OPEN)
        cb.reset()
        self.assertEqual(cb.state, cb.CLOSED)
        self.assertEqual(cb.failure_count, 0)
        self.assertTrue(cb.can_probe())

    def test_to_dict(self):
        """Test that to_dict returns expected keys."""
        cb = CircuitBreakerState(threshold=3, cooldown=30)
        cb.record_failure()
        d = cb.to_dict()
        self.assertEqual(d["state"], cb.CLOSED)
        self.assertEqual(d["failure_count"], 1)
        self.assertEqual(d["threshold"], 3)
        self.assertEqual(d["cooldown"], 30)


class TestCircuitBreakerRegistry(unittest.TestCase):
    """Tests for CircuitBreakerRegistry class."""

    def test_get_creates_new_breaker(self):
        """Test that get() creates a new breaker if one doesn't exist."""
        registry = CircuitBreakerRegistry(threshold=5, cooldown=60)
        cb = registry.get("service:backend")
        self.assertIsNotNone(cb)
        self.assertEqual(cb.threshold, 5)
        self.assertEqual(cb.cooldown, 60)

    def test_get_returns_same_breaker(self):
        """Test that get() returns the same breaker for same endpoint."""
        registry = CircuitBreakerRegistry(threshold=3, cooldown=30)
        cb1 = registry.get("service:backend")
        cb2 = registry.get("service:backend")
        self.assertIs(cb1, cb2)

    def test_different_endpoints_have_different_breakers(self):
        """Test that different endpoints have independent breakers."""
        registry = CircuitBreakerRegistry(threshold=3, cooldown=30)
        cb1 = registry.get("service:backend")
        cb2 = registry.get("service:market")
        self.assertIsNot(cb1, cb2)
        cb1.record_failure()
        cb1.record_failure()
        self.assertEqual(cb1.failure_count, 2)
        self.assertEqual(cb2.failure_count, 0)

    def test_reset_all(self):
        """Test that reset_all() resets all breakers."""
        registry = CircuitBreakerRegistry(threshold=3, cooldown=30)
        registry.get("service:backend").record_failure()
        registry.get("service:market").record_failure()
        registry.get("service:market").record_failure()
        registry.reset_all()
        for cb in registry._breakers.values():
            self.assertEqual(cb.state, cb.CLOSED)
            self.assertEqual(cb.failure_count, 0)

    def test_to_dict(self):
        """Test that to_dict returns all breaker states."""
        registry = CircuitBreakerRegistry(threshold=3, cooldown=30)
        registry.get("service:backend")
        d = registry.to_dict()
        self.assertIn("service:backend", d)
        self.assertEqual(d["service:backend"]["state"], "CLOSED")


class TestHealthCheckAggregator(unittest.TestCase):
    """Tests for HealthCheckAggregator class."""

    def test_empty_summary(self):
        """Test that empty aggregator returns zeroed summary."""
        agg = HealthCheckAggregator()
        s = agg.summary()
        self.assertEqual(s["total_checks"], 0)
        self.assertEqual(s["passed"], 0)
        self.assertEqual(s["warnings"], 0)
        self.assertEqual(s["critical"], 0)
        self.assertEqual(s["pass_rate"], 0.0)
        self.assertEqual(s["overall_status"], "OK")

    def test_summary_counts_correctly(self):
        """Test that summary counts statuses correctly."""
        agg = HealthCheckAggregator()
        agg.add_result("svc1", "service", "OK", "All good")
        agg.add_result("svc2", "service", "WARNING", "High latency")
        agg.add_result("svc3", "service", "CRITICAL", "Down")
        agg.add_result("db", "infrastructure", "OK", "Connected")

        s = agg.summary()
        self.assertEqual(s["total_checks"], 4)
        self.assertEqual(s["passed"], 2)
        self.assertEqual(s["warnings"], 1)
        self.assertEqual(s["critical"], 1)
        self.assertEqual(s["pass_rate"], 50.0)
        self.assertEqual(s["overall_status"], "DEGRADED")

    def test_summary_overall_ok(self):
        """Test that overall is OK when no critical."""
        agg = HealthCheckAggregator()
        agg.add_result("svc1", "service", "OK", "Fine")
        agg.add_result("svc2", "service", "WARNING", "Degraded")
        s = agg.summary()
        self.assertEqual(s["overall_status"], "OK")

    def test_summary_degraded_details(self):
        """Test that degraded services are listed in summary."""
        agg = HealthCheckAggregator()
        agg.add_result("svc1", "service", "OK", "Fine")
        agg.add_result("svc2", "service", "WARNING", "Slow")
        agg.add_result("svc3", "service", "CRITICAL", "Down")
        agg.add_result("db", "infrastructure", "CRITICAL", "Timeout")

        s = agg.summary()
        self.assertEqual(len(s["degraded_services"]), 3)
        statuses = [d["status"] for d in s["degraded_services"]]
        self.assertIn("WARNING", statuses)
        self.assertIn("CRITICAL", statuses)


class TestCheckHttpServiceRetry(unittest.TestCase):
    """Tests for HTTP service check with retry/backoff and circuit breaker."""

    @mock.patch("http.client.HTTPConnection")
    def test_retry_on_timeout(self, mock_conn):
        """Test that HTTP probe retries on timeout/connection error."""
        # Mock connection that fails twice then succeeds
        mock_instance = mock.MagicMock()

        def side_effects():
            # First call: connection error
            conn1 = mock.MagicMock()
            conn1.request.side_effect = Exception("Connection refused")
            yield conn1
            # Second call: connection error
            conn2 = mock.MagicMock()
            conn2.request.side_effect = Exception("Connection refused")
            yield conn2
            # Third call: success
            conn3 = mock.MagicMock()
            resp3 = mock.MagicMock()
            resp3.status = 200
            resp3.read.return_value = b'{"status":"ok"}'
            conn3.getresponse.return_value = resp3
            yield conn3

        mock_conn.side_effect = side_effects()

        rp = RetryPolicy(max_retries=2, backoff_factor=1.0, base_delay=0.01, jitter=False)
        status, detail, code, retries = check_http_service(
            "localhost", 8080, "/health", 5,
            retry_policy=rp,
        )
        self.assertEqual(status, "OK")
        self.assertEqual(code, 200)
        self.assertGreaterEqual(retries, 1)

    @mock.patch("http.client.HTTPConnection")
    def test_circuit_breaker_skips_probe(self, mock_conn):
        """Test that open circuit breaker skips probe."""
        from tools.health_check import CircuitBreakerState

        cb = CircuitBreakerState(threshold=2, cooldown=30)
        cb.record_failure()
        cb.record_failure()  # circuit opens
        self.assertFalse(cb.can_probe())

        status, detail, code, retries = check_http_service(
            "localhost", 8080, "/health", 5,
            circuit_breaker=cb,
        )
        self.assertEqual(status, "CRITICAL")
        self.assertIn("Circuit breaker OPEN", detail)

    @mock.patch("http.client.HTTPConnection")
    def test_retry_max_exceeded_returns_last_error(self, mock_conn):
        """Test that after exhausting retries, last error is returned."""
        mock_instance = mock.MagicMock()
        mock_instance.request.side_effect = Exception("Connection refused")
        mock_conn.return_value = mock_instance

        rp = RetryPolicy(max_retries=2, backoff_factor=1.0, base_delay=0.01, jitter=False)
        status, detail, code, retries = check_http_service(
            "localhost", 8080, "/health", 5,
            retry_policy=rp,
        )
        self.assertEqual(status, "CRITICAL")
        self.assertIn("Connection refused", detail)
        self.assertEqual(retries, 2)  # used all retries


if __name__ == "__main__":
    unittest.main()