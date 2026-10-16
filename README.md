# WFDB-X
## A cross-language implementation of the WFDB Software Package, in Python, C++, MATLAB/Octave, Rust, Julia and R, with identical behavior.**

The [WFDB Software Package](https://physionet.org/content/wfdb/) (by George
B. Moody and contributors) is the reference C library and set of
command-line tools for reading, writing and converting physiologic signal
and annotation files, such as the PhysioNet databases. wfdb-x is a faithful
reimplementation of its version 10.7.0 in six languages, so that you can use
the same files, the same functions and the same tools without the C library.

Each implementation:

* reads and writes **exactly the same files** as the original C library:
  headers (`.hea`), signal files in every WFDB storage format (8, 16, 61,
  80, 160, 212, 310, 311, 24, 32, and the FLAC formats 508/516/524),
  annotation files (MIT and AHA formats), EDF/EDF+, calibration and info
  files, and multi-segment records;
* provides the **same command-line tools** (33 of them, listed below), with
  the same options;
* provides the C library API, with the C function names (`isigopen`,
  `getvec`, `getann`, `putann`, `strtim`, ...), and a high-level API in the
  idiom of its language;
* is **lightweight**: no dependencies beyond the language's standard library
  (except NumPy for Python). FLAC is supported without libFLAC.

The original C sources are kept, unmodified, in
[`third_party/wfdb-main.zip`](third_party/), and serve as the reference
implementation for testing.

## Why wfdb-x

*A note from Reza Sameni, the author of wfdb-x.*

For more than four decades, the WFDB Software Package has been the common
ground of physiologic signal processing. PhysioNet distributes its
databases in WFDB format, and these databases are among the most widely
used in the field. Thousands of published studies, open-source tools and
machine-learning benchmarks rest on what the WFDB library returns when it
reads a record, and on what it writes.

Today, the same record is read in many languages, through independent
reimplementations that each interpret the format and the library in their
own way. Small differences between them (a sample at the end of a segment,
the rounding of a gain, a default value, the handling of a missing field)
are enough for the same file to give different signals, times or
annotations in Python, MATLAB or R. Such differences are rarely visible,
yet they propagate into every feature, figure and model built on the data,
and they make results hard to compare and to reproduce across groups and
toolchains.

wfdb-x addresses this at the root: one specification, the original C
package, reimplemented in six languages and **tested to be identical**,
byte for byte, against the original and against each other, for reading
and for writing. A record read in Julia gives exactly the samples it gives
in C++; a file written in R is exactly the file the original tools write.
Researchers can then choose a language for their work, and move between
languages, without changing their results.

## One deliberate difference: no built-in signal parameters

The original package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits) and units (millivolts) whenever a
record or the user does not give them. These values describe the equipment
of the first PhysioNet databases, recorded in the 1970s and 1980s, not
modern recordings. A silently assumed value is worse than an error: every
time, duration, resampled signal and physical value derived from it is
wrong, the error propagates to every file and result built on it, and
nothing in the output says that a value was assumed.

wfdb-x therefore has **no built-in signal parameters**. Tools that write
them require them (for example `wrsamp -F FREQ -G GAIN -R BITS -U UNITS`),
and an operation that needs a value missing from a record stops with a
clear error instead of guessing. To reproduce the results of the original
tools, give the values they assumed explicitly (for example
`wrsamp -F 250 -G 200 -R 16 -U mV`, or `ad2m -F 250 -G 400 -R 12 -U mV` for
AHA files). This design decision, its consequences, and the values that
reproduce the original behavior are documented in
[`docs/DIVERGENCES.md`](docs/DIVERGENCES.md).

For compatibility, the original behavior also remains available under the
same names, on explicit request only: `--legacy` as the first argument of a
tool (`wrsamp --legacy -o rec ...`), or the legacy option of the library and
of the high-level functions. Legacy mode reproduces the original package
exactly and is tested against its results, but it is kept for compatibility
only: the values it assumes are exactly the silent defaults described above,
so results produced with it carry the same risks.

## What "identical behavior" means, and how it is checked

For the same input, a wfdb-x tool produces **byte for byte** the same
standard output, standard error (including error messages), exit status and
output files as the original C tool. The library functions return the same
values as their C counterparts. (The exceptions are the deliberate
divergences above; the reference results are produced by the C code with
these changes applied, so they are tested in the same way.)

This is verified by tests whose expected results were all produced by the
original C code, not written by hand:

* **Conformance suite** ([`tests/conformance/`](tests/conformance/),
  described in [`docs/conformance.md`](docs/conformance.md)): 908
  command-line test cases, run by a language-independent harness. Their
  expected results were produced by the C programs, built from
  `third_party/` with FLAC support and with
  [`tests/reference/divergences.patch`](tests/reference/divergences.patch)
  applied ([`tests/reference/build_reference.sh`](tests/reference/build_reference.sh)).
  Every implementation passes all of them.
* **Test records** ([`tests/data/`](tests/data/)): written by the C library
  itself ([`tests/reference/gen_records.c`](tests/reference/gen_records.c)).
  They cover every storage format, multi-frequency and multi-segment (fixed
  and variable layout) records, skewed signals, byte offsets,
  block-structured files, EDF, and annotation files using every feature of
  the annotation format.
