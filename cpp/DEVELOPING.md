# Developing WFDB-x for C++

Notes for developers of the C++ implementation. Users should read
[README.md](README.md).

## Layout

* `src/` is the library. `annot.cpp`, `calib.cpp`, `signal.cpp`,
  `wfdbinit.cpp` and `wfdbio.cpp` follow the C files of the same names in
  `lib/` of the WFDB Software Package, function by function. `record.cpp`
  is the high-level API, `metadata.cpp` the header metadata functions of
  the high-level API (`read_metadata`, `set_metadata`, ...; the rules are
  in `../tests/metadata/README.md`), and `flac.cpp` the FLAC codec.
* `apps/` holds the tools. Each follows its C program line by line, so that
  it can be compared with the original. `apps/cemul.hpp` holds the few
  helpers that reproduce the reference platform's behavior where C leaves
  it undefined.
* `include/wfdbx/wfdb.hpp` declares the C-style API, and
  `include/wfdbx/record.hpp` the high-level API, including the header
  metadata functions and their exceptions `ArgumentError` and `FileError`.
* `tests/` holds the unit tests (`tests.hpp` is the test framework, and
  `http_server.hpp` the local HTTP server on 127.0.0.1 of the network
  tests). `tests/test_metadata.cpp` runs the 56 shared metadata cases of
  `../tests/metadata/cases.tsv`. Some tests run tools of the same build
  (`sortann`, and `wrsamp`, `mit2wav` and `mit2edf` for the files that the
  tools open themselves, in `tests/test_files.cpp`); CMake builds them
  first.

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

## Read errors of the high-level readers

`getskewedframe` sets the flag `read_failed` (in `src/signal.cpp`) wherever
it sets the status -3 (a decoder or I/O error, "unexpected EOF in signal
N" with a known length, "error opening segment"), whatever status `getvec`
then returns: a checksum error verified in the same frame gives -4, which
replaces -3. `read_record` and `check_record` turn on
`detail::wfdbx_set_read_checked` (which also clears the flag) while they
read: `getvecs` then stops before a frame in which the flag is set, and
returns the status -3 (if the status was -4 or >= -1). A -4 alone (a
checksum error, all samples read) keeps the frame, and reading continues.
`getvec`, `getframe`, and `getvecs` outside the high-level readers (as
`rdsamp` uses it) are unchanged. `read_record` reserves at most
max(block, 2^26 / nsig + 1) frames in advance, whatever the header's length
or `to` gives, and grows the buffer as it reads.

## Writing through temporary files

`write_record` and `write_annotations` check all their arguments first, then
call `detail::wfdbx_staging_begin` (`src/wfdbio.cpp`). While the staging is
active, `wfdb_fopen` opens each output file ("wb", "ab"), keyed by its
absolute path, as a temporary file `.BASENAME.XXXXXXXX.tmp` (`mkstemps`,
owner-only) in the directory of its destination (for a symbolic link, of
the file it leads to); a later "rb", "wb" or "ab" of the same destination
opens the same temporary file (the in-process annotation sort reads and
rewrites it). URLs, the standard streams, directories and existing files
that are not regular files (devices, FIFOs) are opened as before.
`wfdbx_staging_end(commit)` gives each temporary file the permissions of its
destination (or 0666 less the umask) and renames it over it, only when every
file is complete and no write error occurred; otherwise it removes them all.
In legacy mode, the out-of-order annotation file that `oannclose` sorts with
the `sortann` program is renamed over its destination first
(`wfdbx_staging_commit_one`), unless a write error occurred (it is then
neither renamed nor sorted). The equivalents in Python are
`_wfdbio._staging_begin`, `_staged_open`, `_staging_end` and
`_staging_commit_one`.

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

## Packaging

`cmake --install` installs the library, the headers, the tools, the CMake
package files `wfdbxConfig.cmake` (the exported targets) and
`wfdbxConfigVersion.cmake` (written by `write_basic_package_version_file`,
SameMajorVersion), and `LICENSE`, `LICENSE-GPL` and `NOTICE` from the root
of the repository, in `${CMAKE_INSTALL_DATADIR}/doc/wfdbx`. The `wfdbx`
target requires `cxx_std_17` publicly, so that consumers compile its headers
with C++17. The unit tests find the tools through `$<TARGET_FILE_DIR:sortann>`,
which also works with multi-configuration generators (`ctest -C Release`
after a Ninja Multi-Config or Visual Studio build). To check the package:

```sh
cmake --install cpp/build --prefix /tmp/wfdbx-prefix
# then, in a project with find_package(wfdbx 1.2.2 CONFIG REQUIRED) and
# target_link_libraries(... wfdbx::wfdbx):
cmake -S consumer -B consumer/build -DCMAKE_PREFIX_PATH=/tmp/wfdbx-prefix
```

## Testing

```sh
cmake --build cpp/build
(cd cpp/build && ctest)
python3 tests/conformance/harness.py check --impl cpp -j8
python3 tests/conformance/harness.py check --impl cpp -j8 --legacy
```
