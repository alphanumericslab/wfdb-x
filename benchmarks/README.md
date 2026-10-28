# WFDB-x benchmarks

The same operations, timed in each of the seven WFDB-x languages, and in
wfdb-python and the original C tools for comparison. The results, and how
to get the most speed from WFDB-x, are in
[`docs/BENCHMARKS.md`](../docs/BENCHMARKS.md).

```sh
python3 benchmarks/run.py                      # all languages (builds the drivers first)
python3 benchmarks/run.py --langs cpp,python   # some of them
python3 benchmarks/run.py --cbin /path/to/wfdb/bin   # also time the original C tools
```

`run.py` writes the test records (with `make_records.py`, into
`benchmarks/build/data`, the same on every run), builds the drivers of the
compiled languages (into `benchmarks/build`), runs every operation in every
language, and prints the results as Markdown tables (`--json FILE` and
`--markdown FILE` save them). It stops with an error if two languages read
or wrote different data. For wfdb-python, set `WFDB_PYTHON` to a Python
that has the `wfdb` package (`pip install wfdb`).

## The records

| Record | Contents |
|---|---|
| `long` | 2 signals, format 212, 360 Hz, 1 hour (1,296,000 frames), and its annotation file `long.atr` (4,500 annotations, some with text) |
| `mimic` | multi-segment: 12 segments of 75,000 frames, 4 signals in format 212 at 125 Hz, the first at 4 samples per frame (500 Hz), as in the MIMIC Database |
| `wide` | 12 signals, format 16, 500 Hz, 10 minutes: a 12-lead ECG |

## The operations

Each is one call of the high-level API of the language, with its default
options unless stated.

| Operation | Call | Check |
|---|---|---|
| `read_long` | `read_record("long")` (ADC units) | sum of the samples |
| `read_long_phys` | `read_record("long")` in physical units | sum of the values, to 3 decimals |
| `read_mimic` | `read_record("mimic")` (one value per signal and frame) | sum of the samples |
| `read_wide` | `read_record("wide")` | sum of the samples |
| `write_long` | `write_record` of the samples of `long`, as a new record in format 16 | size of the signal file |
| `read_ann` | `read_annotations("long", "atr")` | number of annotations |
| `write_ann` | `write_annotations` of those annotations (times, codes, text) | size of the annotation file |

The command-line tools are timed as whole processes, started by the runner:
`rdsamp -r long` (1,296,000 lines of output, to `/dev/null`) and
`wfdbdesc long` (a small task: mostly the start-up time of the language).

## The drivers

| Language | Driver |
|---|---|
| C++ | [`cpp/bench.cpp`](cpp/bench.cpp) (built by `cpp/CMakeLists.txt`) |
| Rust | [`rust/src/main.rs`](rust/src/main.rs) (a Cargo package, `rust/Cargo.toml`) |
| Julia | [`julia/bench.jl`](julia/bench.jl) |
| Kotlin | [`kotlin/Bench.kt`](kotlin/Bench.kt) (built by `./gradlew benchJar` in `kotlin/`) |
| Python | [`python/bench.py`](python/bench.py) |
| R | [`r/bench.R`](r/bench.R) |
| MATLAB/Octave | [`matlab/wfdbx_bench.m`](matlab/wfdbx_bench.m) (run in Octave by `matlab/bench.m`) |
| wfdb-python | [`wfdb_python/bench.py`](wfdb_python/bench.py) |

A driver is run as `DRIVER OP DATADIR REPS`. It reads the records from
`DATADIR`, writes into a temporary directory, times one call of `OP`
("first": in Julia and Kotlin it includes compiling the code), then `REPS`
more ("best": the fastest of them), and prints one line of JSON:

```json
{"op": "read_long", "first": 0.051, "best": 0.022, "times": [0.024, 0.022], "check": -1806808018}
```

The runner also measures the peak memory of the whole driver process.

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GPL-3.0-or-later;
see [LICENSE](../LICENSE).
