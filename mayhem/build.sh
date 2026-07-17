#!/usr/bin/env bash
#
# mayhem/build.sh — build cc500's fuzz harness + standalone reproducer (instrumented)
# and a clean, unsanitized build of the real cc500 compiler for the functional test.
#
# cc500 is a single translation unit (cc500.c): a self-hosting C compiler that reads a
# C program from stdin and writes an x86 ELF to stdout. There is no build system — the
# whole project is `gcc cc500.c -o cc500`.
#
#   (1) FUZZ TARGET  /mayhem/cc500            — the in-process libFuzzer harness
#       (mayhem/fuzz_cc500.c #includes cc500.c) with cc500 compiled under $SANITIZER_FLAGS
#       so the fuzzed compiler code is instrumented.
#   (2) STANDALONE   /mayhem/cc500-standalone — same harness linked against the run-once
#       driver $STANDALONE_FUZZ_MAIN (natural crash, no libFuzzer runtime); a repro artifact.
#   (3) TEST BINARY  /mayhem/cc500-test       — the real cc500 compiler, NORMAL flags, no
#       sanitizer, built exactly as upstream documents; mayhem/test.sh drives the self-hosting
#       oracle with it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty --build-arg is honored (no-sanitizer
# build). cc500 has no external libraries, so the empty-sanitizer build links cleanly.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# cc500.c declares the libc primitives with pre-standard prototypes (e.g. `void *malloc(int)`),
# which clang warns about; the harness redirects them anyway, so silence the noise with -w.

# (1) FUZZ TARGET — project (cc500.c, #included by the harness) built WITH sanitizers + DWARF<4.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -w \
    -I"$SRC" "$SRC/mayhem/fuzz_cc500.c" \
    -o /mayhem/cc500

# (2) STANDALONE reproducer — same harness, run-once driver instead of the fuzzing engine.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -w \
    -I"$SRC" "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/fuzz_cc500.c" \
    -o /mayhem/cc500-standalone

# (3) TEST BINARY — the real cc500 compiler, upstream's normal build, NO sanitizer, so
#     mayhem/test.sh's self-hosting oracle isn't perturbed by instrumentation.
$CC -O2 -w "$SRC/cc500.c" -o /mayhem/cc500-test

echo "build.sh: built /mayhem/cc500 (fuzz), /mayhem/cc500-standalone, /mayhem/cc500-test"
