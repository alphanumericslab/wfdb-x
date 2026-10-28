# The conformance suite

The conformance suite checks that an implementation of WFDB-x behaves
**exactly** like the original C WFDB Software Package. It is independent of
the language of the implementation: it runs command-line tools and compares
their results with *golden* results produced by the C programs.

## Layout

| Path | Contents |
|---|---|
| `tests/data/` | test records and input files (most written by the C library) |
| `tests/reference/gen_records.c` | program (linked with the C library) that wrote the test records |
| `tests/reference/build_reference.sh` | builds the C reference from `third_party/wfdb-main.zip`, with FLAC support and the deliberate divergences of WFDB-x (`divergences.patch`; set `WFDBX_ORIGINAL=1` for the unmodified package) |
| `tests/reference/divergences.patch` | the deliberate divergences from the C package ([`docs/DIVERGENCES.md`](DIVERGENCES.md)) |
| `tests/data/make_inputs.py` | creates the synthetic WAV, EDF+, AHA and old-header inputs for converter tests |
| `tests/conformance/cases.py` | the test cases |
| `tests/conformance/harness.py` | runs cases and compares results |
| `tests/conformance/golden/<case>/` | golden results: `stdout`, `stderr`, `status`, and `files/` (every file created or modified) |
| `tests/conformance/legacy/` | the legacy suite: the cases of the original package (`cases.py`) and their results from the unmodified C package (`golden/`); `harness.py check --legacy` runs each case with `--legacy` as the tool's first argument, so that legacy mode must reproduce the original exactly |

Each case runs one tool with given arguments (and optionally standard input,
extra input files, and environment variables) in a fresh copy of
`tests/data`, in the same environment wherever it runs:

* `LC_ALL=C` and `TZ=UTC`; `HOME` is an empty directory inside the work
  directory;
* the variables `WFDB`, `WFDBCAL`, `WFDBANNSORT`, `WFDBGVMODE`,
  `WFDBX_INPUT_DIR`, `WFDBX_OUTPUT_DIR` and `WFDBX_NETWORK` are removed
  (the legacy suite sets `WFDB=.`, the original search path);
* the standard input is the case's input, or empty;
* on macOS and Linux, the tool runs in a session of its own, with no
  controlling terminal, as under a CI service. This matters for `xform`
  without `-o`, which asks for the output record's specifications: like the
  C program, it reads the answers from the terminal (`/dev/tty`) when there
  is one, and from the standard input otherwise. The case gives them on the
  standard input, as when the golden results were made;
* a tool that runs longer than the time limit (120 seconds; `--timeout`
  changes it) fails its case, and the other cases still run.

`{cwd}` in an argument stands for the absolute path of that work directory,
which is written back as `{cwd}` in the recorded standard output and error.
Blobs larger than 64 KB are stored as SHA-256 digests (`*.sha256`).

Write errors are tested with `/dev/full`, a device on which every write
fails ("no space left on device"): a case can create output files as links
to it (`full`), and send the standard output there (`stdout_full`). These
cases are skipped where `/dev/full` does not exist (macOS and Windows; it
exists on Linux), and the summary says how many.

The golden directory names are case-sensitive: a capital letter in a case id
is stored as `^` and the letter in lower case (`rdsamp-r_100s_S` is
`rdsamp-r_100s_^s`), so that ids differing only in case get distinct
directories. Copy the golden results with `git` (or another case-preserving
tool): a copy made on a case-insensitive file system can keep an old
directory's spelling, and the harness then reports "missing golden results"
for it, naming the misspelled directory.

FLAC-compressed signal files written by a tool are compared by their decoded
contents (cases list them in `flac_files`), because the compressed bytes of
FLAC files depend on the libFLAC version and on the processor.

## Running

From the root of the repository:

```sh
# Python implementation (python/src of the repository; nothing to install)
python3 tests/conformance/harness.py check --impl python

# C++ implementation (after building it in cpp/build; see cpp/README.md)
python3 tests/conformance/harness.py check --impl cpp

# Kotlin implementation (after building the jar: cd kotlin && ./gradlew fatJar)
python3 tests/conformance/harness.py check --impl kotlin

# the legacy suite (each tool run with --legacy)
python3 tests/conformance/harness.py check --impl python --legacy

# any implementation, given a command template
python3 tests/conformance/harness.py check --impl "/path/to/bin/{tool}"

# selected tools or cases, verbose
python3 tests/conformance/harness.py check --impl python rdsamp rdann -v
```

Cases run in parallel, as many at a time as the computer has processors;
`-j N` sets the number (`-j 1` runs them one by one). `-x` stops at the
first failure. The harness itself needs only Python 3.9 or later (the
Python implementation also needs NumPy).

`--impl` accepts `python`, `cpp`, `rust`, `julia`, `r`, `octave`, `matlab`,
`kotlin`, or a command template containing `{tool}`. The environment
variable `WFDBX_<IMPL>_CMD` overrides the template of a named
implementation; for `cpp` and `rust`, `WFDBX_<IMPL>_BIN` names another
directory of tools; and for `kotlin`, `WFDBX_KOTLIN_JAR` names another jar
of the tools.

## Regenerating golden results

```sh
tests/reference/build_reference.sh build/wfdb-ref
python3 tests/conformance/harness.py golden --cbin build/wfdb-ref/bin
```

The C tools are run by name, with their directory first in `PATH`, so that
messages that include `argv[0]` are reproducible. The golden results in the
repository were produced on x86-64 Linux (glibc), with libFLAC 1.4.3.

## Adding cases

Add calls to `case(tool, args, ...)` in `cases.py`, regenerate the golden
results of the new cases (`harness.py golden --cbin ... CASE_IDS`), and check
them in. A case must not depend on the current date or time, or on behavior
that is undefined in C (see [`KNOWN_C_BEHAVIORS.md`](KNOWN_C_BEHAVIORS.md)).
