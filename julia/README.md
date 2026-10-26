# wfdb-x for Julia

This directory holds the Julia implementation of wfdb-x, the package
`WFDBX`. It reimplements the [WFDB Software
Package](https://physionet.org/content/wfdb/) 10.7.0: the WFDB library, with
the C library's API and function names, a high-level API, and the 33 WFDB
command-line tools. It reads and writes exactly the same files as the C
library, and its tools produce byte-identical output, messages and exit
statuses. This is checked by the wfdb-x conformance suite
(`tests/conformance/`), whose expected results come from the C
implementation.

The package is pure Julia and depends only on Julia's standard libraries.
It requires Julia 1.9 or later.

## Installation

From a copy of the wfdb-x repository:

```julia
using Pkg
Pkg.develop(path="/path/to/wfdb-x/julia")
using WFDBX
```

(or `] dev /path/to/wfdb-x/julia` in the package REPL). The first `using`
precompiles the package, which takes one to two minutes. Precompilation
runs a workload that compiles the code of the library and the tools, so
later processes start without compiling anything.

## Command-line tools

The tools are run through the driver script `bin/wfdbx.jl`. Its first
argument names the tool, and the rest are the tool's arguments, as for the
C program:

```sh
julia --startup-file=no --project=/path/to/wfdb-x/julia \
    /path/to/wfdb-x/julia/bin/wfdbx.jl rdsamp -r 100s -t 10
```

The driver keeps using Julia's package depot of the user's home directory
when `HOME` was changed (to give `~` names another meaning), so that the
package is not compiled again. A shell wrapper makes this shorter:

```sh
#!/bin/sh
# wfdbx: run a wfdb-x tool, e.g. `wfdbx rdsamp -r 100s -t 10`
exec julia --startup-file=no --project=/path/to/wfdb-x/julia \
    /path/to/wfdb-x/julia/bin/wfdbx.jl "$@"
```

Available tools (`WFDBX.tools()`):

| | |
|---|---|
| Signals | `rdsamp`, `wrsamp`, `xform`, `snip`, `sigamp`, `wfdbdesc`, `sampfreq`, `signame`, `signum`, `wfdbtime`, `time2sec` |
| Annotations | `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann` |
| Files | `wfdbcat`, `wfdbwhich` |
| Converters | `a2m`, `ad2m`, `ahaecg2mit`, `edf2mit`, `m2a`, `makeid`, `md2a`, `mit2edf`, `mit2wav`, `parsescp`, `rdedfann`, `readid`, `revise`, `wav2mit`, `wfdb2mat` |

### No built-in signal parameters

The original package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits, or one based on the storage
format) and units (millivolts) whenever a record or the user does not give
them. These values describe the equipment of the first PhysioNet
databases, not modern recordings, and a silently assumed value corrupts
every time, physical value and file derived from it, with nothing in the
output to say so. As in every wfdb-x implementation, the Julia tools and
library therefore never assume them: a value that is needed but not given
is an error.

* `wrsamp -o` requires `-F FREQ`, `-G GAIN` (`-G 0`: uncalibrated) and
  `-R BITS`, and `-U UNITS` for calibrated signals unless the input's
  second line gives them (`-G`, `-R` and `-U` take lists, the last value
  applying to the remaining signals).
* `ad2m` requires `-F`, `-G`, `-R` and `-U` (unless the gain is 0);
  `ahaecg2mit` requires the same options, before the input files;
  `wav2mit` requires `-G` and `-U` (unless the gain is 0) (the frequency
  and resolution come from the WAV file); `a2m` takes `-F FREQ` if the
  record header gives none, and converts annotation times given in
  milliseconds at that frequency (the C program assumed 4 ms per sample).
* `rdann`, `ann2rr`, `sortann` and `m2a` accept `-F FREQ` (and `rr2ann`
  requires it) for records whose header does not give a frequency.
