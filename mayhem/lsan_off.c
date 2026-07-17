/*
 * lsan_off.c — the sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 *
 * -fsanitize=address always bundles LeakSanitizer; this hook turns off ONLY the at-exit leak
 * check. ASan's memory-error detection and UBSan stay fully active. Leaks are not the bug class
 * this target fuzzes for, and the harness frees every allocation of a run anyway. build.sh links it
 * into the fuzz target, the standalone reproducer and the test compiler alike, so all three share
 * the same runtime configuration.
 */
int __lsan_is_turned_off(void)
{
  return 1;
}
