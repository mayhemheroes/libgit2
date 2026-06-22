#!/usr/bin/env bash
#
# libgit2/mayhem/test.sh — RUN libgit2's own clar test suites (util_tests + libgit2_tests, built by
# mayhem/build.sh in $SRC/build-tests) → CTRF. PATCH-grade oracle: the grader rebuilds (build.sh) then
# runs this. This script only RUNS the pre-built binaries and aggregates counts from clar's JUnit XML.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# clar binaries built by build.sh. Resources are read relative to the source tree, so run from $SRC.
total=0 failed=0 skipped=0
ran_any=0
for bin in build-tests/util_tests build-tests/libgit2_tests; do
  [ -x "$bin" ] || { echo "missing $bin — run mayhem/build.sh first" >&2; exit 2; }
  ran_any=1
  xml="$(mktemp)"
  # clar: -r<file> writes a JUnit summary; non-zero exit on any failure (we read the XML for counts).
  "./$bin" "-r$xml" || true
  # total = number of <testcase>; failed = number of <failure ...>; skipped = number of <skipped ...>.
  # (grep -c always prints a count and exits 1 when zero — `|| true` swallows that exit, no extra line.)
  t=$(grep -c '<testcase' "$xml" 2>/dev/null || true)
  f=$(grep -c '<failure'  "$xml" 2>/dev/null || true)
  s=$(grep -c '<skipped'  "$xml" 2>/dev/null || true)
  : "${t:=0}" "${f:=0}" "${s:=0}"
  total=$(( total + t )); failed=$(( failed + f )); skipped=$(( skipped + s ))
  rm -f "$xml"
done
[ "$ran_any" -eq 1 ] || { echo "no test binaries found in build-tests/ — build.sh bug" >&2; exit 2; }

passed=$(( total - failed - skipped )); [ "$passed" -lt 0 ] && passed=0
emit_ctrf "clar" "$passed" "$failed" "$skipped"
