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
#   T1  golden-bytes  : cc500 compiling its OWN source emits a fixed, known ELF (sha256).
#                       Execution-free; catches any codegen regression or a no-op sabotage.
#   T2  self-hosting  : that emitted compiler (stage2) recompiles cc500.c to a byte-identical
#                       stage3 AND stage2 matches the golden hash (the classic bootstrap fixpoint).
#   T3  KAT echo      : a stdin->stdout copy program round-trips its input.
#   T4  KAT counter   : a while/<=/+ loop prints "0123456789".
#   T5  KAT string    : string-literal + char-array indexing prints "Hello".
#
# build.sh already produced /mayhem/cc500-test (the real compiler, normal flags). This script
# only RUNS it; if it's missing that's a build.sh bug — fail loudly.
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

# cc500 compiling its own source is deterministic and compiler-independent (a correct build
# always emits these exact bytes — verified: gcc-built, clang-built and self-hosted all match).
GOLDEN_SHA="6c21bc2b7a996360c7d6db8fc3a50e6b4f99ec16e794b1d53d3b8f06d74d4688"

passed=0; failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS $1"; passed=$((passed+1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; failed=$((failed+1))
  fi
}

# T1/T2 compile the PINNED baseline source mayhem/cc500-baseline.c (an exact copy of upstream's
# cc500.c), never the working tree's: a patch necessarily edits cc500.c, and hashing the compile of
# the patched source would demand source identity, failing every effective fix. Compiling a fixed
# input asks the right question — does the patched compiler still emit the same code?
BASELINE_SRC="$SRC/mayhem/cc500-baseline.c"

# T1 — golden bytes: cc500 compiles the (pinned) cc500 source to a known ELF.
"$CC500" < "$BASELINE_SRC" > "$WORK/stage2" 2>/dev/null || true
chmod +x "$WORK/stage2" 2>/dev/null || true
got_sha="$(sha256sum "$WORK/stage2" 2>/dev/null | cut -d' ' -f1)"
check "golden-bytes-self-compile" "$GOLDEN_SHA" "$got_sha"

# T2 — self-hosting fixpoint: stage2 recompiles the pinned source to a byte-identical stage3.
"$WORK/stage2" < "$BASELINE_SRC" > "$WORK/stage3" 2>/dev/null || true
if cmp -s "$WORK/stage2" "$WORK/stage3" && [ -s "$WORK/stage2" ]; then
  fp="ok"
else
  fp="mismatch"
fi
check "self-hosting-fixpoint" "ok" "$fp"

# --- known-answer tests: compile a small program, run it, assert its output. ---
run_kat() { # run_kat <name> <src-file> <stdin> <expected-stdout>
  local name="$1" src="$2" stdin="$3" expected="$4"
  "$CC500" < "$src" > "$WORK/$name.bin" 2>/dev/null || true
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
emit_ctrf "cc500-selftest" "$passed" "$failed"
