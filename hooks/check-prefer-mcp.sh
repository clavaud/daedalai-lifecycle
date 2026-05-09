#!/usr/bin/env bash
# DaedalAI Lifecycle Plugin — PreToolUse advisory hook (DAEDA-563)
#
# Purpose: when a Bash command looks like a code-discovery / bulk-edit / rename
# operation that has a better MCP counterpart (codebase-memory-mcp, Serena,
# IntelliJ jetbrains MCP, Morphllm), print a non-blocking advisory to stderr
# so the agent reconsiders before it commits to the wrong tool.
#
# Contract:
#   - stdin: JSON with { "tool_input": { "command": "..." } } (Claude Code hook spec)
#   - stdout: nothing
#   - stderr: advisory message (when a pattern fires); never anything otherwise
#   - exit:   ALWAYS 0 — this hook never blocks
#
# Pattern table (extend with field experience):
#   Bash pattern                              -> Recommended MCP
#   -----------------------------------------  -----------------------------------------
#   grep|rg <regex> targeting code files      -> codebase-memory-mcp.search_graph
#   find . -name '*.<code-ext>'               -> codebase-memory-mcp.search_graph(name_pattern=...)
#   git grep <symbol>                         -> Serena find_referencing_symbols
#   sed -i ... multiple files                 -> Morphllm or IntelliJ replace_text_in_file
#   mv path/Foo.<ext> path/Bar.<ext> (rename) -> IntelliJ rename_refactoring
#
# False-positive guards (skip without nudging):
#   - command runs in build/ node_modules/ target/ .git/ dist/ out/ .gradle/ (path-component aware)
#   - command is part of a build chain: ./gradlew, npm, yarn, pnpm, mvn, make, cargo, go build
#   - --help / --version / -h / -V invocations
#   - target paths are .log / .txt / .md / .json (non-code data) — ONLY when no code-ext token also present

set -u

# --- Read stdin first (need CMD before guards can run) ------------------
INPUT=$(cat || true)
if [[ -z "${INPUT}" ]]; then exit 0; fi

CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD=$(jq -r '.tool_input.command // empty' <<<"${INPUT}" 2>/dev/null || true)
elif command -v python3 >/dev/null 2>&1; then
  CMD=$(python3 -c 'import json,sys;
try:
    d=json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("command",""))
except Exception:
    pass' <<<"${INPUT}" 2>/dev/null || true)
fi

if [[ -z "${CMD}" ]]; then exit 0; fi

# --- Cheap guards FIRST (short-circuit before settings file read) -------

# Skip help/version
case "${CMD}" in
  *"--help"*|*"--version"*|*" -h "*|*" -V "*) exit 0 ;;
esac

# Skip build chain commands at the start of the command line
case "${CMD}" in
  ./gradlew*|gradle\ *|mvn\ *|npm\ *|yarn\ *|pnpm\ *|make\ *|cargo\ *|"go build"*|"go test"*|"go run"*|node\ *|python\ *|python3\ *|pytest*|./mvnw*) exit 0 ;;
esac

# Skip if path-component is a known build/output dir.
# Anchored: must follow start-of-string, whitespace, or '/' so 'build-tools/' won't trip 'build/'.
RE_BUILD_PATH='(^|[[:space:]/])(build|node_modules|target|\.git|dist|out|\.gradle)/'
if [[ "${CMD}" =~ $RE_BUILD_PATH ]]; then
  exit 0
fi

# --- Settings: read from .claude/daedalai-lifecycle.local.md (YAML frontmatter)
# Defaults if absent: enabled=true, severity=advisory.
SETTINGS_FILE=".claude/daedalai-lifecycle.local.md"
NUDGE_ENABLED="true"
NUDGE_SEVERITY="advisory"
if [[ -f "${SETTINGS_FILE}" ]]; then
  # Best-effort YAML frontmatter scrape — no full YAML parser dependency.
  in_fm=0
  while IFS= read -r line; do
    line="${line%$'\r'}"  # strip CRLF if present
    if [[ "${line}" == "---" ]]; then
      if [[ ${in_fm} -eq 0 ]]; then in_fm=1; else break; fi
      continue
    fi
    if [[ ${in_fm} -eq 1 ]]; then
      case "${line}" in
        mcp_nudge.enabled:*)  NUDGE_ENABLED=$(printf '%s' "${line#mcp_nudge.enabled:}"  | tr -d "[:space:]\"'") ;;
        mcp_nudge.severity:*) NUDGE_SEVERITY=$(printf '%s' "${line#mcp_nudge.severity:}" | tr -d "[:space:]\"'") ;;
      esac
    fi
  done < "${SETTINGS_FILE}"
fi

