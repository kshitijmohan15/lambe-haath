"""Shared pytest fixtures for lambe-haath agent + protocol tests."""

import os
import sys
from pathlib import Path

# Make `tests/` importable as a package so test files can `from tests.mock_agent ...`
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
