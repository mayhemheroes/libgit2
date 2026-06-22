#!/usr/bin/env bash
#
# libgit2/mayhem/build.sh — build libgit2's native fuzz harnesses (fuzzers/*_fuzzer.c) twice
# (libFuzzer + standalone reproducer), instrumenting the PROJECT with $SANITIZER_FLAGS, plus
# libgit2's own clar test suite with the project's NORMAL flags (so mayhem/test.sh only RUNS it).
#
# Runs as `mayhem` in /mayhem inside the commit image. The base image exports the build contract:
#   CC/CXX, LIB_FUZZING_ENGINE (-fsanitize=fuzzer), SANITIZER_FLAGS (ASan+UBSan, halting),
#   STANDALONE_FUZZ_MAIN (LLVM run-once single-input driver), SRC (=/mayhem).
set -euo pipefail

# clang rejects an empty SOURCE_DATE_EPOCH — unset it rather than pass ''.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (overridable), sane defaults. SANITIZER_FLAGS uses `=` (not `:=`)
# so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# Common cmake options for an offline static build (no HTTPS/SSH/NTLM/Negotiate backends, bundled
# zlib + builtin regex) — keeps the fuzz targets self-contained and the test suite offline-friendly.
COMMON_CMAKE_OPTS=(
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_CLI=OFF
  -DUSE_HTTPS=OFF
  -DUSE_SSH=OFF
  -DUSE_AUTH_NTLM=OFF
  -DUSE_AUTH_NEGOTIATE=OFF
  -DUSE_BUNDLED_ZLIB=ON
  -DREGEX_BACKEND=builtin
  -DCMAKE_C_COMPILER="$CC"
)

# ── 1) PROJECT + libFuzzer fuzzers, instrumented with $SANITIZER_FLAGS ───────────────
# Must include -fsanitize=fuzzer-no-link in CMAKE_C_FLAGS so that libgit2's own objects
# (src/libgit2/, src/util/, deps/) are compiled with coverage instrumentation
# (__sanitizer_cov_trace_pc_guard calls injected into every edge).  Without it, the
# library objects have no sancov instrumentation → Mayhem sees 0 edges on every target.
#
# Note: fuzzers/CMakeLists.txt calls add_c_flag(-fsanitize=fuzzer-no-link) only in the
# fuzzers/ subdirectory scope, so without this override the library is UNinstrumented
# even though -DBUILD_FUZZERS=ON.  The final link adds -fsanitize=fuzzer (full libFuzzer
# runtime) per target, which is correct; the NO-link variant here just enables coverage.
cmake -S "$SRC" -B "$SRC/build" "${COMMON_CMAKE_OPTS[@]}" \
      -DBUILD_TESTS=OFF -DBUILD_FUZZERS=ON -DUSE_STANDALONE_FUZZERS=OFF \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake --build "$SRC/build" -j"$MAYHEM_JOBS"

# Copy each libFuzzer binary to /mayhem/<name>_fuzzer (the Mayhemfile targets).
for fz in "$SRC"/build/fuzzers/*_fuzzer; do
  [ -x "$fz" ] || continue
  cp -f "$fz" "/mayhem/$(basename "$fz")"
done

# ── 2) Standalone (non-fuzzer) reproducer per harness, via $STANDALONE_FUZZ_MAIN ─────
# Single-input run-once driver linked against the sanitized libgit2.a — same instrumentation, no
# libFuzzer runtime. The harnesses are C, so the driver links directly (no C++ mangling concern).
INC=(
  -I "$SRC/src/libgit2" -I "$SRC/src/util" -I "$SRC/include"
  -I "$SRC/build/gen_headers"
  -I "$SRC/deps/llhttp" -I "$SRC/deps/pcre2" -I "$SRC/deps/xdiff"
  -I "$SRC/deps/zlib" -I "$SRC/deps/reftable"
)
# $SANITIZER_FLAGS may be empty (sanitizer off-switch) — leave it unquoted so it expands to nothing.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -std=c90 -D_GNU_SOURCE -c "$SRC/fuzzers/fuzzer_utils.c" -o /tmp/fuzzer_utils.o
for src in "$SRC"/fuzzers/*_fuzzer.c; do
  name="$(basename "${src%.c}")"           # e.g. commit_graph_fuzzer
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -std=c90 -D_GNU_SOURCE -c "$src" -o "/tmp/$name.o"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "/tmp/$name.o" /tmp/fuzzer_utils.o /tmp/standalone_main.o \
      "$SRC/build/libgit2.a" -lrt -o "/mayhem/${name}-standalone"
done

# ── 3) libgit2's own clar test suite, with the project's NORMAL flags ────────────────
# Independent build dir + clean flags (env -u CFLAGS) so test.sh stays an honest functional oracle
# and won't false-fail on benign UB. test.sh only RUNS the binaries this produces.
env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
  cmake -S "$SRC" -B "$SRC/build-tests" "${COMMON_CMAKE_OPTS[@]}" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=ON -DBUILD_FUZZERS=OFF
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target util_tests --target libgit2_tests
