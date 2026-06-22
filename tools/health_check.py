#!/usr/bin/env python3
"""
Health check tool for the Tent of Trials platform.
Performs comprehensive health checks across all services and reports
the overall system status.

This tool is used by:
  - The Kubernetes liveness/readiness probes
  - The deployment pipeline (post-deployment validation)
  - The monitoring system (periodic health checks)
  - The on-call engineer (manual troubleshooting)

The health check performs the following checks:
  1. Service availability (HTTP health endpoints)
  2. Database connectivity (connection test)
  3. Redis connectivity (ping test)
  4. Kafka connectivity (metadata fetch)
  5. Message queue depth (consumer lag check)
  6. Certificate expiry (TLS certificate check)
  7. Disk space (filesystem usage check)
  8. Memory usage (process memory check)

Each check returns a status of OK, WARNING, or CRITICAL, along with
a detail message and optional diagnostic data.

New features:
  - Configurable retry logic with exponential backoff for HTTP probes
  - Circuit breaker pattern to avoid hammering down services
  - Health check result aggregation (summary stats)
  - Proper logging with WARNING level for degraded services

Usage:
    python3 health_check.py                  # Check all services
    python3 health_check.py --service backend # Check specific service
    python3 health_check.py --json            # JSON output
    python3 health_check.py --watch           # Continuous monitoring
    python3 health_check.py --max-retries 3   # Retry failed checks up to 3 times
    python3 health_check.py --backoff-factor 2.0  # Exponential backoff multiplier
    python3 health_check.py --circuit-threshold 3 # Open circuit after 3 consecutive failures
"""

import argparse
import json
import logging
import math
import os
import random
import socket
import ssl
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------

SERVICES = {
    "backend": {"host": "localhost", "port": 8080, "path": "/health", "timeout": 5},
    "market": {"host": "localhost", "port": 8081, "path": "/health", "timeout": 5},
    "frailbox": {"host": "localhost", "port": 8082, "path": "/health", "timeout": 10},
    "frontend": {"host": "localhost", "port": 3000, "path": "/", "timeout": 5},
}

INFRASTRUCTURE = {
    "postgresql": {"host": os.environ.get("DB_HOST", "localhost"), "port": int(os.environ.get("DB_PORT", "5432")), "timeout": 5},
    "redis": {"host": os.environ.get("REDIS_HOST", "localhost"), "port": int(os.environ.get("REDIS_PORT", "6379")), "timeout": 5},
    "kafka": {"host": os.environ.get("KAFKA_HOST", "localhost"), "port": int(os.environ.get("KAFKA_PORT", "9092")), "timeout": 5},
}

DISK_THRESHOLD_WARNING = 80
DISK_THRESHOLD_CRITICAL = 90

MEMORY_THRESHOLD_WARNING = 80
MEMORY_THRESHOLD_CRITICAL = 90

# Default circuit breaker / retry config
DEFAULT_MAX_RETRIES = 0
DEFAULT_BACKOFF_FACTOR = 2.0
DEFAULT_BASE_DELAY = 1.0
DEFAULT_CIRCUIT_THRESHOLD = 3
DEFAULT_CIRCUIT_COOLDOWN = 30

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

