#!/usr/bin/env bash
#
# mayhem/build.sh — build cc500's fuzz harness, standalone reproducer and the compiler that
# mayhem/test.sh checks, all instrumented.
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
#   (3) TEST BINARY  /mayhem/cc500-test       — the compiler mayhem/test.sh checks. It links the
#       SAME harness+cc500 object as (1), compiled once below with the graded flags, the same
#       libFuzzer runtime and LSan hook, and adds only mayhem/cc500_stdout.c, which writes the
#       ELF cc500 emits to stdout instead of discarding it. test.sh runs it in libFuzzer's
#       run-one-input mode (`cc500-test prog.c > prog`).
#
# Why (3) is not a plain `cc -O2 cc500.c`: a test compiler built outside the harness's macro
# context and flags let a patch disable cc500 in the graded build only. An `#ifdef exit` early
# return, hidden from cc500's own lexer by a backslash-newline comment splice, cleared every PoV
# while test.sh stayed at 5/5 (#1460). With one shared object, any change a patch makes to the
# graded code is also in the compiler test.sh checks. (2) is compiled separately, without
# fuzzer instrumentation, because it must also link with no sanitizer runtime.
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

OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# The harness+project object (cc500.c #included by mayhem/fuzz_cc500.c), compiled ONCE with the
# graded target's flags (sanitizers, DWARF<4, fuzzer instrumentation); (1) and (3) both link it.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -w \
    -I"$SRC" -c "$SRC/mayhem/fuzz_cc500.c" -o "$OBJ/fuzz_cc500.o"
# The sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15), linked into every binary.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -w -c "$SRC/mayhem/lsan_off.c" -o "$OBJ/lsan_off.o"

# (1) FUZZ TARGET.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$OBJ/fuzz_cc500.o" "$OBJ/lsan_off.o" \
    -o /mayhem/cc500

# (2) STANDALONE reproducer — same harness, run-once driver instead of the fuzzing engine.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -w \
    -I"$SRC" "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/fuzz_cc500.c" "$SRC/mayhem/lsan_off.c" \
    -o /mayhem/cc500-standalone

# (3) TEST BINARY — (1)'s objects and runtime, plus the stdout sink for the emitted ELF.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -w -c "$SRC/mayhem/cc500_stdout.c" -o "$OBJ/cc500_stdout.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$OBJ/fuzz_cc500.o" "$OBJ/lsan_off.o" "$OBJ/cc500_stdout.o" \
    -o /mayhem/cc500-test

echo "build.sh: built /mayhem/cc500 (fuzz), /mayhem/cc500-standalone, /mayhem/cc500-test (fuzz objects + stdout sink)"
