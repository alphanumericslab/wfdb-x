# Developing WFDB-x for C++

Notes for developers of the C++ implementation. Users should read
[README.md](README.md).

## Layout

* `src/` is the library. `annot.cpp`, `calib.cpp`, `signal.cpp`,
  `wfdbinit.cpp` and `wfdbio.cpp` follow the C files of the same names in
  `lib/` of the WFDB Software Package, function by function. `record.cpp`
  is the high-level API, and `flac.cpp` the FLAC codec.
* `apps/` holds the tools. Each follows its C program line by line, so that
  it can be compared with the original. `apps/cemul.hpp` holds the few
  helpers that reproduce the reference platform's behavior where C leaves
  it undefined.
* `include/wfdbx/wfdb.hpp` declares the C-style API, and
  `include/wfdbx/record.hpp` the high-level API.

## Bulk reading in `getvecs`

`getvecs(buffer, n)` reads `n` sample vectors with the semantics of `n`
calls of `getvec`; `getvecs(buffer, n, &status)` also gives the status of
the last `getvec` call. It decodes whole frames in bulk where it can:
formats 8, 16, 24, 32, 61, 80, 160, 212, 310 and 311 (one format per signal
group), and null signals (format 0) of known length, in regular files,
without deskewing or resampling. This covers records of several sampling
frequencies, in low-resolution mode (averaging the oversampled signals with
`meansamp`) and in high-resolution mode (from the start of a frame), and the
segments of multi-segment records, of fixed or variable layout (mapped with
`sigmap`), null segments included. It reads everything else with `getvec`,
as well as the frame at which checksums are verified or a null signal ends,
the change from one segment to the next, and the frames near the end of a
file. The bulk path reads the file in the same `bsize` blocks as the
per-frame path, and leaves the same state (samples, checksums, counts,
`gvc`), so the buffer state, statuses and messages are identical.
`read_record` reads multiples of 6 frames per call, so that formats 212, 310
and 311 end each call on a whole packed unit.
`wfdbx_set_bulk_read(false)` turns it off; the tests in `tests/test_bulk.cpp`
use it to compare both paths.

## Write errors

`WFDB_FILE::error()` and `eof()` use `ferror_unlocked` and `feof_unlocked`
where CMake finds them, and fall back to `ferror` and `feof` elsewhere,
including Windows, which has no documented lock-free versions.

The tools write the standard output with C stdio, which ignores a failed
write and sets the stream's error flag, as in C. `wfdbx_legacy_args`
installs an exit check (`src/wfdbio.cpp`) that flushes the standard output,
tests its error flag, and turns an exit status of 0 into 1 after a write
error. It is registered with `on_exit`, which gives it the exit status of
both `std::exit(n)` and a return from `main`, where CMake finds it
(`WFDBX_HAVE_ON_EXIT`: glibc); elsewhere `atexit` does not see the status,
and any exit after a write error has status 1. The unit tests call
`wfdbx_legacy_args`, so their `main` ends with `std::_Exit`.

## Performance

`benchmarks/cpp/` holds the benchmark driver of the C++ implementation
(`wfdbx_bench`, built and run by `benchmarks/run.py`, with the library
added by `add_subdirectory`, without tools or tests).
[docs/BENCHMARKS.md](../docs/BENCHMARKS.md) gives the results, including
the tools `rdsamp` and `wfdbdesc` against the original C programs.

## Testing

```sh
cmake --build cpp/build
ctest --test-dir cpp/build
python3 tests/conformance/harness.py check --impl cpp -j8
python3 tests/conformance/harness.py check --impl cpp -j8 --legacy
```