* The other tools report an error when they need a value that the record
  does not specify (for example `mit2edf`: "ADC resolution of signal N of
  record R is not specified"); unspecified units are shown as `nd`, and
  `wfdbdesc` prints "ADC resolution: not specified".

To reproduce the results of the original tools, give the values they
assumed explicitly, e.g. `wrsamp -F 250 -G 200 -R 16 -U mV`,
`ad2m -F 250 -G 400 -R 12 -U mV`,
`ahaecg2mit -F 250 -G 400 -R 12 -U mV FILE.ecg`,
`wav2mit -G 6400 -U mV` (16-bit files; 12.5 for 8-bit files), or
`a2m -F 250`. See [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md).

**Legacy mode.** `--legacy` as the *first* argument of any tool
(`rdsamp --legacy -r 100s -t 10`) makes it behave exactly as the original
tool: the original options (the wfdb-x options such as `-F` in `rdann`
are unrecognized), defaults, messages, help texts and exit statuses. In
the library, `wfdbx_set_legacy([w], on)` (which returns the previous
setting), `wfdbx_get_legacy([w])` and `wfdbx_legacy_args([w], args)` (used
by the tools) control the same mode, per `Wfdb` instance (off by default);
the high-level functions take a `legacy=false` keyword argument
(`read_record`, `read_header`, `read_annotations`, `write_record`,
`write_record_physical`, `write_annotations`, `physical`) that applies the
original defaults for that call only. Legacy mode reproduces the original
package exactly, and is tested against its results (the legacy
conformance suite, `harness.py check --legacy`). It is kept for
compatibility only: the values it assumes are exactly the silent defaults
this project removed, so results produced with it carry the same risks.

A tool can also run inside a Julia session, with its standard streams
captured:

```julia
status, out, err = WFDBX.run_tool("rdsamp", ["-r", "100s", "-t", "1"]; dir="/path/to/data")
```

## Finding records and files

Every relative name is read under the input directory and written under the
output directory -- whatever you set as the input directory, a local
directory or a URL, prefixes it; a name given as a full path (`/Users/...`),
a `~` path or a URL is used as given; nothing else is searched. (The
original library searched the directories of the WFDB path, and possibly
`http://physionet.org/physiobank/database`: a search can silently open the
wrong file, such as a stale copy earlier in the path, and fails in ways
nobody notices; wfdb-x tries exactly one location.) Relative names may
contain directories and `..` (`"mitdb/100"`, `"../data/100"`). The tools use
the environment variables below.

| Setting | Julia | Environment variable | Default |
|---|---|---|---|
| input directory (a directory, a `~` path or a URL) | `wfdbx_set_input_dir([w], d)` (returns the previous one), `wfdbx_get_input_dir([w])`; `input_dir=` of the readers | `WFDBX_INPUT_DIR` | none: the current directory |
| output directory (local) | `wfdbx_set_output_dir([w], d)`, `wfdbx_get_output_dir([w])`; `dir=` of the writers | `WFDBX_OUTPUT_DIR` | none: the current directory |
| network access | `wfdbx_set_network([w], true)` (returns the previous setting, 1 or 0), `wfdbx_get_network([w])`; `network=` of the readers | `WFDBX_NETWORK` (a non-zero number: on) | off |

The settings belong to a `Wfdb` instance (by default, `lib()`). A function
call overrides the environment variable (read when the setting is first
needed); `nothing` (or `""`; for the network, `nothing` or a negative
number) restores the default, i.e. the environment variable's value if it
is set. A relative or `~` directory is used relative to the current
directory (or expanded) when a file is opened. The high-level readers set
`input_dir=` and `network=` for the duration of the call only (and restore
the previous values, also on errors); `nothing` keeps the current setting.

**PhysioNet.** The files of a PhysioNet database are under
`https://physionet.org/files/<database>/<version>/`. Reading from it is an
explicit choice -- wfdb-x never contacts a server unless network access is
on:

```julia
wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
wfdbx_set_network(true)
rec = read_record("100"; to="0:10")
# or, for one call:
rec = read_record("100"; input_dir="https://physionet.org/files/mitdb/1.0.0/", network=true)
```

```sh
WFDBX_NETWORK=1 WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/ wfdbx rdsamp -r 100 -t 0:5
```

Remote files are read with the `Downloads` standard library (loaded when
the first URL is read), in full, and kept for the rest of the process (each
URL is requested at most once per `Wfdb` instance; redirects are followed,
an HTTP status of 400 or more is a failure, and
reading gives up if connecting takes 30 s or no data arrives for 30 s, with no limit on the total time). They are
read-only: a URL cannot be written, nor be the output directory
(`wfdbx_set_output_dir` then reports an error and returns the current
setting). With network access off, a URL is not opened, and the first
attempt prints `wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or
call wfdbx_set_network(1) to open URL`.

**Files named in headers.** The signal files named in a header, and the
segments of a multi-segment record, are in the directory of that header (on
disk or at its URL) or below it: `100.dat` is read next to `100.hea`, and
`data/a.dat` in its subdirectory `data`. Nothing else is tried, and a name
that is absolute, begins with `~`, is a URL or contains a `..` component is
refused (`init: file NAME named in the header of record REC is not in the
header's directory`), so that a header (perhaps downloaded) cannot make the
library read other local files or contact other servers. (`~` as a segment
name, a null segment, and `-` as a signal file name, the standard input,
keep their meaning.) Annotation files, `.info` files and the calibration
file (`WFDBCAL`) follow the rule above with the name as given: the
annotations of record `mitdb/100` are `<input directory>/mitdb/100.atr`.

**The C-style API.** `setwfdb(p)` sets the input directory: `p` must name a
single directory (`setwfdb("data")`; `""` or `";"` restores the default;
several, such as `". data"`, are an error: `setwfdb: wfdb-x reads from a
single input directory; use wfdbx_set_input_dir (or legacy mode for the WFDB
search path)`). `setwfdb` splits its argument at spaces, as the original does, so a directory whose name contains a space must be set with `wfdbx_set_input_dir`, which takes the name as it is.
`getwfdb()` returns the input directory, or `"."` if none
is set; `resetwfdb()` restores the value set by the last `setwfdb`
(`wfdbquit()` leaves the settings as they are). The `WFDB` environment
variable is not used: if it is set, the first lookup prints `wfdb-x: the
WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use
legacy mode)`.

**Legacy mode** (`--legacy`, `wfdbx_set_legacy([w], true)`, `legacy=true`)
keeps the original search of the WFDB path (`WFDB`, `setwfdb` with several
entries, `@file` paths, `%r`, names containing `..` refused), without any
network access (as the reference C build, compiled without network
support: URL names and URL path entries are not opened). The input
directory and `WFDBX_NETWORK` are not used in legacy mode; the output
directory is.

## High-level API

```julia
using WFDBX
rec = read_record("100s"; to="0:10")    # first 10 s (also: from, channels, highres, pad)
rec.samples                             # Matrix{Int32}: rec.samples[i, s] = sample i of signal s
physical(rec)                           # Matrix{Float64}, physical units (NaN: invalid)
rec.siginfo, rec.fs, rec.base_time, rec.comments, rec.channels
rec.base_time_ms, rec.base_date         # e.g. 50403500, (2024, 6, 21); or nothing
rec.checksum_ok                         # false if the data do not match the header's checksums
signal_names(rec)                       # signal descriptions, as bytes
h = read_header("100s")                 # Header (no signal file is opened)
h.fs, h.counter_freq, h.base_counter, h.nsamples, h.nsig, h.siginfo, h.base_time,
h.base_time_ms, h.base_date, h.comments
write_record("new", rec.samples, rec.fs; fmt=212, gains=200.0, adcres=11, units="mV",
             names=["MLII", "V5"])
write_record_physical("newp", physical(rec), rec.fs; gains=[200.0, 100.0], adcres=16,
                      units="mV")
ann = read_annotations("100s", "atr")   # Annotations: samples, codes, symbols, aux, ...
read_annotations("rec", "atr"; fs=250)  # fs: used if the record's header gives none
write_annotations("100s", "cpy", ann; fs=360)
write_annotations("100s", "raw", ann; sort=false)  # leave an out-of-order file unsorted
```

Records are read under the input directory and files are written under the
output directory (by default, the current directory), or in `dir` (see
*Finding records and files* above, and below). These functions throw a
`WfdbError` on failure; `read_record` throws "can't read signal data of
record REC (getvec status S)" when reading stops with a getvec status below
-1, e.g. -3 for a signal file shorter than its header says, instead of
returning the samples read so far (reaching the end of the record is not an
error). This applies in legacy mode too, since the high-level API is a
wfdb-x addition (`getvec`, `getvecs`, the new `getvecs_status`, which also
returns that status, and the tools are unchanged). Each one also accepts a
`Wfdb` instance as its first argument, and uses that instance's state (resetting
it with `wfdbquit`). Their docstrings (`?read_record` in the REPL) describe
the options.