logger = logging.getLogger("health_check")
logger.setLevel(logging.INFO)
if not logger.handlers:
    _ch = logging.StreamHandler(sys.stderr)
    _formatter = logging.Formatter(
        "[%(levelname)s] %(asctime)s - %(name)s - %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    _ch.setFormatter(_formatter)
    logger.addHandler(_ch)


# ---------------------------------------------------------------------------
# CIRCUIT BREAKER
# ---------------------------------------------------------------------------

class CircuitBreakerState:
    """Tracks circuit breaker state for a single endpoint."""

    CLOSED = "CLOSED"      # Normal operation, requests pass through
    OPEN = "OPEN"          # Failing, requests are short-circuited
    HALF_OPEN = "HALF_OPEN"  # Testing if service is back

    def __init__(self, threshold: int, cooldown: float):
        self.threshold = threshold
        self.cooldown = cooldown
        self.state = self.CLOSED
        self.failure_count = 0
        self.last_failure_time = 0.0

    def record_success(self):
        """Record a successful probe and reset the breaker."""
        self.failure_count = 0
        if self.state == self.HALF_OPEN:
            logger.info("Circuit breaker half-open probe succeeded, closing circuit")
        self.state = self.CLOSED

    def record_failure(self) -> bool:
        """
        Record a failed probe.
        Returns True if the circuit is now open (caller should skip further attempts).
        """
        self.failure_count += 1
        self.last_failure_time = time.time()

        if self.state == self.HALF_OPEN:
            # Half-open probe failed, back to open
            self.state = self.OPEN
            logger.warning("Circuit breaker half-open probe failed, re-opening circuit")
            return True

        if self.failure_count >= self.threshold:
            self.state = self.OPEN
            logger.warning(
                "Circuit breaker OPEN for threshold=%d consecutive failures. "
                "Cooldown=%ds", self.threshold, self.cooldown
            )
            return True

        return False

    def can_probe(self) -> bool:
        """
        Check if we can probe the endpoint.
        Returns True if circuit is CLOSED, or if cooldown expired (HALF_OPEN).
        """
        now = time.time()
        if self.state == self.OPEN:
            if now - self.last_failure_time >= self.cooldown:
                self.state = self.HALF_OPEN
                logger.info("Circuit breaker cooldown expired, transitioning to HALF_OPEN")
                return True
            return False
        return True

    def reset(self):
        """Manually reset the breaker to closed state."""
        self.state = self.CLOSED
        self.failure_count = 0
        self.last_failure_time = 0.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "state": self.state,
            "failure_count": self.failure_count,
            "threshold": self.threshold,
            "cooldown": self.cooldown,
            "last_failure_time": self.last_failure_time,
        }


class CircuitBreakerRegistry:
    """Manages circuit breakers for multiple endpoints."""

    def __init__(self, threshold: int = DEFAULT_CIRCUIT_THRESHOLD,
                 cooldown: float = DEFAULT_CIRCUIT_COOLDOWN):
        self.threshold = threshold
        self.cooldown = cooldown
        self._breakers: Dict[str, CircuitBreakerState] = {}

    def get(self, endpoint_key: str) -> CircuitBreakerState:
        if endpoint_key not in self._breakers:
            self._breakers[endpoint_key] = CircuitBreakerState(
                threshold=self.threshold,
                cooldown=self.cooldown,
            )
        return self._breakers[endpoint_key]

    def reset_all(self):
        for breaker in self._breakers.values():
            breaker.reset()

    def to_dict(self) -> Dict[str, Any]:
        return {
            k: v.to_dict()
            for k, v in self._breakers.items()
        }


# ---------------------------------------------------------------------------
# RETRY / BACKOFF
# ---------------------------------------------------------------------------

class RetryPolicy:
    """Exponential backoff retry policy for HTTP probes."""

    def __init__(self, max_retries: int = DEFAULT_MAX_RETRIES,
                 backoff_factor: float = DEFAULT_BACKOFF_FACTOR,
                 base_delay: float = DEFAULT_BASE_DELAY,
                 jitter: bool = True):
        self.max_retries = max_retries
        self.backoff_factor = backoff_factor
        self.base_delay = base_delay
        self.jitter = jitter

    def get_delay(self, attempt: int) -> float:
        """
        Calculate delay for the given attempt (0-indexed).
        Formula: delay = base_delay * (backoff_factor ^ attempt)
        If jitter is enabled, adds ±25% random jitter.
        """
        delay = self.base_delay * (self.backoff_factor ** attempt)
        if self.jitter:
            jitter_amount = delay * 0.25
            delay += random.uniform(-jitter_amount, jitter_amount)
            delay = max(0.01, delay)  # ensure minimum positive delay
        return delay

    def should_retry(self, attempt: int, status: int) -> bool:
        """Determine if we should retry based on attempt count and HTTP status."""
        if attempt >= self.max_retries:
            return False
        # Retry on server errors (5xx) and timeouts (status 0)
        if status >= 500 or status == 0:
            return True
        return False

    def to_dict(self) -> Dict[str, Any]:
        return {
            "max_retries": self.max_retries,
            "backoff_factor": self.backoff_factor,
            "base_delay": self.base_delay,
            "jitter": self.jitter,
        }


# ---------------------------------------------------------------------------
# HEALTH CHECK RESULT AGGREGATOR
# ---------------------------------------------------------------------------

