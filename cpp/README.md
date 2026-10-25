# wfdb-x for C++

wfdb-x for C++ is a C++17 implementation of the WFDB library and
command-line tools of the WFDB Software Package 10.7.0. It reads and writes
the same files as the original C library, and its tools produce
byte-identical output. The library is `libwfdbx`, its headers are in
`<wfdbx/...>` and its API is in namespace `wfdbx`. See the
[project README](../README.md) for the overall design.

* No dependencies beyond the C++17 standard library (FLAC-compressed signals
  are supported without libFLAC).
* Faster than the C library (see [Performance](#performance)).
* Linux, macOS and Windows (GCC 8+, Clang 7+, MSVC 2019+).

## Building and installing

With CMake 3.14 or later:

```sh
cmake -S cpp -B cpp/build                       # Release build by default
cmake --build cpp/build -j8
cmake --install cpp/build --prefix /usr/local   # optional
```

This builds the library (`libwfdbx`), the command-line tools (in
`cpp/build/bin/`) and the unit tests. Options:

| Option | Default | Effect |
|---|---|---|
| `WFDBX_BUILD_TOOLS` | `ON` | build the command-line tools |
| `WFDBX_BUILD_TESTS` | `ON` | build the unit tests |
| `BUILD_SHARED_LIBS` | `OFF` | build a shared library |

To use the installed library from a CMake project:

```cmake
find_package(wfdbx REQUIRED)
target_link_libraries(myprogram PRIVATE wfdbx::wfdbx)
```

or compile directly: `c++ -std=c++17 myprogram.cpp -lwfdbx`.

## Command-line tools

Each tool is a separate program with the name, options, output, error
messages and exit status of the original (see the *WFDB Applications Guide*,
[`third_party/wag.pdf`](../third_party/)):

```sh
cpp/build/bin/rdsamp -r 100s -t 10 -v -p
```

| Group | Tools |
|---|---|
| Signals | `rdsamp`, `wrsamp`, `wfdbdesc`, `sigamp`, `snip`, `xform`, `sampfreq`, `signame`, `signum`, `wfdbcat`, `wfdbwhich` |
| Time conversion | `wfdbtime`, `time2sec` |
| Annotations | `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann` |
| Format converters | `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`, `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`, `revise`, `parsescp` |

Records are found using the WFDB path (the `WFDB` environment variable), as
with the C library. Remote (http, ftp) records are not supported.

The sources in `apps/` follow the C programs line by line, so that each can
be compared with its original; `apps/cemul.hpp` holds the few helpers that
reproduce the reference platform's behavior where C leaves it undefined.

## No built-in signal parameters

The original package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits) and units (millivolts) whenever a
record or the user does not give them. These values describe the equipment
of the first PhysioNet databases, not modern recordings, and a silently
assumed value corrupts every time, duration, resampled signal and physical
value derived from it, with nothing in the output to say so. Like every
wfdb-x implementation, wfdb-x for C++ therefore never assumes them: a value
that the record or the user does not give is reported as unspecified, and
an operation that needs it stops with a clear error.

* `wrsamp -o` requires `-F FREQ`, `-G GAIN` (`-G 0` declares the signals
  uncalibrated) and the new `-R BITS`; the new `-U UNITS` gives the units,
  required for calibrated signals unless the input's units row gives them
  (`-R` and `-U` take lists, like `-G`).
* `ad2m` requires `-F`, `-G`, `-R` and `-U` (unless the gain is 0);
  `ahaecg2mit` requires the same options, before the input files;
  `wav2mit` requires `-G` and `-U` (unless the gain is 0); `a2m`, `rdann`,
  `ann2rr`, `sortann` and `m2a` take `-F FREQ` for records whose header does
  not give a frequency.
* A header without an ADC resolution gives a resolution of 0
  (`wfdbdesc`: "ADC resolution: not specified"); unspecified units are shown
  as `nd` (rdsamp, wfdbdesc, wfdb2mat, mit2edf, xform), not `mV`. `mit2edf`
  and `xform` stop if they need a resolution that is not specified.
* Errors such as "sampling frequency of record R is not specified", "signal
  N of record R is uncalibrated" and "ADC resolution of signal N of record R
  is not specified" replace the guesses.

To reproduce the results of the original tools, give the values they
assumed explicitly, for example `wrsamp -F 250 -G 200 -R 16 -U mV` (with
format 16; `-R 12` for format 212), `ad2m -F 250 -G 400 -R 12 -U mV`,
`ahaecg2mit -F 250 -G 400 -R 12 -U mV 1001.ecg`, `wav2mit -G 6400 -U mV`
(16-bit files; `-G 12.5` for 8-bit files) or `a2m -F 250`. See
[`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md).

**Legacy mode.** The original behavior remains available on request.
`--legacy` as the *first* argument of any tool (`rdsamp --legacy -r 100s
-p`) makes it behave exactly as the original one: the same options (those
added by wfdb-x, such as `-F` in `rdann` or `-R` in `wrsamp`, are then
unrecognized), outputs, messages, help texts and exit statuses. In the
library, `wfdbx_set_legacy(1)` turns legacy mode on (it returns the previous
setting; `wfdbx_get_legacy()` reads it, and `wfdbx_legacy_args(argc, argv)`
is the function the tools call to recognize `--legacy`), and the high-level
functions take a `legacy` option (`ReadOptions::legacy`,
`WriteOptions::legacy`, and a `legacy` parameter of `read_header()` and
`read_annotations()`) that turns it on for the duration of the call and
restores the previous behavior of these functions (gains of 200 and a
format-based ADC resolution by default in `write_record()`, 250 Hz for
annotations without a header, 200 adu/unit for uncalibrated signals in
`Record::physical()`). Legacy mode reproduces the original package exactly,
and it is tested against its results (the legacy conformance suite,
`harness.py check --legacy`, and the library values of
`tests/reference/api_expect.c`). It is kept for compatibility only: the
values it assumes are exactly the silent defaults this project removed, so
results produced with it carry the same risks.

## High-level API

`<wfdbx/record.hpp>` reads and writes whole records and annotation files
in a few calls. Results are returned by value (`std::vector`s and
`std::string`s that own their data), and errors are reported by throwing
`wfdbx::Error`. Records are found in the WFDB path; files are written
relative to the current directory.

```cpp
#include <cstdio>
#include <wfdbx/record.hpp>

wfdbx::ReadOptions opt;
opt.from = "0:10";                         // a WFDB time, or a sample number
opt.to = "0:20";
wfdbx::Record rec = wfdbx::read_record("100s", opt);
rec.fs;                                    // 360
rec.nsamples();                            // 3600
rec.at(0, 1);                              // sample 0 of signal 1 (ADC units)
rec.physical(0, 1);                        // ... in rec.siginfo[1].units
rec.siginfo[1].desc;                       // "V5"

wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr");
for (size_t i = 0; i < ann.size(); i++)
    std::printf("%lld %s\n", ann.samples[i], ann.symbols[i].c_str());

wfdbx::WriteOptions w;
w.fmt = 212;
w.gains = {200};                           // required: no default gain
w.adcres = {11};                           // required: no default resolution
w.units = {"mV"};                          // required for calibrated signals
w.names = {"MLII", "V5"};
wfdbx::write_record("new", rec.samples, rec.nsig, rec.fs, w);  // new.dat, new.hea
wfdbx::write_annotations("new", "atr", ann);                    // new.atr
```

`rec.samples` holds the samples frame by frame (`samples[i * nsig + s]` is
sample `i` of signal `s`); invalid samples are `WFDB_INVALID_SAMPLE`, and
`physical()` returns NaN for them. `ReadOptions` also selects signals
(`opt.channels = {"V5"}`), the multi-frequency mode (`highres`) and padding
of invalid samples (`pad`); `WriteOptions` takes one value for all signals,
or one per signal. `write_record_physical()` takes samples in physical
units.

**Output directory.** `WriteOptions::dir` (and the last parameter of
`write_annotations(record, annotator, ann, fs, dir)`) creates the files in
an existing directory instead of the current one: `w.dir = "out";
write_record("rec", ...)` writes `out/rec.hea` and `out/rec.dat`, and the
header names the record and its signal file without the directory (`rec 2
360 ...`, `rec.dat ...`), so that the record opens from that directory
under its plain name (`setwfdb("out"); read_record("rec")`). The record
name must not contain a directory then ("record name must not contain a
directory when dir is given"), and a missing directory is an error
("directory D does not exist"). The library's output directory
(`wfdbx_set_output_dir()`, below) is set for the duration of the call and
restored afterwards, also on errors; the same in legacy mode. Without
`dir`, a record name with a directory (`out/rec`) is recorded with it in
the header, as by the C library.

There is no default sampling frequency, gain, ADC resolution or units (see
[`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)):

