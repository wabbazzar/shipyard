#!/bin/bash
# Select a Python with TOML support without requiring a machine-global package.
# macOS /usr/bin/python3 is currently 3.9 and has neither tomllib nor tomli;
# Shipyard already requires Python 3.11+, but native-hook fixtures intentionally
# put the system interpreter first on PATH.

toml_python_bin() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'try:
 import tomllib
except ImportError:
 import tomli' >/dev/null 2>&1 || continue
    command -v "$candidate"
    return 0
  done
  return 1
}
