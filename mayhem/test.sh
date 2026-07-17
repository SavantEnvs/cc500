#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for cc500 (a self-hosting C compiler).
#
# cc500 ships NO upstream test suite (it's a single-file demo compiler). This is a
# genuine BEHAVIORAL oracle built from cc500's own defining property — it self-hosts —
# plus known-answer tests that compile small C programs and assert the *behaviour* of
# the generated binaries. Every assertion checks OUTPUT/VALUE, so a patch that neuters
# the compiler to a no-op / exit(0) FAILS here (nothing gets emitted -> every check fails).
#
#   T1  golden-bytes  : the (patched) compiler compiles a FROZEN reference program to a fixed,
#                       known ELF (sha256). Execution-free; catches any codegen regression or a
#                       no-op sabotage.
#   T2  self-hosting  : the (patched) compiler compiles the WORKING-TREE cc500.c to stage2; stage2
#                       recompiles cc500.c to a byte-identical stage3 (the classic bootstrap
#                       fixpoint) AND stage2 compiles the frozen reference program to the golden
#                       hash (the self-hosted compiler generates the same code as the native one).
#   T3  KAT echo      : a stdin->stdout copy program round-trips its input.
#   T4  KAT counter   : a while/<=/+ loop prints "0123456789".
#   T5  KAT string    : string-literal + char-array indexing prints "Hello".
#
# Why T1 compiles a frozen input and not cc500.c: cc500.c is the project's only source file, so
# every patch edits it. The compile of the patched cc500.c is a different ELF even when the fix is
# correct and codegen is untouched (the input program changed, not the compiler's behaviour), so
# hashing it would fail every effective patch. The golden hash is therefore taken over a fixed input.
# The frozen input is mayhem/cc500/testsuite/cc500-self.c, a byte-for-byte copy of upstream
# cc500.c @ 9213e1c (16747 bytes, sha256 REF_SRC_SHA below; it doubles as a Mayhem seed). It must
# stay byte-identical: editing it breaks T1/T2, and test.sh refuses to run if it drifts.
# Self-hosting on the PATCHED source (T2) is kept: cc500 documents itself as self-compiling, so a
# patch the compiler can no longer compile has lost real functionality.
#
# The compiler under test is /mayhem/cc500-test, prebuilt by build.sh: the graded fuzz target's
# own harness+cc500 object, sanitizers and libFuzzer runtime, plus a sink that writes the emitted
# ELF to stdout. So every check below runs the code the grader fuzzes, and a patch that uses the
# build context (macros, flags, harness state) to disable cc500 in the fuzz build only fails here
# (#1460). libFuzzer's run-one-input mode is the CLI: `cc500-test prog.c > prog` (file argument,
# not stdin); its log goes to stderr.
# This script only RUNS it; if it's missing that's a build.sh bug — fail loudly.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

CC500="/mayhem/cc500-test"
if [ ! -x "$CC500" ]; then
  echo "test.sh: $CC500 missing — build.sh must produce it" >&2
  emit_ctrf "cc500-selftest" 0 1
  exit 1
fi

# Frozen oracle input (see header): upstream's cc500.c @ 9213e1c, kept verbatim under mayhem/.
REF_SRC="$SRC/mayhem/cc500/testsuite/cc500-self.c"
REF_SRC_SHA="eeef98be3a67f7bde45d901299ffb540331c1bb9024ecbdf75033e5072a008ac"
if [ "$(sha256sum "$REF_SRC" 2>/dev/null | cut -d' ' -f1)" != "$REF_SRC_SHA" ]; then
  echo "test.sh: frozen oracle input $REF_SRC is missing or modified — it must stay byte-identical to upstream cc500.c @ 9213e1c" >&2
  emit_ctrf "cc500-selftest" 0 1
  exit 1
fi

# Compiling the reference program is deterministic and compiler-independent (a correct build
# always emits these exact bytes — verified: gcc-built, clang-built and self-hosted all match).
GOLDEN_SHA="6c21bc2b7a996360c7d6db8fc3a50e6b4f99ec16e794b1d53d3b8f06d74d4688"

