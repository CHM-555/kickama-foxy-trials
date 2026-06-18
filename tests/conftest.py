"""Shared fixtures for API tests."""
import pytest
import json
from unittest.mock import Mock, patch
from pathlib import Path


@pytest.fixture
def mock_db():
    """Mock database connection."""
    db = Mock()
    db.execute.return_value = []
    db.fetchone.return_value = None
    db.commit.return_value = True
    return db


@pytest.fixture
def mock_redis():
    """Mock Redis connection."""
    redis = Mock()
    redis.get.return_value = None
    redis.set.return_value = True
    redis.delete.return_value = True
    return redis


@pytest.fixture
def sample_trade():
    """Sample trade data."""
    return {
        "id": "trade_001",
        "symbol": "BTC/USD",
        "side": "buy",
        "price": 50000.0,
        "quantity": 0.1,
        "timestamp": "2024-01-15T10:00:00Z",
    }


@pytest.fixture
def sample_order():
    """Sample order data."""
    return {
        "id": "order_001",
        "symbol": "BTC/USD",
        "side": "buy",
        "type": "limit",
        "price": 50000.0,
        "quantity": 0.1,
        "status": "pending",
    }


@pytest.fixture
def auth_headers():
    """Authentication headers for API requests."""
    return {
        "Authorization": "Bearer test-token-123",
        "Content-Type": "application/json",
    }


@pytest.fixture
def large_payload():
    """Large payload for stress testing."""
    return {
        "trades": [
            {
                "id": f"trade_{i:06d}",
                "symbol": "BTC/USD",
                "side": "buy" if i % 2 == 0 else "sell",
                "price": 50000.0 + i,
                "quantity": 0.001 * i,
            }
            for i in range(1000)
        ]
    }


@pytest.fixture
def unicode_payload():
    """Payload with unicode characters."""
    return {
        "symbol": "BTC/USD",
        "note": "Tín dụng ₿ - 比特币 - ₹ Bitcoin",
    }
