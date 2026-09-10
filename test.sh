#!/bin/bash
# Runs the suite. Sources/main.swift is excluded: it holds the app's top-level
# entry point, and two files named main.swift cannot be compiled together.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -target arm64-apple-macos14.0 -o build/snapshot \
  $(ls Sources/*.swift | grep -v 'Sources/main.swift') \
  tools/tests.swift tools/measure.swift tools/main.swift
./build/snapshot test
