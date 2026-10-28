# The C reference

How the expected results of the WFDB-x tests are produced: by the original
C WFDB Software Package (version 10.7.0, kept unmodified in
[`third_party/wfdb-main.zip`](../../third_party/)), never by hand.

| File | Contents |
|---|---|
| [`build_reference.sh`](build_reference.sh) | Builds the C package with FLAC support, with the deliberate divergences of WFDB-x applied (`divergences.patch`), into a given directory; with `WFDBX_ORIGINAL=1`, the unmodified package (the reference of the legacy suite) |
| [`divergences.patch`](divergences.patch) | The deliberate divergences of WFDB-x from the original package, as a patch to its C sources; [`docs/DIVERGENCES.md`](../../docs/DIVERGENCES.md) explains each one |
| [`gen_records.c`](gen_records.c) | The program, linked with the C library, that wrote most of the test records in [`tests/data/`](../data/README.md) |
| [`api_expect.c`](api_expect.c) | Prints the results of library functions that no command-line tool exercises, as the C library computes them: the expected values of the library unit tests in each language |

```sh
tests/reference/build_reference.sh build/wfdb-ref                     # with the divergences
WFDBX_ORIGINAL=1 tests/reference/build_reference.sh build/wfdb-orig  # the original package
```

The script needs a C compiler, make, unzip and libFLAC (set `FLAC_PREFIX`
if its headers are not installed); its header comments give the details.