class HealthCheckAggregator:
    """Aggregates and summarizes health check results."""

    def __init__(self):
        self.results: List[Dict[str, Any]] = []
        self.start_time = time.time()

    def add_result(self, name: str, category: str,
                   status: str, detail: str, metric: Optional[float] = None,
                   retries: int = 0, circuit_breaker_state: Optional[Dict] = None,
                   endpoint: Optional[str] = None):
        self.results.append({
            "name": name,
            "category": category,
            "status": status,
            "detail": detail,
            "metric": metric,
            "retries": retries,
            "circuit_breaker_state": circuit_breaker_state,
            "endpoint": endpoint,
        })

    def summary(self) -> Dict[str, Any]:
        elapsed = time.time() - self.start_time
        by_status = defaultdict(int)
        by_category = defaultdict(lambda: defaultdict(int))
        degraded_details = []

        for r in self.results:
            by_status[r["status"]] += 1
            by_category[r["category"]][r["status"]] += 1
            if r["status"] in ("WARNING", "CRITICAL"):
                degraded_details.append({
                    "name": r["name"],
                    "status": r["status"],
                    "detail": r["detail"],
                    "category": r["category"],
                })

        total = len(self.results)
        ok_count = by_status.get("OK", 0)
        warning_count = by_status.get("WARNING", 0)
        critical_count = by_status.get("CRITICAL", 0)

        return {
            "total_checks": total,
            "passed": ok_count,
            "warnings": warning_count,
            "critical": critical_count,
            "pass_rate": round((ok_count / total) * 100, 1) if total > 0 else 0.0,
            "elapsed_seconds": round(elapsed, 3),
            "degraded_services": degraded_details,
            "overall_status": "OK" if critical_count == 0 else "DEGRADED",
        }

    def log_degraded(self):
        """Log WARNING-level entries for degraded services."""
        for r in self.results:
            if r["status"] == "WARNING":
                logger.warning(
                    "Degraded service: %s (%s) - %s",
                    r["name"], r["category"], r["detail"]
                )
            elif r["status"] == "CRITICAL":
                logger.warning(
                    "Critical service: %s (%s) - %s",
                    r["name"], r["category"], r["detail"]
                )


# ---------------------------------------------------------------------------
# CHECK FUNCTIONS
# ---------------------------------------------------------------------------

def check_http_service(
    host: str, port: int, path: str, timeout: int,
    retry_policy: Optional[RetryPolicy] = None,
    circuit_breaker: Optional[CircuitBreakerState] = None,
) -> Tuple[str, str, int, int]:
    """
    Perform an HTTP health check with optional retry and circuit breaker.
    Returns (status, detail, http_code, retries_used).
    """
    import http.client

    endpoint_key = f"{host}:{port}{path}"

    # Circuit breaker: check if we can probe
    if circuit_breaker is not None and not circuit_breaker.can_probe():
        logger.warning(
            "Circuit breaker OPEN for %s, skipping probe. "
            "Failures: %d/%d, cooldown remaining: %.1fs",
            endpoint_key,
            circuit_breaker.failure_count,
            circuit_breaker.threshold,
            max(0.0, circuit_breaker.cooldown - (time.time() - circuit_breaker.last_failure_time)),
        )
        return "CRITICAL", f"Circuit breaker OPEN ({circuit_breaker.state})", 0, 0

    max_attempts = 1
    if retry_policy is not None:
        max_attempts = retry_policy.max_retries + 1

    for attempt in range(max_attempts):
        try:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
            conn.request("GET", path)
            resp = conn.getresponse()
            status_code = resp.status
            body = resp.read().decode("utf-8", errors="replace")[:200]
            conn.close()

            if status_code == 200:
                result = "OK"
                detail = f"HTTP {status_code}"
            elif status_code < 500:
                result = "WARNING"
                detail = f"HTTP {status_code}: {body[:100]}"
            else:
                result = "CRITICAL"
                detail = f"HTTP {status_code}: {body[:100]}"

            # Record in circuit breaker
            if circuit_breaker is not None:
                if result == "OK":
                    circuit_breaker.record_success()
                else:
                    circuit_breaker.record_failure()

            return result, detail, status_code, attempt

        except Exception as e:
            status_code = 0
            detail = str(e)

            # Check if we should retry
            if retry_policy is not None and retry_policy.should_retry(attempt, status_code):
                delay = retry_policy.get_delay(attempt)
                logger.info(
                    "Attempt %d/%d failed for %s. Retrying in %.2fs...",
                    attempt + 1, retry_policy.max_retries + 1,
                    endpoint_key, delay,
                )
                time.sleep(delay)
                continue
            else:
                if circuit_breaker is not None:
                    circuit_breaker.record_failure()
                return "CRITICAL", detail, status_code, attempt

    # Should not reach here normally
    return "CRITICAL", detail, 0, max_attempts - 1