No sampling frequency, gain, ADC resolution or units are ever assumed (a
deliberate divergence from the C library, which assumed 250 Hz, 200 adu/mV,
12 bits and millivolts; see [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)):
`write_record` and `write_record_physical` require `gains` (0 declares a
signal uncalibrated, which is an error for physical samples), `adcres`
(at least 1 bit; "write_record: ADC resolution(s) must be specified"), `units` for
every signal whose gain is not 0 ("write_record: units must be specified")
and `fs > 0`; `read_record` gives `fs == 0` for a header without a
frequency, and rejects time strings that need one, and its `siginfo` has
`adcres == 0` and `units === nothing` where the header gives none;
`physical` throws for an uncalibrated signal; `read_annotations` takes an
optional `fs` for records without a frequency.

### Directories, absolute paths and annotation order

**Output directory.** `write_record(...; dir="out")`,
`write_record_physical(...; dir="out")` and `write_annotations(...;
dir="out")` create their files in the directory `out` (which must exist:
otherwise a `WfdbError`, "directory out does not exist"), and the header
names the record and its signal file without the directory (`rec 2 360
...`, `rec.dat ...`), so that the record opens from that directory under
its plain name (`setwfdb("out")`, then `read_record("rec")`; or
`read_record("out/rec")`). The record name must not contain a directory
when `dir` is given (a `WfdbError`). In the library API,
`wfdbx_set_output_dir([w], "out")` makes every output file of that `Wfdb`
instance be created in `out` (it returns the previous directory, as bytes,
or `nothing`; `wfdbx_set_output_dir(nothing)` restores the default, files
created as named, and `wfdbx_get_output_dir([w])` returns the current
one); the writers set it for the duration of the call, and restore it
afterwards, also on errors. The C-style API and the tools are otherwise
unchanged: `newheader("out/rec")` and `wrsamp -o out/rec` still record the
name `out/rec`, as in C.

