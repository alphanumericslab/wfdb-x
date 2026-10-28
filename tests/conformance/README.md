# The conformance suite

Checks that an implementation of WFDB-x behaves exactly like the original C
WFDB Software Package: for each case, a command-line tool is run, and its
standard output, standard error, exit status and every file it creates or
changes are compared, byte for byte, with the results of the C program.

| Path | Contents |
|---|---|
| `harness.py` | Runs the cases with an implementation and compares the results (`check`), or records the results of the C programs (`golden --cbin DIR`) |
| `cases.py` | The 1023 test cases |
| `golden/<case>/` | The results of the C programs for each case: `stdout`, `stderr`, `status`, and `files/` |
| `legacy/` | The legacy suite: 877 cases of the original package's behavior (`legacy/cases.py`) and their results from the unmodified C package (`legacy/golden/`); `check --legacy` runs each with `--legacy` as the tool's first argument |

From the repository root:

```sh
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl cpp -j4
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl cpp -j4 --legacy
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl cpp rdsamp   # cases whose name starts with rdsamp
```

`--impl` is one of `python`, `cpp`, `rust`, `julia`, `r`, `octave`,
`matlab`, `kotlin`, or `c` with `--cbin DIR` for the C programs.
`python3 tests/conformance/harness.py --help` lists the options.

[`docs/conformance.md`](../../docs/conformance.md) describes the suite in
full: the environment of each case, how the golden results were made, and
how to add a case.
