# WFDB-x documentation

The documents shared by the seven implementations of WFDB-x. Each language
has its own README, with installation, usage and its API:
[C++](../cpp/README.md), [Python](../python/README.md),
[MATLAB/Octave](../matlab/README.md), [Rust](../rust/README.md),
[Julia](../julia/README.md), [R](../r/README.md),
[Kotlin](../kotlin/README.md). The [project README](../README.md) is the
starting point.

| Document | Contents |
|---|---|
| [DIVERGENCES.md](DIVERGENCES.md) | The deliberate differences from the original WFDB Software Package, the reasons for each, and legacy mode, which reproduces the original exactly |
| [KNOWN_C_BEHAVIORS.md](KNOWN_C_BEHAVIORS.md) | Surprising but well-defined behaviors of the C code that WFDB-x reproduces, and the behavior WFDB-x chose where the C code's is undefined |
| [INVENTORY.md](INVENTORY.md) | Every command-line tool and library function, with its status in each language |
| [conformance.md](conformance.md) | The conformance suite: how every implementation is checked against the original C programs, and how to run it |
| [BENCHMARKS.md](BENCHMARKS.md) | Speed and memory use of the seven implementations, compared with wfdb-python and the original C tools, and how to read records fastest |
| [porting-guide.md](porting-guide.md) | The architecture of WFDB-x, and the C semantics that every implementation must reproduce |
| [AUTHORS.md](AUTHORS.md) | The authors of the C code that each part of WFDB-x translates |
| [RELEASING.md](RELEASING.md) | How to release the Python package on PyPI: accounts, API tokens, TestPyPI and PyPI |
| [overview.svg](overview.svg), [overview.png](overview.png) | WFDB-x at a glance: the figure shown in the project README |

The tools and the library functions themselves are documented by the
original package's manuals, which WFDB-x follows: the WFDB Applications
Guide ([`third_party/wag.pdf`](../third_party/)) and the WFDB Programmer's
Guide (in [`third_party/wfdb-main.zip`](../third_party/)).
