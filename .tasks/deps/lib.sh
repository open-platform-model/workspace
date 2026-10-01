# shellcheck shell=bash
# Helpers shared by the .tasks/deps scripts. Sourced, never run.

# next_patch <version>: the version with its last dot-separated number plus one
# (1.0.3 -> 1.0.4; a fixture prerelease 0.1.0-alpha.2 -> 0.1.0-alpha.3).
next_patch() { awk -F. -v OFS=. '{$NF=$NF+1; print}' <<<"$1"; }
