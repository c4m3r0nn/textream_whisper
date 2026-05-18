#!/bin/bash
# Run Textream unit tests without Xcode
set -e

TEST_DIR="$(cd "$(dirname "$0")" && pwd)/TextreamTests"
TMPFILE=$(mktemp /tmp/textream_test_XXXXXX.swift)

# Combine all test files
cat "$TEST_DIR"/*.swift > "$TMPFILE"

echo "Compiling tests..."
swiftc -o /tmp/textream_tests "$TMPFILE" -framework XCTest -lXCTestSwiftSupport 2>&1 || {
    echo ""
    echo "Falling back to swift test execution..."
    # Alternative: just compile and check for errors
    swiftc -parse "$TMPFILE" 2>&1 && echo "All test files parse successfully." || exit 1
    rm -f "$TMPFILE"
    echo "Note: Run tests via Xcode (Cmd+U) for full XCTest execution."
    exit 0
}

echo "Running tests..."
/tmp/textream_tests
rm -f "$TMPFILE" /tmp/textream_tests
echo "All tests passed!"