# Lowercase for case-insensitive comparison (bash 3.2 compatible — no ${var,,})
NUDGE_ENABLED_LC=$(printf '%s' "${NUDGE_ENABLED}" | tr '[:upper:]' '[:lower:]')
NUDGE_SEVERITY_LC=$(printf '%s' "${NUDGE_SEVERITY}" | tr '[:upper:]' '[:lower:]')

if [[ "${NUDGE_ENABLED_LC}" == "false" || "${NUDGE_SEVERITY_LC}" == "silent" ]]; then
  exit 0
fi

# Helper: emit a nudge to stderr. Args: $1=server, $2=body.
emit_nudge() {
  local server="$1"; shift
  local body="$*"
  >&2 printf '\n💡 MCP-tool nudge — consider %s instead of native Bash:\n%s\n' "${server}" "${body}"
  if [[ "${NUDGE_SEVERITY_LC}" == "verbose" ]]; then
    >&2 printf '   (silence per-project: add `mcp_nudge.enabled: false` to %s frontmatter)\n' "${SETTINGS_FILE}"
  fi
}

# Detect whether an MCP server is configured in ~/.claude.json or .mcp.json.
# Best-effort: returns 0 if any token in $1 (space-separated) appears as an
# mcpServers key. Returns 1 if none found and the file(s) are readable.
mcp_installed() {
  local needles="$1"
  python3 - "$needles" <<'PY' 2>/dev/null
import json, os, sys, re
needles = sys.argv[1].split()
def keys(path):
    try:
        with open(path) as f: d = json.load(f)
    except Exception:
        return set()
    out = set((d.get('mcpServers') or {}).keys())
    for p, v in (d.get('projects') or {}).items():
        out.update(((v or {}).get('mcpServers') or {}).keys())
    return out
all_keys = set()
for p in (os.path.expanduser('~/.claude.json'), '.mcp.json', '.claude/mcp.json'):
    all_keys.update(keys(p))
# normalize: case-insensitive substring match
low = {k.lower() for k in all_keys}
hit = any(any(n.lower() in k for k in low) for n in needles)
sys.exit(0 if hit else 1)
PY
}

install_hint() {
  local server="$1"
  case "${server}" in
    codebase-memory-mcp) printf '   Install: claude mcp add codebase-memory-mcp <transport-args>\n   Docs: https://github.com/codebase-memory-mcp\n' ;;
    serena)              printf '   Install: claude mcp add serena <transport-args>\n   Docs: https://github.com/serena-mcp\n' ;;
    jetbrains)           printf '   Install: claude mcp add jetbrains <transport-args> (requires JetBrains IDE plugin)\n' ;;
    morphllm-fast-apply) printf '   Install: claude mcp add morphllm-fast-apply <transport-args>\n' ;;
  esac
}

# --- Patterns ------------------------------------------------------------

CODE_EXT_TOKEN_RE='[A-Za-z0-9_./-]+\.(java|kt|kts|ts|tsx|js|jsx|py|go|rb|rs|c|cc|cpp|h|hpp|cs|scala|swift|m|mm|php|dart|vue|svelte)'

# Token-boundary regexes for cheap pattern detection (bash =~, no fork).
# Note: bash regex (POSIX ERE) does NOT support \b; use explicit boundary classes instead.
# Use ([[:space:]]|$) for trailing boundary and (^|[[:space:]]) for leading where needed.
RE_GREP_RECURSIVE='^[[:space:]]*(rg([[:space:]]|$)|grep[[:space:]]+-[A-Za-z]*r[A-Za-z]*([[:space:]]|$)|grep[[:space:]]+--include)'
# Data-extension targets: only skip when present AND no code-extension token also in command.
RE_DATA_EXT='\.(log|txt|md|csv|json|yaml|yml|xml)([[:space:]]|$)'
RE_CODE_EXT='\.(java|kt|kts|ts|tsx|js|jsx|py|go|rs|rb|c|cc|cpp|h|hpp|cs|scala|swift|m|mm|php|dart|vue|svelte|sh|gradle)([[:space:]]|$)'
RE_FIND_HEAD='^[[:space:]]*find([[:space:]]|$)'
RE_FIND_NAME_CODE="-name[[:space:]]+['\"]?\\*\\.(java|kt|kts|ts|tsx|js|jsx|py|go|rb|rs|cpp|cs|swift|php|dart)['\"]?"
RE_GIT_GREP='^[[:space:]]*git[[:space:]]+grep([[:space:]]|$)'
RE_SED_INPLACE='^[[:space:]]*sed[[:space:]]+(-i([[:space:]]|$)|-[a-zA-Z]*i[a-zA-Z]*([[:space:]]|$))'
RE_MV_HEAD='^[[:space:]]*mv[[:space:]]+'

