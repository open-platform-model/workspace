#!/usr/bin/env bash
# Print the newest release tag of a workspace repo matching a prefix, read from
# GitHub (no registry tooling, no auth): `latest-tag.sh <repo> <prefix>`.
# Prereleases count (the v2 line ships alphas); `-0.dev.` branch builds do not.
# The version is echoed WITHOUT the prefix and without a leading `v`.
set -euo pipefail
repo="$1"; prefix="$2"
git ls-remote --tags --refs "https://github.com/open-platform-model/${repo}" "refs/tags/${prefix}*" \
  | awk -F'refs/tags/' '{print $2}' \
  | grep -v -- '-0\.dev\.' \
  | sed "s/^${prefix}//; s/^v//" \
  | sed "s/-/~/" | sort -V | tail -1 | sed "s/~/-/"
