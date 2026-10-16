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

A shell wrapper makes this shorter:

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

## High-level API

```julia
using WFDBX
rec = read_record("100s"; to="0:10")    # first 10 s (also: from, channels, highres, pad)
rec.samples                             # Matrix{Int32}: rec.samples[i, s] = sample i of signal s
physical(rec)                           # Matrix{Float64}, physical units (NaN: invalid)
rec.siginfo, rec.fs, rec.base_time, rec.comments, rec.channels
signal_names(rec)                       # signal descriptions, as bytes
read_header("100s")                     # Vector{Siginfo}
write_record("new", rec.samples, rec.fs; fmt=212, gains=200.0, adcres=11, units="mV",
             names=["MLII", "V5"])
write_record_physical("newp", physical(rec), rec.fs; gains=[200.0, 100.0], adcres=16,
                      units="mV")
ann = read_annotations("100s", "atr")   # Annotations: samples, codes, symbols, aux, ...
read_annotations("rec", "atr"; fs=250)  # fs: used if the record's header gives none
write_annotations("100s", "cpy", ann; fs=360)
```

Records are looked for in the WFDB path (the environment variable `WFDB`,
or `setwfdb(path)`); files are written in the current directory. These
functions throw a `WfdbError` on failure. Each one also accepts a `Wfdb`
instance as its first argument, and uses that instance's state (resetting
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

## C-style API

Each function of the C library is a Julia function with the same name and
arguments (`isigopen`, `getvec`, `putvec`, `annopen`, `getann`, `putann`,
`calopen`, `getcal`, `strtim`, `timstr`, `setwfdb`, ...), with these
conventions:

* **Library state.** The C library keeps its state (WFDB path, open
  records and annotators, ...) in global variables. In Julia it lives in a
  `Wfdb` object, which every function takes as an optional first argument.
  Without that argument, a function uses the default instance `lib()`:

  ```julia
  setwfdb(". /data")              # the default instance
  w = Wfdb()                      # an independent library state
  setwfdb(w, "/other/data")
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
records. It reads and writes MIT and AHA annotation files. As in C, an
output annotation file whose annotations are out of order is sorted with
`sortann` when it is closed. `getvecs(v, n)` reads `n` sample vectors at
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
same machine.

## Testing

From the root of the repository:

```sh
julia --startup-file=no --project=julia julia/test/runtests.jl   # unit tests
python3 tests/conformance/harness.py check --impl julia -j8        # conformance
```

[`DEVELOPING.md`](DEVELOPING.md) describes how the code is organized and
how to check that no tool compiles anything at run time.

## Authors and license

The Julia implementation was written by Reza Sameni (October 2026). It ports
the C code of the WFDB Software Package, written by George B. Moody
(1983-2014), with revisions by Benjamin Moody (2010-2022) and
contributions from others. [`docs/AUTHORS.md`](../docs/AUTHORS.md) lists
the authors of each ported file, and each source file credits the authors
of the C code it ports.

The licenses are those of the WFDB Software Package. The library is under
the GNU Library General Public License, version 2 or later
([`LICENSE.LIB`](../LICENSE.LIB)). The tools are under the GNU General
Public License, version 2 or later ([`LICENSE`](../LICENSE)).