nudged=0

# 1) grep|rg targeting code (recursive grep, rg, or grep --include with code ext).
#    Skip ONLY if data-extension token present AND no code-extension token also present.
if [[ ${nudged} -eq 0 ]]; then
  if [[ "${CMD}" =~ $RE_GREP_RECURSIVE ]]; then
    if [[ "${CMD}" =~ $RE_DATA_EXT ]] && ! [[ "${CMD}" =~ $RE_CODE_EXT ]]; then
      :  # data-only target — skip
    else
      if mcp_installed "codebase-memory-mcp"; then
        emit_nudge "codebase-memory-mcp.search_graph" \
"   search_graph(project=\"<auto-detected>\", query=\"<your search>\")
   — graph-aware, BM25-ranked, structurally typed.
   For symbol references specifically: prefer Serena find_referencing_symbols."
      else
        emit_nudge "codebase-memory-mcp.search_graph (NOT INSTALLED)" \
"   This grep would benefit from a graph-aware structural search.
$(install_hint codebase-memory-mcp)
   After install, reindex once with index_repository(project=\"...\")."
      fi
      nudged=1
    fi
  fi
fi

# 2) find . -name '*.<code-ext>'
if [[ ${nudged} -eq 0 ]]; then
  if [[ "${CMD}" =~ $RE_FIND_HEAD ]] && [[ "${CMD}" =~ $RE_FIND_NAME_CODE ]]; then
    if mcp_installed "codebase-memory-mcp"; then
      emit_nudge "codebase-memory-mcp.search_graph" \
"   search_graph(project=\"<auto-detected>\", name_pattern=\"<glob>\")
   — file lookup that also returns symbol/type metadata, not just paths."
    else
      emit_nudge "codebase-memory-mcp.search_graph (NOT INSTALLED)" \
"   For listing code files by name, an indexed graph search is faster.
$(install_hint codebase-memory-mcp)"
    fi
    nudged=1
  fi
fi

# 3) git grep <symbol>
if [[ ${nudged} -eq 0 ]]; then
  if [[ "${CMD}" =~ $RE_GIT_GREP ]]; then
    if mcp_installed "serena jetbrains"; then
      emit_nudge "Serena find_referencing_symbols (or jetbrains.search_symbol)" \
"   Symbol-aware: returns true references, not regex matches.
   Skips comments, strings, partial-name collisions."
    else
      emit_nudge "Serena find_referencing_symbols (NOT INSTALLED)" \
"   For symbol references prefer LSP-based search over regex.
$(install_hint serena)"
    fi
    nudged=1
  fi
fi

# 4) sed -i across files (heuristic: -i flag and >=2 path tokens with code ext)
if [[ ${nudged} -eq 0 ]]; then
  if [[ "${CMD}" =~ $RE_SED_INPLACE ]]; then
    # Count code-file path tokens in the command. >=2 → bulk edit territory.
    count=$(printf '%s' "${CMD}" | grep -oE "${CODE_EXT_TOKEN_RE}" | wc -l | tr -d ' ')
    if [[ "${count}" -ge 2 ]]; then
      if mcp_installed "morphllm-fast-apply jetbrains"; then
        emit_nudge "Morphllm fast-apply (or jetbrains.replace_text_in_file)" \
"   Bulk edit across files — Morphllm preserves intent + handles ambiguity better than regex.
   IntelliJ alternative is project-aware (won't break imports/types)."
      else
        emit_nudge "Morphllm or IntelliJ MCP (NOT INSTALLED)" \
"   Bulk sed across code files is fragile (no syntax awareness).
$(install_hint morphllm-fast-apply)
$(install_hint jetbrains)"
      fi
      nudged=1
    fi
  fi
fi

# 5) mv path/Foo.<ext> path/Bar.<ext> — rename of source file
if [[ ${nudged} -eq 0 ]]; then
  if [[ "${CMD}" =~ $RE_MV_HEAD ]]; then
    # Two code-file tokens with same extension is the strong signal.
    files=$(printf '%s' "${CMD}" | grep -oE "${CODE_EXT_TOKEN_RE}" | head -2)
    fcount=$(printf '%s\n' "${files}" | grep -c . || true)
    if [[ "${fcount}" -eq 2 ]]; then
      if mcp_installed "jetbrains"; then
        emit_nudge "jetbrains.rename_refactoring" \
"   File rename + import/usage updates in one refactor.
   A bare 'mv' leaves all references dangling."
      else
        emit_nudge "jetbrains.rename_refactoring (NOT INSTALLED)" \
"   Renaming a source file with 'mv' breaks every reference to it.
$(install_hint jetbrains)"
      fi
      nudged=1
    fi
  fi
fi

exit 0
