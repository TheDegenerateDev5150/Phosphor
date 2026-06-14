#!/usr/bin/env bash
set -euo pipefail
base=${1:-origin/main}
branch=$(git branch --show-current)
merge_base=$(git merge-base "$base" HEAD)
commits=$(git log --oneline --reverse "$merge_base..HEAD")
files=$(git diff --name-only "$merge_base...HEAD")

printf 'Branch: %s\nBase: %s\n\nCommits:\n%s\n\nChanged files:\n%s\n\n' "$branch" "$base" "${commits:-<none>}" "${files:-<none>}"

scope_count=0
has_messages=0 has_wifi=0 has_startup=0 has_tests=0 has_docs=0
if grep -Eq 'Messages|MessageExporter|MessageViewModel' <<<"$files"; then has_messages=1; fi
if grep -Eq 'WiFi|wifi|DeviceManager|BackupScheduler|PyMobileDevice' <<<"$files"; then has_wifi=1; fi
if grep -Eq 'PhosphorApp|ContentView|BackupManifest|BackupInfo|BackupViewModel' <<<"$files"; then has_startup=1; fi
if grep -Eq 'Scripts/(regression-tests|regression/|benchmark|build)' <<<"$files"; then has_tests=1; fi
if grep -Eq 'README|HANDOFF|CONTRIBUTING|docs/' <<<"$files"; then has_docs=1; fi
for v in $has_messages $has_wifi $has_startup $has_docs; do scope_count=$((scope_count + v)); done

if [ "$scope_count" -gt 1 ]; then
  echo 'WARNING: multiple likely scopes detected.'
  echo 'Create a separate branch/PR unless this is intentionally coordinated.'
  exit 2
fi

if [ "$has_tests" -eq 1 ] && [ "$scope_count" -eq 0 ]; then
  echo 'WARNING: test/build-script-only branch; confirm this is intentional.'
  exit 2
fi

echo 'Scope check passed: branch appears focused.'
