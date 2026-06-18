#!/usr/bin/env python3
"""Tests for diagnostic metadata diff tool."""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from diagnostic_diff import compare_metadata, load_metadata


def test_compare_metadata_added_removed():
    old = {"modules": [{"name": "backend", "status": "passed"}]}
    new = {"modules": [{"name": "backend", "status": "passed"}, {"name": "frontend", "status": "passed"}]}
    diff = compare_metadata(old, new)
    assert diff["added_modules"] == ["frontend"]
    assert diff["removed_modules"] == []
    print("✅ Added/removed modules test passed")


def test_compare_metadata_status_change():
    old = {"modules": [{"name": "backend", "status": "passed"}]}
    new = {"modules": [{"name": "backend", "status": "failed"}]}
    diff = compare_metadata(old, new)
    assert len(diff["changed_status"]) == 1
    assert diff["changed_status"][0]["old"] == "passed"
    assert diff["changed_status"][0]["new"] == "failed"
    print("✅ Status change test passed")


def test_compare_metadata_duration_delta():
    old = {"modules": [{"name": "backend", "duration_ms": 1000}]}
    new = {"modules": [{"name": "backend", "duration_ms": 1500}]}
    diff = compare_metadata(old, new)
    assert len(diff["duration_deltas"]) == 1
    assert diff["duration_deltas"][0]["delta_ms"] == 500
    print("✅ Duration delta test passed")


def test_compare_metadata_no_changes():
    old = {"modules": [{"name": "backend", "status": "passed", "duration_ms": 1000}]}
    new = {"modules": [{"name": "backend", "status": "passed", "duration_ms": 1000}]}
    diff = compare_metadata(old, new)
    assert diff["added_modules"] == []
    assert diff["removed_modules"] == []
    assert diff["changed_status"] == []
    assert diff["duration_deltas"] == []
    print("✅ No changes test passed")


def test_load_metadata_invalid():
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        f.write("not valid json")
        tmpfile = f.name
    try:
        load_metadata(tmpfile)
        assert False, "Should have exited"
    except SystemExit:
        print("✅ Invalid JSON test passed")
    finally:
        os.unlink(tmpfile)


def test_load_metadata_missing():
    try:
        load_metadata("/nonexistent/file.json")
        assert False, "Should have exited"
    except SystemExit:
        print("✅ Missing file test passed")


if __name__ == "__main__":
    test_compare_metadata_added_removed()
    test_compare_metadata_status_change()
    test_compare_metadata_duration_delta()
    test_compare_metadata_no_changes()
    test_load_metadata_invalid()
    test_load_metadata_missing()
    print("\nAll tests passed!")