**Absolute paths.** A record named by an absolute path
(`read_record("/data/mitdb/100")`, `rdsamp -r /data/mitdb/100`) is opened
as given, and its signal files are found next to its header. The C library
searched for such a name in each directory of the WFDB path (`./` + the
name), so that it was found only from the root directory; it still does so
in legacy mode, where an empty component in the WFDB path makes names be
used as given: with `setwfdb(";")` (or `WFDB=";"`), `/data/mitdb/100` opens
in legacy mode too.

**Annotation order.** Annotations written out of canonical order (by time,
then `num`, then `chan`) are rearranged when the file is closed, in the
same process, with a result identical byte for byte to that of `sortann`
(the last of several annotations with the same time, `num` and `chan` is
kept, and `NOTQRS` annotations are dropped); `WFDBANNSORT=0` disables it.
`write_annotations(...; sort=true)` or `sort=false` decides for that call
only, whatever `WFDBANNSORT` says (in legacy mode too; the environment is
not changed).
Unlike the original `sortann`, neither the sort nor the `sortann` tool
loses an out-of-order annotation at time 0 (written after later ones), nor
those inserted after it. The C library ran the `sortann` program (found in
the `PATH`), as legacy mode does (running `bin/wfdbx.jl sortann --legacy`
in a separate `julia` process, without a shell, in the output directory if
one is set), with the original loss.