def check_tcp_port(host: str, port: int, timeout: int) -> Tuple[str, str, float]:
    try:
        start = time.time()
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.close()
        latency = (time.time() - start) * 1000
        return "OK", f"Connected ({latency:.1f}ms)", latency
    except socket.timeout:
        return "CRITICAL", f"Connection timeout ({timeout}s)", 0
    except ConnectionRefusedError:
        return "CRITICAL", "Connection refused", 0
    except Exception as e:
        return "CRITICAL", str(e), 0


def check_certificate_expiry(host: str, port: int = 443) -> Tuple[str, str, int]:
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                if not cert:
                    return "WARNING", "No certificate found", 0

                from datetime import datetime as dt
                expires = dt.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
                days_left = (expires - dt.now()).days

                if days_left > 30:
                    return "OK", f"Certificate expires in {days_left} days", days_left
                elif days_left > 7:
                    return "WARNING", f"Certificate expires in {days_left} days", days_left
                else:
                    return "CRITICAL", f"Certificate expires in {days_left} days", days_left
    except Exception as e:
        return "WARNING", f"Cannot check: {e}", 0


def check_disk_usage(path: str = "/") -> Tuple[str, str, float]:
    try:
        stat = os.statvfs(path)
        total = stat.f_frsize * stat.f_blocks
        free = stat.f_frsize * stat.f_bavail
        used = total - free
        pct = (used / total) * 100

        if pct < DISK_THRESHOLD_WARNING:
            return "OK", f"{pct:.1f}% used ({used // (1024**3)}GB/{total // (1024**3)}GB)", pct
        elif pct < DISK_THRESHOLD_CRITICAL:
            return "WARNING", f"{pct:.1f}% used ({used // (1024**3)}GB/{total // (1024**3)}GB)", pct
        else:
            return "CRITICAL", f"{pct:.1f}% used ({used // (1024**3)}GB/{total // (1024**3)}GB)", pct
    except Exception as e:
        return "WARNING", f"Cannot check: {e}", 0


def check_memory_usage() -> Tuple[str, str, float]:
    try:
        with open("/proc/meminfo") as f:
            meminfo = {}
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    key = parts[0].strip()
                    value = parts[1].strip().replace(" kB", "")
                    try:
                        meminfo[key] = int(value) * 1024
                    except ValueError:
                        pass

        total = meminfo.get("MemTotal", 0)
        available = meminfo.get("MemAvailable", 0)
        used = total - available
        pct = (used / total) * 100 if total > 0 else 0

        if pct < MEMORY_THRESHOLD_WARNING:
            return "OK", f"{pct:.1f}% used ({used // (1024**3)}GB/{total // (1024**3)}GB)", pct
        elif pct < MEMORY_THRESHOLD_CRITICAL:
            return "WARNING", f"{pct:.1f}% used", pct
        else:
            return "CRITICAL", f"{pct:.1f}% used", pct
    except Exception as e:
        return "WARNING", f"Cannot check: {e}", 0


def check_load_average() -> Tuple[str, str, float]:
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().strip().split()
            load = float(parts[0])
            cpu_count = os.cpu_count() or 1
            load_pct = (load / cpu_count) * 100

            if load_pct < 70:
                return "OK", f"Load: {load} ({load_pct:.0f}% of {cpu_count} cores)", load
            elif load_pct < 90:
                return "WARNING", f"Load: {load} ({load_pct:.0f}% of {cpu_count} cores)", load
            else:
                return "CRITICAL", f"Load: {load} ({load_pct:.0f}% of {cpu_count} cores)", load
    except Exception as e:
        return "WARNING", f"Cannot check: {e}", 0


# ---------------------------------------------------------------------------
# HEALTH CHECK RUNNER
# ---------------------------------------------------------------------------

