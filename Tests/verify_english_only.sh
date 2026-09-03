#!/usr/bin/env bash
set -euo pipefail

# Regression: the shipped app and repository expose English only. This catches
# accidentally restoring a language catalog, a language picker, or a translated
# README.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -e README.zh-CN.md ]]; then
  echo "Translated README must not be shipped: README.zh-CN.md" >&2
  exit 1
fi

if rg -n --glob '*.swift' --glob '*.md' \
  'README\.zh-CN|AppLanguage|Localization\.shared|Strings\.(zhHans|zhHant|ja|ko|fr|es)|routesToCJK|IntentExamples\.chinese|StrokeInk' \
  NotchFlow README.md CHANGELOG.md; then
  echo "Multilingual support remains in the shipped source." >&2
  exit 1
fi
