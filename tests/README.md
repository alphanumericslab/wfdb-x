# WFDB-x tests

The tests shared by the seven implementations. Each implementation also has
unit tests of its own, in its directory (for example `python/tests`,
`cpp/tests`, `rust/tests`).

| Directory | Contents |
|---|---|
| [`conformance/`](conformance/README.md) | The conformance suite: 1023 command-line test cases, and 877 more for legacy mode, whose expected results were all produced by the original C programs, run by a harness that works with any implementation |
| [`data/`](data/README.md) | The test records and input files, most of them written by the original C library |
| [`reference/`](reference/README.md) | How the reference results are made: the build of the original C package, the deliberate divergences of WFDB-x as a patch, and the C programs that wrote the test records and the expected values of the library unit tests |

To check an implementation, from the repository root:

```sh
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl python -j4
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl python -j4 --legacy
```

(`--impl` is one of `python`, `cpp`, `rust`, `julia`, `r`, `octave`,
`matlab`, `kotlin`.) [`docs/conformance.md`](../docs/conformance.md)
describes the suite in full.
