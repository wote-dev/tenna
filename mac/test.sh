#!/bin/zsh
# Runs Swift Testing with the standalone Command Line Tools, which install the
# Testing framework outside SwiftPM's default search path. Full Xcode needs no shim.
set -euo pipefail

cd "$(dirname "$0")"

CLT_TESTING_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ -d "$CLT_TESTING_FRAMEWORKS/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT_TESTING_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$CLT_TESTING_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_TESTING_FRAMEWORKS"
fi

exec swift test
