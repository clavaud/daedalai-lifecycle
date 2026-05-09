#!/usr/bin/env bash
# Tests for hooks/check-prefer-mcp.sh — run from anywhere.
# Each case: pipe a Claude Code PreToolUse JSON envelope into the hook and
# assert stderr matches (or doesn't match) an expected substring.
# Exit code is checked separately — must be 0 for every case.

set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${THIS_DIR}/../check-prefer-mcp.sh"

if [[ ! -x "${HOOK}" ]]; then
  echo "FAIL: hook not executable at ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

# run_case <name> <expect|deny> <expected-substring> <command>
run_case() {
  local name="$1" mode="$2" needle="$3" cmd="$4"
  local payload err exit_code
  payload=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "${cmd}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  err=$(printf '%s' "${payload}" | "${HOOK}" 2>&1 >/dev/null)
  exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    FAIL=$((FAIL+1)); FAILED_NAMES+=("${name} [non-zero exit ${exit_code}]"); return
  fi

  case "${mode}" in
    expect)
      if [[ "${err}" == *"${needle}"* ]]; then
        PASS=$((PASS+1))
      else
        FAIL=$((FAIL+1)); FAILED_NAMES+=("${name} [expected '${needle}', got: '${err}']")
      fi
      ;;
    deny)
      if [[ -z "${err}" ]]; then
        PASS=$((PASS+1))
      else
        FAIL=$((FAIL+1)); FAILED_NAMES+=("${name} [expected silence, got: '${err}']")
      fi
      ;;
  esac
}

# --- Positive cases (each pattern in the table fires) --------------------

run_case "grep-recursive-java" expect "search_graph" \
  "grep -rn '@Component' src/main/java"

run_case "rg-on-code" expect "search_graph" \
  "rg 'class Foo' --type java"

run_case "find-by-code-ext" expect "search_graph" \
  "find . -name '*.java'"

run_case "git-grep-symbol" expect "find_referencing_symbols" \
  "git grep getUserData"

run_case "sed-bulk-multi-files" expect "Morphllm" \
  "sed -i 's/old/new/g' src/Foo.java src/Bar.java"

run_case "mv-rename-source-file" expect "rename_refactoring" \
  "mv src/Foo.java src/Bar.java"

# --- Negative cases (false-positive guards must skip) --------------------

run_case "gradlew-build-skip" deny "" \
  "./gradlew build"

run_case "npm-install-skip" deny "" \
  "npm install"

run_case "grep-on-log-skip" deny "" \
  "grep 'TODO' build/output.log"

run_case "grep-help-skip" deny "" \
  "grep --help"

run_case "find-help-skip" deny "" \
  "find --version"

run_case "grep-non-recursive-no-code-glob" deny "" \
  "grep ERROR /tmp/some.log"

run_case "sed-single-file-skip" deny "" \
  "sed -i 's/old/new/g' Foo.java"

run_case "mv-non-code-skip" deny "" \
  "mv old.txt new.txt"

run_case "find-on-build-dir-skip" deny "" \
  "find build/ -name '*.class'"

run_case "ls-skip" deny "" \
  "ls -la src/"

# --- Report --------------------------------------------------------------

echo
echo "==== check-prefer-mcp.sh tests ===="
echo "PASS: ${PASS}"
echo "FAIL: ${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  printf 'Failed cases:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "${n}"; done
  exit 1
fi
exit 0
