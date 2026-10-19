#!/bin/zsh
# Runs the tests (Swift Testing). With only the Command Line Tools installed,
# SwiftPM needs to be told where the Testing framework lives; with Xcode it finds it itself.
set -euo pipefail
cd "$(dirname "$0")"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* ]]; then
    swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
else
    swift test "$@"
fi