passed=0; failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# compile <src-file> > <elf>: one compile by the test compiler. libFuzzer's log goes to
# $WORK/cc500-test.log and crash artifacts to $WORK. -detect_leaks=0 turns off libFuzzer's
# leak-check re-run. Without it, libFuzzer runs an input a SECOND time whenever the first run
# allocated more than it freed, and the ELF comes out twice. LSan is off in this build anyway
# (mayhem/lsan_off.c), so the re-run checks nothing.
compile() {
  "$CC500" -detect_leaks=0 -artifact_prefix="$WORK/" "$1" 2>>"$WORK/cc500-test.log" || true
}

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS $1"; passed=$((passed+1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; failed=$((failed+1))
  fi
}

# T1 — golden bytes: the patched compiler compiles the frozen reference program to a known ELF.
compile "$REF_SRC" > "$WORK/ref.bin"
got_sha="$(sha256sum "$WORK/ref.bin" 2>/dev/null | cut -d' ' -f1)"
check "golden-bytes-reference-compile" "$GOLDEN_SHA" "$got_sha"

# T2 — self-hosting: the patched compiler compiles the working-tree cc500.c (stage2); stage2
# recompiles it to a byte-identical stage3, and stage2 compiles the reference program to the
# golden hash.
compile "$SRC/cc500.c" > "$WORK/stage2"
chmod +x "$WORK/stage2" 2>/dev/null || true
"$WORK/stage2" < "$SRC/cc500.c" > "$WORK/stage3" 2>/dev/null || true
"$WORK/stage2" < "$REF_SRC" > "$WORK/stage2-ref.bin" 2>/dev/null || true
s2_ref_sha="$(sha256sum "$WORK/stage2-ref.bin" 2>/dev/null | cut -d' ' -f1)"
if [ -s "$WORK/stage2" ] && cmp -s "$WORK/stage2" "$WORK/stage3" && [ "$s2_ref_sha" = "$GOLDEN_SHA" ]; then
  fp="ok"
else
  fp="mismatch"
fi
check "self-hosting-fixpoint" "ok" "$fp"

# --- known-answer tests: compile a small program, run it, assert its output. ---
run_kat() { # run_kat <name> <src-file> <stdin> <expected-stdout>
  local name="$1" src="$2" stdin="$3" expected="$4"
  compile "$src" > "$WORK/$name.bin"
  chmod +x "$WORK/$name.bin" 2>/dev/null || true
  local out
  out="$(printf '%s' "$stdin" | "$WORK/$name.bin" 2>/dev/null)" || true
  check "$name" "$expected" "$out"
}

cat > "$WORK/echo.c" <<'EOF'
void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  int c;
  c = getchar();
  while (c != 0-1) {
    putchar(c);
    c = getchar();
  }
  return 0;
}
EOF
run_kat "kat-echo" "$WORK/echo.c" "Mayhem!" "Mayhem!"

cat > "$WORK/counter.c" <<'EOF'
void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  int c;
  c = '0';
  while (c <= '9') {
    putchar(c);
    c = c + 1;
  }
  putchar(10);
  return 0;
}
EOF
run_kat "kat-counter" "$WORK/counter.c" "" "$(printf '0123456789\n')"

cat > "$WORK/string.c" <<'EOF'
void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  char *s;
  int j;
  s = "Hello";
  j = 0;
  while (s[j] != 0) {
    putchar(s[j]);
    j = j + 1;
  }
  putchar(10);
  return 0;
}
EOF
run_kat "kat-string" "$WORK/string.c" "" "$(printf 'Hello\n')"

echo "cc500 functional oracle: $passed passed, $failed failed"
if [ "$failed" -gt 0 ] && grep -qE 'ERROR: (AddressSanitizer|UndefinedBehaviorSanitizer|libFuzzer)|runtime error:' "$WORK/cc500-test.log" 2>/dev/null; then
  echo "cc500-test reported sanitizer errors while compiling:"
  grep -m3 -E 'ERROR: (AddressSanitizer|UndefinedBehaviorSanitizer|libFuzzer)|runtime error:' "$WORK/cc500-test.log" | sed 's/^/  /'
fi
emit_ctrf "cc500-selftest" "$passed" "$failed"
