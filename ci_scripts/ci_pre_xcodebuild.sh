#!/bin/sh
# Xcode Cloud: before each build, stamp every target with the CI build number
# (CFBundleVersion), keeping MARKETING_VERSION as set in the project.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
fi
