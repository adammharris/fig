/* ABI probe (C). Compiled by `zig build abi-check` against the C ABI static
 * library to prove include/fig.h is valid, self-contained C that links. The
 * twin abi_probe.cpp does the same under a C++ compiler (the header guards
 * `extern "C"`). Symbol presence is checked separately by tools/abi-check.zig. */
#include "fig.h"

int main(void) {
    return 0;
}
