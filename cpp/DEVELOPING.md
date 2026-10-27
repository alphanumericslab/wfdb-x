# Developing wfdb-x for C++

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

`getvecs(buffer, n)` reads `n` frames with the semantics of `n` calls of
`getvec`; `getvecs(buffer, n, &status)` also gives the status of the last
`getvec` call. It decodes frames in bulk where it can: formats 8, 16, 24,
32, 61, 80, 160, 212, 310 and 311, with one sample per signal per frame, in
regular files, without deskewing or resampling, and with one format per
signal group. It reads everything else frame by frame, as well as the frame
at which checksums are verified and the frames near the end of a file. The
bulk path reads the file in the same `bsize` blocks as the per-frame path,
so the buffer state, statuses and messages are identical.
`wfdbx_set_bulk_read(false)` turns it off; the tests in `tests/test_bulk.cpp`
use it to compare both paths.

## Write errors

`WFDB_FILE::error()` and `eof()` use `ferror_unlocked` and `feof_unlocked`
where CMake finds them, and fall back to `ferror` and `feof` elsewhere,
including Windows, which has no documented lock-free versions.

## Performance

Best of 7 runs on Linux x86-64, GCC, Release build, for `big`, a
two-signal, 648,000-frame format 212 record generated for the benchmark:

| Command | C | C++ |
|---|---|---|
| `rdsamp -r big` | 0.18 s | 0.05 s |
| `rdsamp -r big -p` | 0.41 s | 0.17 s |

## Testing

```sh
cmake --build cpp/build
ctest --test-dir cpp/build
PYTHONPATH=python/src python3 tests/conformance/harness.py check --impl cpp -j8
PYTHONPATH=python/src python3 tests/conformance/harness.py check --impl cpp -j8 --legacy
```
