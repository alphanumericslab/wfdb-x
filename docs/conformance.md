# The conformance suite

The conformance suite checks that an implementation of wfdb-x behaves
**exactly** like the original C WFDB Software Package. It is independent of
the language of the implementation: it runs command-line tools and compares
their results with *golden* results produced by the C programs.

## Layout

| Path | Contents |
|---|---|
| `tests/data/` | test records and input files (most written by the C library) |
| `tests/reference/gen_records.c` | program (linked with the C library) that wrote the test records |
| `tests/reference/build_reference.sh` | builds the C reference from `third_party/wfdb-main.zip`, with FLAC support and the deliberate divergences of wfdb-x (`divergences.patch`; set `WFDBX_ORIGINAL=1` for the unmodified package) |
| `tests/reference/divergences.patch` | the deliberate divergences from the C package ([`docs/DIVERGENCES.md`](DIVERGENCES.md)) |
| `tests/data/make_inputs.py` | creates the synthetic WAV, EDF+, AHA and old-header inputs for converter tests |
| `tests/conformance/cases.py` | the test cases |
| `tests/conformance/harness.py` | runs cases and compares results |
| `tests/conformance/golden/<case>/` | golden results: `stdout`, `stderr`, `status`, and `files/` (every file created or modified) |
| `tests/conformance/legacy/` | the legacy suite: the cases of the original package (`cases.py`) and their results from the unmodified C package (`golden/`); `harness.py check --legacy` runs each case with `--legacy` as the tool's first argument, so that legacy mode must reproduce the original exactly |

Each case runs one tool with given arguments (and optionally standard input,
extra input files, and environment variables) in a fresh copy of
`tests/data`, with `WFDB=.`, `LC_ALL=C` and `TZ=UTC`. `{cwd}` in an argument
stands for the absolute path of that work directory, which is written back as
`{cwd}` in the recorded standard output and error. Blobs larger than 64 KB
are stored as SHA-256 digests (`*.sha256`).

FLAC-compressed signal files written by a tool are compared by their decoded
contents (cases list them in `flac_files`), because the compressed bytes of
FLAC files depend on the libFLAC version and on the processor.

## Running

```sh
# Python implementation (from the repository root)
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl python

# C++ implementation (after building it in cpp/build; see cpp/README.md)
python3 tests/conformance/harness.py check --impl cpp

# any implementation, given a command template
python3 tests/conformance/harness.py check --impl "/path/to/bin/{tool}"

# selected tools or cases, verbose
python3 tests/conformance/harness.py check --impl python rdsamp rdann -v
```

`--impl` accepts `python`, `cpp`, `rust`, `julia`, `r`, `octave`, `matlab`,
or a command template containing `{tool}`. The environment variable
`WFDBX_<IMPL>_CMD` overrides the template of a named implementation, and
(for `cpp` and `rust`) `WFDBX_<IMPL>_BIN` names another directory of tools.

## Regenerating golden results

```sh
tests/reference/build_reference.sh /tmp/wfdb-ref
python3 tests/conformance/harness.py golden --cbin /tmp/wfdb-ref/bin
```

The C tools are run by name, with their directory first in `PATH`, so that
messages that include `argv[0]` are reproducible. The golden results in the
repository were produced on x86-64 Linux (glibc), with libFLAC 1.4.3.

## Adding cases

Add calls to `case(tool, args, ...)` in `cases.py`, regenerate the golden
results of the new cases (`harness.py golden --cbin ... CASE_IDS`), and check
them in. A case must not depend on the current date or time, or on behavior
that is undefined in C (see [`KNOWN_C_BEHAVIORS.md`](KNOWN_C_BEHAVIORS.md)).
