#!/bin/bash
cd "$(dirname "$0")"

if command -v go &> /dev/null; then
    echo "Go compiler found. Compiling proxy natively..."
    # Build proxy natively for the current OS (Linux/macOS)
    go build -o proxy proxy.go
else
    echo "Go compiler not found. Falling back to pre-built proxy.exe (Windows only)."
fi
