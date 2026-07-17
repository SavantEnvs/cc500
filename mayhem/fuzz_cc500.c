/*
 * fuzz_cc500.c — in-process libFuzzer harness for cc500.
 *
 * cc500 is a tiny self-hosting C compiler: it reads a C source program from stdin
 * and writes an x86 ELF binary to stdout, using the libc primitives getchar(),
 * putchar(), malloc() and exit() (which it only DECLARES, relying on libc).
 *
 * The old Mayhem target was the raw stdin-reading binary (`/cc500/cc500`), which is
 * uninstrumented and single-shot. Per the port-repo skill (requirement: a raw
 * file-input CLI target that would yield 0 edges is converted to an in-process
 * libFuzzer harness over the SAME code path), this harness drives cc500's entire
 * compile pipeline (lexer -> recursive-descent parser -> x86 code emitter) in
 * process, once per fuzz input, with the project code compiled under ASan+UBSan.
 *
 * Parity: the code path is identical to the CLI binary — main1() runs be_start(),
 * the lexer, program() and be_finish() exactly as the standalone compiler does. We
 * only redirect the four libc primitives so the input comes from the fuzz buffer
 * instead of stdin, the generated ELF is discarded instead of written to stdout,
 * exit() unwinds back into the harness, and every allocation the run makes is
 * reclaimed at the end of the iteration (cc500's my_realloc never frees, which is
 * fine for a run-once process but would leak under in-process fuzzing — the harness,
 * owning the allocator, bounds each run's allocations to that run).
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

/* --- fuzz input, fed to cc500 in place of stdin --- */
static const uint8_t *g_data;
static size_t g_size;
static size_t g_pos;
static jmp_buf g_exit_env;

/* --- per-iteration allocation tracking, so nothing leaks across runs --- */
static void **g_allocs;
static size_t g_alloc_len;
static size_t g_alloc_cap;

static void track(void *p)
{
  if (!p)
    return;
  if (g_alloc_len == g_alloc_cap) {
    size_t ncap = g_alloc_cap ? g_alloc_cap * 2 : 64;
    void **n = (void **)realloc(g_allocs, ncap * sizeof(void *));
    if (!n)
      return; /* drop tracking on OOM; libc will reclaim at process exit */
    g_allocs = n;
    g_alloc_cap = ncap;
  }
  g_allocs[g_alloc_len++] = p;
}

static void free_all(void)
{
  for (size_t k = 0; k < g_alloc_len; k++)
    free(g_allocs[k]);
  g_alloc_len = 0;
}

/* Replacements for the libc primitives cc500 uses. Defined BEFORE the macros below
 * so cc500_malloc can call the real malloc. */
int cc500_getchar(void)
{
  if (g_pos >= g_size)
    return -1;
  return g_data[g_pos++];
}

int cc500_putchar(int c)
{
  return c; /* discard the emitted ELF byte stream */
}

void cc500_exit(int code)
{
  (void)code;
  longjmp(g_exit_env, 1);
}

void *cc500_malloc(int n)
{
  /* cc500 asks for `int` bytes; a hostile input can drive this negative or huge.
   * Clamp to keep the allocator honest and bounded (parity: cc500 itself never
   * checks the return, so a genuine NULL-deref remains reachable). */
  size_t sz = (n < 0) ? 0 : (size_t)n;
  if (sz > (64u << 20))
    sz = (64u << 20);
  void *p = malloc(sz);
  track(p);
  return p;
}

/* Redirect cc500's references to our in-process implementations, and rename its
 * main() out of the way of libFuzzer's own main(). */
#define main    cc500_entry
#define getchar cc500_getchar
#define putchar cc500_putchar
#define malloc  cc500_malloc
#define exit    cc500_exit

#include "cc500.c"

#undef main
#undef getchar
#undef putchar
#undef malloc
#undef exit

/* Reset every global cc500 relies on so each fuzz iteration is independent. */
static void reset_state(void)
{
  nextc = 0;
  token = NULL;
  token_size = 0;
  i = 0;
  code = NULL;
  code_size = 0;
  codepos = 0;
  code_offset = 0;
  table = NULL;
  table_size = 0;
  table_pos = 0;
  stack_pos = 0;
  number_of_args = 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  g_data = data;
  g_size = size;
  g_pos = 0;

  reset_state();

  /* cc500 never initialises its global `token` buffer: on any input that lexes to ZERO
   * tokens (empty / whitespace-only / comment-only), get_token writes token[0] through the
   * NULL `token` pointer (UBSan: null-pointer arithmetic at cc500.c:114; in practice a NULL
   * store -> SIGSEGV). A single newline triggers it, so under halting sanitizers the target
   * would abort within the first few fuzz iterations — before exercising the lexer/parser/
   * codegen — i.e. effectively unfuzzable. Following the skill's precedent for making such a
   * target fuzzable at the harness level (cf. tldr's NUL-termination fix), the harness supplies
   * the single missing initialisation: a 1-byte `token` buffer. token_size stays 0, so the
   * normal lazy-realloc path is UNCHANGED for real programs (the first lexed character reallocs
   * exactly as upstream does). This suppresses only the degenerate zero-token NULL store; every
   * other cc500 code path — and the memory-safety defects it harbours — remains reachable. */
  token = (char *)cc500_malloc(1);
  if (token)
    token[0] = 0;

  if (setjmp(g_exit_env) == 0)
    main1(); /* be_start(); nextc = getchar(); get_token(); program(); be_finish(); */

  free_all();
  return 0;
}
