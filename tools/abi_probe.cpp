// ABI probe (C++). Twin of abi_probe.c, compiled under a C++ compiler by
// `zig build abi-check` to prove include/fig.h is valid C++ as well (the header
// guards `extern "C"`) and links against the C ABI static library.
#include "fig.h"

int main() {
    return 0;
}