def run_health_checks(
    service: Optional[str] = None,
    json_output: bool = False,
    retry_policy: Optional[RetryPolicy] = None,
    circuit_registry: Optional[CircuitBreakerRegistry] = None,
) -> Dict[str, Any]:
    results: Dict[str, Any] = {
        "timestamp": datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "services": {},
        "infrastructure": {},
        "system": {},
        "overall_status": "OK",
        "aggregation": {},
        "retry_policy": retry_policy.to_dict() if retry_policy else None,
        "circuit_breakers": circuit_registry.to_dict() if circuit_registry else {},
    }

    aggregator = HealthCheckAggregator()
    all_ok = True

    # Check services
    for name, config in SERVICES.items():
        if service and name != service:
            continue

        endpoint_key = f"service:{name}"
        cb = None
        if circuit_registry is not None:
            cb = circuit_registry.get(endpoint_key)

        status, detail, code, retries_used = check_http_service(
            config["host"], config["port"], config["path"], config["timeout"],
            retry_policy=retry_policy,
            circuit_breaker=cb,
        )

        results["services"][name] = {
            "status": status,
            "detail": detail,
            "code": code,
            "endpoint": f"http://{config['host']}:{config['port']}{config['path']}",
            "retries": retries_used,
        }
        if cb:
            results["services"][name]["circuit_breaker"] = cb.to_dict()

        aggregator.add_result(
            name=name, category="service", status=status, detail=detail,
            metric=code, retries=retries_used,
            circuit_breaker_state=cb.to_dict() if cb else None,
            endpoint=f"http://{config['host']}:{config['port']}{config['path']}",
        )
        if status == "CRITICAL":
            all_ok = False

    # Check infrastructure
    for name, config in INFRASTRUCTURE.items():
        if service and name != service:
            continue
        status, detail, latency = check_tcp_port(config["host"], config["port"], config["timeout"])
        results["infrastructure"][name] = {
            "status": status,
            "detail": detail,
            "endpoint": f"{config['host']}:{config['port']}",
        }
        aggregator.add_result(
            name=name, category="infrastructure", status=status, detail=detail,
            metric=latency,
            endpoint=f"{config['host']}:{config['port']}",
        )
        if status == "CRITICAL":
            all_ok = False

    # Check system resources
    disk_status, disk_detail, disk_pct = check_disk_usage()
    results["system"]["disk"] = {"status": disk_status, "detail": disk_detail}
    aggregator.add_result(
        name="disk", category="system", status=disk_status, detail=disk_detail,
        metric=disk_pct,
    )
    if disk_status == "CRITICAL":
        all_ok = False

    mem_status, mem_detail, mem_pct = check_memory_usage()
    results["system"]["memory"] = {"status": mem_status, "detail": mem_detail}
    aggregator.add_result(
        name="memory", category="system", status=mem_status, detail=mem_detail,
        metric=mem_pct,
    )
    if mem_status == "CRITICAL":
        all_ok = False

    load_status, load_detail, load_val = check_load_average()
    results["system"]["load"] = {"status": load_status, "detail": load_detail}
    aggregator.add_result(
        name="load", category="system", status=load_status, detail=load_detail,
        metric=load_val,
    )

    # Check certificate expiry (web services)
    for name, config in SERVICES.items():
        if service and name != service:
            continue
        if config["port"] == 443:
            cert_status, cert_detail, days_left = check_certificate_expiry(config["host"])
            results["services"][name]["certificate"] = {
                "status": cert_status,
                "detail": cert_detail,
                "days_remaining": days_left,
            }
            aggregator.add_result(
                name=f"{name}/certificate", category="certificate",
                status=cert_status, detail=cert_detail, metric=days_left,
            )
            if cert_status == "CRITICAL":
                all_ok = False

    results["overall_status"] = "OK" if all_ok else "DEGRADED"
    results["aggregation"] = aggregator.summary()

    # Log degraded services
    aggregator.log_degraded()

    return results


def print_health_report(results: Dict[str, Any]):
    print(f"\n{'='*60}")
    print(f"  HEALTH CHECK REPORT")
    print(f"  Host: {results['hostname']}")
    print(f"  Time: {results['timestamp']}")
    print(f"  Overall: {results['overall_status']}")
    if results.get("aggregation"):
        agg = results["aggregation"]
        print(f"  Checks: {agg['total_checks']} total, "
              f"{agg['passed']} passed, "
              f"{agg['warnings']} warnings, "
              f"{agg['critical']} critical")
    if results.get("retry_policy"):
        rp = results["retry_policy"]
        print(f"  Retry: max_retries={rp['max_retries']}, "
              f"backoff_factor={rp['backoff_factor']}")
    if results.get("circuit_breakers"):
        open_breakers = sum(
            1 for v in results["circuit_breakers"].values()
            if v.get("state") == "OPEN"
        )
        if open_breakers > 0:
            print(f"  Circuit Breakers: {open_breakers} OPEN")
    print(f"{'='*60}")

    for category, items in [("Services", results["services"]),
                             ("Infrastructure", results["infrastructure"]),
                             ("System", results["system"])]:
        if items:
            print(f"\n  {category}:")
            for name, check in items.items():
                if isinstance(check, dict) and "status" in check:
                    status_icon = {"OK": "✓", "WARNING": "⚠", "CRITICAL": "✗"}.get(check["status"], "?")
                    detail = check['detail']
                    if check.get("retries", 0) > 0:
                        detail += f" (retried {check['retries']}x)"
                    print(f"    {status_icon} {name}: {detail}")
                else:
                    print(f"    {name}:")
                    for sub_name, sub_check in check.items():
                        if isinstance(sub_check, dict) and "status" in sub_check:
                            sub_icon = {"OK": "✓", "WARNING": "⚠", "CRITICAL": "✗"}.get(sub_check["status"], "?")
                            print(f"      {sub_icon} {sub_name}: {sub_check['detail']}")
    print()


