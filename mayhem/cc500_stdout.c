/*
 * cc500_stdout.c — the output sink that turns the fuzz build into /mayhem/cc500-test.
 *
 * mayhem/fuzz_cc500.c routes every byte cc500 emits through cc500_output_byte(), whose
 * weak default discards it (the fuzz target has no use for the generated ELF). build.sh
 * links THIS strong definition, together with the very same harness object and libFuzzer
 * runtime as the graded target, into /mayhem/cc500-test, so the compiler mayhem/test.sh
 * checks writes its output to stdout exactly as the upstream CLI does
 * (`cc500-test prog.c > prog`, libFuzzer's run-one-input mode). No other code differs.
 */
#include <stdio.h>

void cc500_output_byte(int c)
{
  putchar(c);
}
