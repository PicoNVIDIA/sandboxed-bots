#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Pre-submission gate for a PUBLIC NVIDIA repo. Runs on the local checkout.
# Anything flagged here must be fixed before an MR.
cd "${1:-/tmp/sb-push/nemoclaw-hermes-swarm}" || exit 1
fail=0
hit() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; fail=$((fail+1)); }
ok()  { printf "  \033[32mok\033[0m   %s\n" "$*"; }

echo "SECRETS AND CREDENTIALS"
pat='lsv2_pt_[A-Za-z0-9]|tvly-[A-Za-z0-9]{8}|gho_[A-Za-z0-9]{8}|github_pat_[A-Za-z0-9]|sk-[A-Za-z0-9]{16}|AKIA[0-9A-Z]{12}|-----BEGIN [A-Z ]*PRIVATE KEY'
m=$(grep -rInE "$pat" . --exclude-dir=.git 2>/dev/null | grep -viE '\.example|placeholder|YOUR_|<your|e\.g\.|lsv2_pt_…')
[ -n "$m" ] && { hit "credential-shaped strings found:"; echo "$m" | head -5 | sed 's/^/       /'; } || ok "no credential patterns"

echo "LONG HEX (possible keys)"
m=$(grep -rInE '\b[0-9a-f]{32,}\b' . --exclude-dir=.git 2>/dev/null \
    | grep -viE 'sha256|digest|traceId|spanId|0000000000000000|commit|checksum|uuid')
[ -n "$m" ] && { hit "long hex strings:"; echo "$m" | head -4 | sed 's/^/       /'; } || ok "no stray long hex"

echo "INTERNAL IDENTIFIERS"
# --exclude the checker itself: its own pattern list would match every time
for p in '10\.187\.' 'nvaie-tme' 'poc-nvaie' '/home/nvidia' 'pmoorhead' 'poc-sandbox' 'swarm-cleanroom'; do
  m=$(grep -rIn "$p" . --exclude-dir=.git --exclude='presubmit-check.sh' 2>/dev/null | head -3)
  [ -n "$m" ] && { hit "internal reference '$p':"; echo "$m" | sed 's/^/       /'; } || ok "no '$p'"
done

echo "AGENT NAMES FROM OUR DEPLOYMENT (should be generic in a public example)"
m=$(grep -rInE '\b(bot-)?(alpha|beta|gamma|delta)\b' . --exclude-dir=.git 2>/dev/null \
    | grep -vE 'docs/|README|\.md:|presubmit-check' | head -5)
[ -n "$m" ] && printf "  \033[33mnote\033[0m specific agent names in non-doc files:\n%s\n" "$(echo "$m" | sed 's/^/       /')" \
             || ok "no hardcoded agent names outside docs"

echo "FILES THAT MUST NOT SHIP"
for d in secrets data backup logs state .env; do
  [ -e "$d" ] && hit "$d present in repo" || ok "no $d"
done

echo "REQUIRED FILES"
for f in README.md LICENSE .env.example .gitignore; do
  [ -f "$f" ] && ok "$f" || hit "$f MISSING"
done

echo "SPDX HEADERS"
n=0; miss=0
for f in scripts/*.sh policies/*.yaml Dockerfile.* observability/*.yaml observability/*.example; do
  [ -f "$f" ] || continue
  n=$((n+1))
  head -5 "$f" | grep -q "SPDX-License-Identifier" || { miss=$((miss+1)); printf "       missing: %s\n" "$f"; }
done
[ "$miss" -eq 0 ] && ok "$n files all carry SPDX" || hit "$miss of $n files missing SPDX"

echo "SYNTAX"
for f in scripts/*.sh; do bash -n "$f" 2>/dev/null || hit "bash syntax: $f"; done
ok "shell scripts parse"
PY=$(command -v python3)
"$PY" - <<'PY' 2>/dev/null || echo "  (yaml module unavailable locally; validate on the box)"
import glob, sys
try: import yaml
except ImportError: sys.exit(1)
bad=[]
for f in glob.glob("policies/*.yaml")+glob.glob("observability/*.yaml"):
    try: yaml.safe_load(open(f))
    except Exception as e: bad.append(f"{f}: {e}")
print("  ok   yaml parses" if not bad else "  FAIL yaml: "+"; ".join(bad))
PY

echo "EXECUTABLE BITS (git mode, not filesystem)"
ne=$(git ls-files -s scripts/ 2>/dev/null | awk '$1!="100755"{print $4}')
[ -z "$ne" ] && ok "all scripts 100755 in git" || { hit "not executable in git:"; echo "$ne" | sed 's/^/       /'; }

echo
[ "$fail" -eq 0 ] && printf "\033[32mPASS\033[0m — ready to submit\n" || printf "\033[31m%d problem(s)\033[0m — fix before submitting\n" "$fail"