* **Library unit tests** in each language directory, with expected values
  printed by the C library
  ([`tests/reference/api_expect.c`](tests/reference/api_expect.c)).

A few behaviors of the C code are undefined (crashes or reads of
uninitialized memory), and many are surprising but well-defined. Both kinds
are documented in [`docs/KNOWN_C_BEHAVIORS.md`](docs/KNOWN_C_BEHAVIORS.md),
with the behavior wfdb-x chose where C's is undefined.

## Implementations

All six implement the complete library and all 33 tools (see
[`docs/INVENTORY.md`](docs/INVENTORY.md) for the details). Each directory
has a README with installation instructions, usage examples and
requirements.

| Language | Directory and README | Install (from a copy of this repository) |
|---|---|---|
| Python | [`python/`](python/README.md) | `pip install wfdb-x` (PyPI), or `pip install ./python` |
| C++ | [`cpp/`](cpp/README.md) | `cmake -S cpp -B cpp/build && cmake --build cpp/build` |
| MATLAB / GNU Octave | [`matlab/`](matlab/README.md) | `addpath('/path/to/wfdb-x/matlab')` (tested with Octave) |
| Rust | [`rust/`](rust/README.md) | `cargo install --path rust` |
| Julia | [`julia/`](julia/README.md) | `using Pkg; Pkg.develop(path="/path/to/wfdb-x/julia")` |
| R | [`r/`](r/README.md) | `R CMD INSTALL r` |

The Python package is distributed on PyPI as `wfdb-x`, with example
notebooks and a sample record (`wfdbx --examples` copies the notebooks). In
code, the packages are named
`wfdbx` (Python, MATLAB, Rust, R, and the C++ namespace) or `WFDBX`
(Julia).

## Command-line tools

Signal and annotation tools from `app/`: `rdsamp`, `wrsamp`, `rdann`, `wrann`,
`sortann`, `ann2rr`, `rr2ann`, `wfdbdesc`, `wfdbtime`, `time2sec`, `sampfreq`,
`signame`, `signum`, `sigamp`, `snip`, `xform`, `wfdbcat`, `wfdbwhich`.

Format converters from `convert/`: `edf2mit`, `mit2edf`, `rdedfann`,
`wav2mit`, `mit2wav`, `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`,
`makeid`, `readid`, `revise`, `parsescp`.

The interactive viewer (WAVE), the plotting tools, and the analysis programs
of `psd/` are outside the scope of this project.

## Documentation

* [`docs/INVENTORY.md`](docs/INVENTORY.md): every tool and library
  function, with its status in each language
* [`docs/conformance.md`](docs/conformance.md): the conformance suite, and
  how to run it for any implementation
* [`docs/KNOWN_C_BEHAVIORS.md`](docs/KNOWN_C_BEHAVIORS.md): reproduced C
  behaviors, and the handling of undefined ones
* [`docs/porting-guide.md`](docs/porting-guide.md): architecture, and the C
  semantics that every implementation must reproduce
* [`docs/AUTHORS.md`](docs/AUTHORS.md): the authors of the C code that each
  part of wfdb-x ports
* The WFDB Applications Guide ([`third_party/wag.pdf`](third_party/))
  describes the tools, and the WFDB Programmer's Guide (in
  `third_party/wfdb-main.zip`) the library API; wfdb-x reproduces both.

## How wfdb-x was developed

The development of wfdb-x was **AI-assisted**. We designed the project and
its requirements (faithfulness to the original C package, identical
behavior across languages, the testing methodology, and the deliberate
design decisions such as removing built-in signal parameters), and directed
and reviewed the work. The code, tests and documentation were originally written with
Claude Code, Anthropic's AI coding assistant, working from the original C
sources and reviewed and tested by human engineers.

AI-written code calls for strong verification, and wfdb-x is built around
it: every implementation is checked against the outputs of the original C
tools and library on the conformance suite (908 cases, plus 838 for legacy
mode), against the other five implementations, and by its own unit tests.
Reports of any difference from the original package are welcome as GitHub
issues.

— [Reza Sameni](https://sameni.info)

## Versions

wfdb-x has its own version numbers, shared by the six implementations and
following [semantic versioning](https://semver.org): 1.0.0 is the first
release. They are independent of the version of the WFDB Software Package
that wfdb-x implements, 10.7.0, which the library still reports as in C
(`wfdbversion()` returns `"10.7.0"`, and `wfdberror()` names it).

## Authors and license

The wfdb-x reimplementations were written by Reza Sameni (Oct 2026), as
ports of the C code of the WFDB Software Package, written by George B.
Moody, Benjamin Moody and the other contributors credited, file by file, in
[`docs/AUTHORS.md`](docs/AUTHORS.md).

wfdb-x uses the same licenses as the original WFDB Software Package:

* the **libraries** are distributed under the GNU Library General Public
  License, version 2 or (at your option) any later version
  ([`LICENSE.LIB`](LICENSE.LIB));
* the **applications** (command-line tools) and the tests are distributed
  under the GNU General Public License, version 2 or (at your option) any
  later version ([`LICENSE`](LICENSE)).

The original WFDB Software Package is Copyright (C) 1983-2022 George B. Moody
and the WFDB contributors.