### Checksums, and outputs that are inputs

**Checksum errors.** When `read_record` reads a record to its end and the
samples do not match the checksums in its header (getvec status -4: the
data are complete, only their sum disagrees), it returns every frame (the
last one included) and warns with `@warn "checksum error in record REC: the
signal data do not match the checksums in its header"` (instead of the
library's `getvec: checksum error in signal N`); `checksum_warning=false`
turns the warning off. Either way, the record's `checksum_ok` is `false`
(`true` otherwise; the checksums are verified only by a read that reaches
the end of the record). Any other read error (e.g. a truncated signal file,
status -3) is still a `WfdbError`. The C-style `getvec` and the tools are
unchanged. This behavior is identical in all six implementations of wfdb-x.

**An output signal file is never an input file.** The library refuses to
create an output signal file that is the same file (same device and inode,
whatever its name: another spelling, a hard link) as a signal file of the
open input record, including the signal files of every segment of an open
multi-segment record: `osigfopen` (or `osigopen`) prints `osigfopen: output
file NAME is also an input file`, returns -3, and the input is left intact
(e.g. `xform -i vlay -o fmt16`, where `fmt16` is a segment of `vlay`, used to
truncate `fmt16.dat` while reading it; xform now prints `xform: can't write
output signals (osigopen: output file fmt16.dat is also an input file)`).
Legacy mode keeps the original behavior (no check). This behavior is
identical in all six implementations of wfdb-x.

## C-style API

Each function of the C library is a Julia function with the same name and
arguments (`isigopen`, `getvec`, `putvec`, `annopen`, `getann`, `putann`,
`calopen`, `getcal`, `strtim`, `timstr`, `setwfdb`, ...), with these
conventions:

* **Library state.** The C library keeps its state (input directory, open
  records and annotators, ...) in global variables. In Julia it lives in a
  `Wfdb` object, which every function takes as an optional first argument.
  Without that argument, a function uses the default instance `lib()`:

  ```julia
  setwfdb("/data")                # the input directory of the default instance
  w = Wfdb()                      # an independent library state
  wfdbx_set_input_dir(w, "/other/data")
  wfdbfile(w, "hea", "100s")      # path of the header of 100s, or nothing
  ```

* **Strings are bytes.** WFDB files are not UTF-8, so the library returns
  text as `Vector{UInt8}`. The exceptions are time and date strings
  (`timstr`, `mstimstr`, `datstr`), which are `String`s. Arguments may be
  `String`s or byte vectors. C's `NULL` is `nothing`.
* **Integer types** are those of the C reference platform: `WFDB_Sample`
  and C `int` are `Int32`; `WFDB_Time` and `long` are `Int64`.
* **Structures** (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) have the C field names. Arrays that a C function fills are
  passed as vectors, as in `isigopen(record, si::Vector{Siginfo}, nsig)`
  or `getvec(v::Vector{Int32})`.
* **Errors** are handled as in C. Functions return error codes and print
  messages on the standard error unless `wfdbquiet()` was called.
  `wfdberror()` returns the last message.
* **No default sampling frequency, gain, ADC resolution or units** (wfdb-x
  divergence; see
  [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)): `sampfreq` returns 0
  for a header without a frequency; `strtim`, `timstr` and `mstimstr`
  report an error without one (`wfdbx_time_needs_freq(string)`, a wfdb-x
  addition, tells whether `strtim` needs it); `aduphys`, `physadu`,
  `adumuv` and `muvadu` report an error and return `NaN` or
  `WFDB_INVALID_SAMPLE` for an uncalibrated signal or an invalid signal
  number. A header without an ADC resolution gives `adcres == 0`, and one
  without units gives `units === nothing` (never millivolts).
  `WFDB_DEFFREQ`, `WFDB_DEFGAIN` and `WFDB_DEFRES` remain defined but
  unused.

```julia
n = isigopen("100s", nothing, 0)        # number of signals (reads the header only)
si = [Siginfo() for _ in 1:n]
isigopen("100s", si, n)                 # open the signals; si receives their descriptions
v = zeros(Int32, n)
for t in 0:9
    getvec(v) > 0 || break
    println(mstimstr(t), " ", aduphys(0, v[1]), " ", aduphys(1, v[2]))
end
wfdbquit()

annopen("100s", [Anninfo("atr", WFDB_READ)], 1)
a = Annotation()
while getann(0, a) == 0
    println(a.time, " ", String(annstr(a.anntyp)))
end
```

The library supports every signal format, including EDF and the FLAC
formats 508, 516 and 524, as well as multi-segment and multi-frequency
records. It reads and writes MIT and AHA annotation files. An output
annotation file whose annotations are out of order is sorted when it is
closed, as by `sortann` (see "Annotation order" above). `getvecs(v, n)` reads `n` sample vectors at
once; the result is the same as `n` calls of `getvec`, but faster.

The parts of the C standard library that affect output are emulated
exactly: glibc's `printf` (`cformat`, `cprintf`, `cfprintf`, including
`%e`/`%f`/`%g` of every `Float64`), `strtol`/`strtod`/`sscanf`, `rand`, and
C `FILE` streams (`WfdbFile`). They are not exported; use them as
`WFDBX.cformat` and so on.