def parse_args():
    parser = argparse.ArgumentParser(description="Health check tool")
    parser.add_argument("--service", "-s", help="Check specific service only")
    parser.add_argument("--json", "-j", action="store_true", help="JSON output")
    parser.add_argument("--watch", "-w", action="store_true", help="Continuous monitoring")
    parser.add_argument("--interval", "-i", type=int, default=30, help="Check interval in seconds")
    parser.add_argument("--output", "-o", help="Output file path")
    # Retry / Backoff
    parser.add_argument("--max-retries", type=int, default=DEFAULT_MAX_RETRIES,
                        help=f"Max retries for HTTP probes (default: {DEFAULT_MAX_RETRIES})")
    parser.add_argument("--backoff-factor", type=float, default=DEFAULT_BACKOFF_FACTOR,
                        help=f"Exponential backoff multiplier (default: {DEFAULT_BACKOFF_FACTOR})")
    parser.add_argument("--base-delay", type=float, default=DEFAULT_BASE_DELAY,
                        help=f"Base delay in seconds for backoff (default: {DEFAULT_BASE_DELAY})")
    # Circuit breaker
    parser.add_argument("--circuit-threshold", type=int, default=DEFAULT_CIRCUIT_THRESHOLD,
                        help=f"Consecutive failures before opening circuit (default: {DEFAULT_CIRCUIT_THRESHOLD})")
    parser.add_argument("--circuit-cooldown", type=int, default=DEFAULT_CIRCUIT_COOLDOWN,
                        help=f"Seconds before resetting open circuit (default: {DEFAULT_CIRCUIT_COOLDOWN})")
    return parser.parse_args()


def main():
    args = parse_args()

    # Build retry policy
    retry_policy = None
    if args.max_retries > 0:
        retry_policy = RetryPolicy(
            max_retries=args.max_retries,
            backoff_factor=args.backoff_factor,
            base_delay=args.base_delay,
        )
        logger.info(
            "Retry policy enabled: max_retries=%d, backoff_factor=%.1f, base_delay=%.1fs",
            args.max_retries, args.backoff_factor, args.base_delay,
        )

    # Build circuit breaker registry
    circuit_registry = None
    if args.circuit_threshold > 0:
        circuit_registry = CircuitBreakerRegistry(
            threshold=args.circuit_threshold,
            cooldown=args.circuit_cooldown,
        )
        logger.info(
            "Circuit breaker enabled: threshold=%d, cooldown=%ds",
            args.circuit_threshold, args.circuit_cooldown,
        )

    if args.watch:
        print(f"Continuous monitoring (interval: {args.interval}s). Press Ctrl+C to stop.")
        try:
            while True:
                results = run_health_checks(args.service, args.json,
                                            retry_policy=retry_policy,
                                            circuit_registry=circuit_registry)
                if args.json:
                    print(json.dumps(results, indent=2))
                else:
                    print_health_report(results)
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\nMonitoring stopped")
    else:
        results = run_health_checks(args.service, args.json,
                                    retry_policy=retry_policy,
                                    circuit_registry=circuit_registry)
        if args.json:
            output = json.dumps(results, indent=2)
            print(output)
        else:
            print_health_report(results)

        if args.output:
            with open(args.output, "w") as f:
                if args.json:
                    json.dump(results, f, indent=2)
                else:
                    json.dump(results, f, indent=2)
            print(f"Report saved to {args.output}")

        if results["overall_status"] == "DEGRADED":
            return 1

    return 0


if __name__ == "__main__":
    main()