* `WriteOptions::gains` is required ("write_record: gains must be
  specified"); a gain of 0 declares a signal uncalibrated, which
  `write_record_physical()` rejects ("signal N is uncalibrated"). `fs` must
  be greater than 0.
* `WriteOptions::adcres` is required, with values of at least 1
  ("write_record: ADC resolution(s) must be specified"; the C tools inferred
  it from the format), and `WriteOptions::units` must give the units of
  every signal whose gain is not 0 ("write_record: units must be
  specified").
* `read_record()` and `read_header()` report an ADC resolution that the
  header does not give as 0, and units it does not give as `std::nullopt`
  (never `"mV"`).
* `read_record()` returns `fs == 0` for a record whose header does not give
  a frequency, and throws "sampling frequency of record R is not specified"
  for a time string in `from`/`to` that needs it (any but `s...`, `e`, `i`,
  `o`; see `wfdbx_time_needs_freq()`). `rec.physical()` throws "signal N of
  record R is uncalibrated" for a signal with gain 0 (`N` is the signal
  number in the record, `rec.signals[s]`).
* `read_annotations(record, annotator, from, to, fs)` takes an optional
  sampling frequency (`std::optional<WFDB_Frequency>`; if given, it must be
  greater than 0, otherwise "read_annotations: fs must be > 0" is thrown),
  used (like `rdann -F`) if the record has no header or
  its header gives none; without it, the result's `fs` is the time
  resolution of the annotation file (0 if none), and time strings that need
  the frequency throw the error above.

Error handling:

```cpp
try {
    wfdbx::Record rec = wfdbx::read_record("nosuchrecord");
} catch (const wfdbx::Error &e) {
    std::fprintf(stderr, "%s\n", e.what());   // "can't read record nosuchrecord"
}
```

These functions use the global state of the library (they call
`wfdbquit()`), so they should not be interleaved with calls of the WFDB
library API on an open record.

## WFDB library API

`<wfdbx/wfdb.hpp>` declares every function of the WFDB library in namespace
`wfdbx`, with the C names, arguments and return values (`isigopen`,
`getvec`, `getann`, `putann`, `strtim`, ...), so that WFDB programs can be
ported line by line; the *WFDB Programmer's Guide* applies, and each
function is summarized in the header. The differences from C are in the
types:

* string arguments are `const char *`;
* strings returned by the library are `std::string`, or
  `std::optional<std::string>` where C may return `NULL`; they are returned
  by value, so unlike C's pointers they stay valid after later calls;
* the string fields of `WFDB_Siginfo` and `WFDB_Calinfo` are
  `std::optional<std::string>`, as C distinguishes `NULL` from `""`;
* an annotation's `aux` is a `std::optional<std::string>` holding the C
  bytes: a length byte followed by the data;
* `WFDB_Time` is 64 bits (as in the C library built with
  `-DWFDB_LARGETIME`).

As in C, arrays such as the `WFDB_Siginfo` array of `isigopen` and the
sample vector of `getvec` are allocated by the caller, a negative return
value indicates an error, and error messages are printed on `stderr`
(`wfdbquiet()` turns them off; `wfdberror()` returns the last one).

```cpp
#include <cstdio>
#include <wfdbx/wfdb.hpp>
using namespace wfdbx;

WFDB_Siginfo si[2];
if (isigopen("100s", si, 2) == 2) {
    WFDB_Sample v[2];
    while (getvec(v) > 0) { /* ... */ }
}
WFDB_Anninfo ai{"atr", WFDB_READ};
WFDB_Annotation a;
if (annopen("100s", &ai, 1) == 0)
    while (getann(0, &a) == 0)
        std::printf("%s %s\n", timstr(a.time).c_str(), annstr(a.anntyp)->c_str());
wfdbquit();
```

`getvecs(buffer, n)`, an addition, reads `n` frames at once with the
semantics of `n` calls of `getvec` (`buffer` must hold `n` times as many
values as `getvec` returns). Annotation codes are declared in
`<wfdbx/ecgcodes.hpp>`, and the mapping macros of `<wfdb/ecgmap.h>` are
functions in `<wfdbx/ecgmap.hpp>`. As in C, the library keeps global state
and is not thread-safe.

The library never assumes a sampling frequency, a gain, an ADC resolution
or units (the wfdb-x divergence described in
[`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)):
`sampfreq()` returns 0 for a header without a frequency; without a
frequency, `strtim()` fails (returns 0) for strings that need one,
`timstr()`/`mstimstr()` return `"s"` followed by the sample number, and
`setifreq()` fails; `aduphys()`, `physadu()`, `adumuv()` and `muvadu()`
return NaN or `WFDB_INVALID_SAMPLE` for an uncalibrated signal or an invalid
signal number. A header without an ADC resolution gives `adcres == 0`
(the C library inferred it from the format, or assumed `WFDB_DEFRES`, 12
bits), and one without units gives `units == std::nullopt`.
`wfdbx_time_needs_freq(string)`, an addition, tells whether `strtim()`
needs the frequency for a string. `WFDB_DEFFREQ`, `WFDB_DEFGAIN` and
`WFDB_DEFRES` remain defined but are not used.

**Absolute paths.** An input file named by an absolute path
(`isigopen("/data/mitdb/100", ...)`, `rdsamp -r /data/mitdb/100`) is opened
directly, and its directory is added to the WFDB path, so that the signal
files next to the header are found. The C library (and legacy mode)
searched for it in each directory of the WFDB path, joining `./` and the
name, so that it was found only from the root directory. In both modes,
`setwfdb(";")` (or `WFDB=";"`), a WFDB path with an empty component, makes
the library use names as given.

**Sorting annotation files.** An output annotation file whose annotations
were written out of order is sorted when it is closed (`oannclose()`,
`wfdbquit()`; unless `WFDBANNSORT` is 0), in the same process, with a
result identical, byte for byte, to that of `sortann -r. RECORD -a
ANNOTATOR`. The messages and the status are those of C ("Rearranging
annotations for output annotator ... done!"); the sortann program's own
messages (e.g. "init: can't open header for record ...") are gone. Unlike
the original sortann, the sort (and the `sortann` tool) never loses an
out-of-order annotation at time 0 (num 0, chan 0), nor the annotations
inserted after it. The C library ran the sortann program through the shell,
finding it only in the PATH; legacy mode runs it too (looked for next to the
executable, then in the PATH, as `sortann --legacy`, so that the original
behavior is reproduced, loss included), without a shell (the arguments are
passed directly, so names with spaces work), in the output directory if one
is set.

**Output directory.** `wfdbx_set_output_dir(dir)`, an addition, makes the
library create its output files (headers, signal and annotation files, for
writing or appending) as `dir/NAME`, `NAME` being the name it would use
otherwise; the names recorded in headers are unchanged. It returns the
previous value; `nullptr` or `""` means none (the default), and
`wfdbx_get_output_dir()` reads it (`std::nullopt` if none). As for any
output file, missing directories are created.

## FLAC-compressed signals

Formats 508, 516 and 524 are handled by a built-in FLAC decoder and encoder
(`src/flac.cpp`). Files written by the C library (libFLAC) are read exactly.
Files written by wfdb-x are standard FLAC streams that the C library reads
back with identical samples; their compressed bytes differ from libFLAC's
(which depend on the libFLAC version) and are the same in every wfdb-x
implementation.

## Performance

Best of 7 runs, printing a two-signal, 648,000-frame format 212 record (30
minutes at 360 Hz) to `/dev/null` on Linux x86-64 (GCC, Release build):

| Command | C (10.7.0) | C++ |
|---|---|---|
| `rdsamp -r big` | 0.18 s | 0.05 s |
| `rdsamp -r big -p` | 0.41 s | 0.17 s |

## Testing

```sh
cmake --build cpp/build && cpp/build/wfdbx_tests             # unit tests
python3 tests/conformance/harness.py check --impl cpp -j8   # conformance
```

The unit tests (`tests/`, 69 tests) cover the library API, the high-level
API and the FLAC codec, with expected values produced by the C library. The
conformance suite ([`docs/conformance.md`](../docs/conformance.md), 928
cases, and 858 in legacy mode) runs every tool on test cases whose expected results were produced by
the original C programs, and requires byte-identical results.

## Authors and license

The C code ported here was written by George B. Moody and others, and
revised by Benjamin Moody; the header of each source file credits the
authors of the C file it ports (see [`docs/AUTHORS.md`](../docs/AUTHORS.md)).
The C++ implementation was developed by Reza Sameni (2026), with AI
assistance (see the project README).

The library (`include/`, `src/`) is distributed under the GNU Library
General Public License, version 2 or later; the command-line tools (`apps/`)
and the tests under the GNU General Public License, version 2 or later. See
[`LICENSE.LIB`](../LICENSE.LIB) and [`LICENSE`](../LICENSE).