## FLAC

The FLAC formats use a FLAC decoder and encoder written in Julia (the C
library uses libFLAC). The decoder handles every standard FLAC subframe and
coding type. The encoder writes the same bytes as the other wfdb-x
implementations; libFLAC's compressed bytes depend on its version, but both
decode to the same samples.

## Performance

Tool processes load the precompiled package image and compile nothing at
run time. A tool such as `wfdbwhich` takes about 0.23 s to run, of which
about 0.21 s is Julia's own startup (`julia -e 'exit()'`). After that, the
tools run at C speed. In one process, `rdsamp` prints a record of 648,000
two-signal frames (format 212) in about 0.10 s in raw units and 0.13 s in
physical units (`-p`). The C `rdsamp` takes about 0.13 s and 0.39 s on the
same machine. `write_record` (which calls `putvec` for each frame) writes
216,000 two-signal frames in 0.01-0.02 s in every format, about as fast as
`read_record` reads them back.

## Testing

From the root of the repository:

```sh
julia --startup-file=no --project=julia julia/test/runtests.jl   # unit tests
python3 tests/conformance/harness.py check --impl julia -j8        # conformance
```

[`DEVELOPING.md`](DEVELOPING.md) describes how the code is organized and
how to check that no tool compiles anything at run time.

## Authors and license

The Julia implementation was developed by Reza Sameni (2026), with AI
assistance (see the project README). It ports
the C code of the WFDB Software Package, written by George B. Moody
(1983-2014), with revisions by Benjamin Moody (2010-2022) and
contributions from others. [`docs/AUTHORS.md`](../docs/AUTHORS.md) lists
the authors of each ported file, and each source file credits the authors
of the C code it ports.

The licenses are those of the WFDB Software Package. The library is under
the GNU Library General Public License, version 2 or later
([`LICENSE.LIB`](../LICENSE.LIB)). The tools are under the GNU General
Public License, version 2 or later ([`LICENSE`](../LICENSE)).
