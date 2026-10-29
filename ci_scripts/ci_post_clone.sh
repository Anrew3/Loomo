#!/bin/sh
# Xcode Cloud: runs after the repository is cloned, before building.
# Checks the file-format schema is a valid JSON Schema, which xcodebuild doesn't cover.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
echo "Xcode: $(xcodebuild -version | head -1)"

python3 -m venv /tmp/loomo-venv
/tmp/loomo-venv/bin/pip install -q jsonschema
/tmp/loomo-venv/bin/python scripts/check-schema.py   # checks the schema itself is valid
