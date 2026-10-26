# Deliberate divergences from the C implementation

wfdb-x reproduces the WFDB Software Package 10.7.0 exactly, with the
exceptions described here: **it has no built-in signal parameters**, it
**finds files only where they are named** (no search path, and no network
access unless the user asks for it), it **sorts out-of-order annotation
files itself** instead of running a separate program, and its sorting
**does not lose annotations** as the original `sortann` does, and it **never
writes over a file it is reading**. They are deliberate,
the same in all six implementations, and tested like everything else: the
reference results of the conformance suite come from the C package with
[`tests/reference/divergences.patch`](../tests/reference/divergences.patch)
applied (see [`tests/reference/build_reference.sh`](../tests/reference/build_reference.sh)).
The patch is the precise definition of the divergences; this page explains
them. The original behavior remains available in all cases, on request (see
[Legacy mode](#legacy-mode)).

These design decisions were made by Reza Sameni in 2026 (the last
four after code reviews), for the reasons below. Each source file affected
by them says so in its header.

## No built-in sampling frequency, gain, ADC resolution or units

### Why

The C package falls back on built-in values for four parameters of a
signal whenever a record or the user does not give them:

| Parameter | Built-in value in C | Where it came from |
|---|---|---|
| sampling frequency | 250 Hz (`WFDB_DEFFREQ`), 500 Hz in `parsescp` | the AHA database (250 Hz) |
| gain | 200 adu/mV (`WFDB_DEFGAIN`); 400 adu/mV for AHA files; 12.5 or 6400 adu/mV for WAV files | the MIT-BIH and AHA digitizers |
| ADC resolution | 12 bits (`WFDB_DEFRES`), or the storage width of the format | the 12-bit digitizers of these databases |
| units | millivolts | ECG |

These values describe the equipment with which the first PhysioNet
databases were recorded, in the 1970s and 1980s, and they made sense for
a package built around those databases. They do not describe modern
recordings: today's acquisition systems sample at anything from a few hertz
to tens of kilohertz, with gains, resolutions (often 16 or 24 bits) and
units that depend on the device and on the signal, which is often not an
ECG at all.

A silent default is worse than an error. Every time, duration, interval,
resampled signal and physical value computed from a wrong default is wrong,
the error propagates to every file and result derived from it, and nothing
in the output says that a value was assumed. wfdb-x therefore never assumes
any of these four parameters: it uses the values given in the record, or
values given explicitly by the user, and reports an error when an operation
needs a value that is not available. Where an output must still show a
missing unit, it shows `nd` ("not defined", a notation the C package
already used for empty units) rather than `mV`.

The only exception is `parsescp`, whose internal processing is defined for
its own output: it writes a gain of 200 adu/mV because it rescales the SCP
samples to units of 5 µV, so that value is exact, not assumed.

### Reproducing the results of the original package

To obtain the results of the original WFDB tools, give the values they
assumed — explicitly. Nothing is defaulted internally.

| Tool | Values to give |
|---|---|
| `wrsamp` (writing a record, `-o`) | `-F 250 -G 200 -U mV`, and `-R` with the storage width of the output format (`-R 12` for format 212, `-R 16` for 16, 61, 160 and 516, `-R 8` for 8, 80 and 508, `-R 10` for 310 and 311, `-R 24` for 24 and 524, `-R 32` for 32) |
| `wav2mit` | `-G 12.5 -U mV` for 8-bit files, `-G 6400 -U mV` for 16-bit files (the frequency and resolution are those in the WAV file) |
| `ad2m` | `-F 250 -G 400 -R 12 -U mV` (the AHA database) |
| `ahaecg2mit` | `-F 250 -G 400 -R 12 -U mV` (the AHA database) |
| `a2m`, `rr2ann`, `rdann`, `ann2rr`, `sortann`, `m2a`, for a record without a header (or without a frequency in its header) | `-F 250` |
| `xform` (interactive) | the ADC resolution that C offered: the storage width of the output format, or 12 bits for 16-bit formats |
| library | `setsampfreq(250)` before opening a record whose header gives no frequency |

The output then contains the same samples, times and values as the
original. One difference remains by construction: a header written with
`-U mV` says `200/mV` where the C tools wrote `200` and left millivolts to be
assumed.

### What changes, in detail

**Library**

* A header that does not give a sampling frequency leaves it unspecified:
  `sampfreq` returns 0 (C: 250), unless the caller has set one with
  `setsampfreq` before opening the record (as in C).
* A header that does not give an ADC resolution leaves it unspecified (0);
  C inferred it from the format or assumed 12 bits. Missing units remain
  unspecified (`NULL`), as in C, but are never taken to be millivolts.
* Time conversions that need the frequency fail when it is unspecified:
  `strtim` reports "sampling frequency is not specified" and returns 0 for
  time strings other than sample numbers (`s...`), `e`, `i` and `o`;
  `timstr` and `mstimstr` report the same error and return the time as a
  sample number (`s` followed by the number). (C: 1 sample per second.)
  The new function `wfdbx_time_needs_freq(string)` tells whether `strtim`
  needs the frequency for a given string.
* `setifreq` fails if the input frequency is unspecified.
* `aduphys`, `physadu`, `adumuv` and `muvadu` fail for an uncalibrated
  signal (gain 0) or an invalid signal number: they report the error and
  return NaN (`aduphys`) or `WFDB_INVALID_SAMPLE` (the others). (C: gain
  200, and baseline 0 for invalid signal numbers.)
* The constants `WFDB_DEFFREQ`, `WFDB_DEFGAIN` and `WFDB_DEFRES` remain
  defined, for compatibility, but the library does not use them.

**Tools.** A tool that writes these parameters into a record requires them;
a tool that needs a parameter missing from its input stops with an error
only when the requested operation needs it:

| Tool | Behavior |
|---|---|
| `wrsamp` | `-F`, `-G` and the new `-R BITS` are required when a record is written (`-o`), and the new `-U UNITS` for calibrated signals unless the input gives the units; `-G 0` declares the signals uncalibrated. `-G`, `-R` and `-U` take one value per signal (the last applies to the rest) |
| `wav2mit` | new `-G GAIN` (required) and `-U UNITS` (required unless the gain is 0) |
| `ad2m`, `ahaecg2mit` | new `-F FREQ`, `-G GAIN`, `-R BITS` and `-U UNITS`, all required (`-U` unless the gain is 0); `ahaecg2mit` locates the short-format part of a long-format file from `-F` |
| `a2m`, `rr2ann`, `rdann`, `ann2rr`, `sortann`, `m2a` | `-F FREQ` (new except in `rr2ann`), used if the record has no header or the header has no frequency, and required then when times are converted (always for `a2m` and `rdann`; for time arguments and time output formats in `ann2rr` and `sortann`; for `-s` in `m2a`) |
| `a2m` | converts annotation times given in milliseconds (AHA file types 1 to 3) at the record's sampling frequency; C assumed 4 ms per sample (250 Hz) whatever the record's frequency |
| `rdsamp` | needs the frequency for time arguments, time columns (`-p` without `-pS`, or with `-v`) and XML output (`-X`), and the gain of each selected signal for physical units (`-p`); unspecified units are shown as `nd` |
| `sigamp` | needs the frequency (its measurement windows are in seconds), and the gains for `-p` |
| `snip`, `wfdb2mat`, `mit2wav`, `wfdbtime` | need the frequency |
| `xform` | needs the frequency; refuses an output frequency of 0, rescaling an uncalibrated signal to a given gain, and rescaling by ADC resolution when a resolution is unspecified; offers an ADC resolution only if it comes from the input (or the previous output signal) and suits the output format, and stops if none is given |
| `mit2edf` | needs the frequency, and the gain and ADC resolution of every signal (an EDF file stores physical and digital ranges); unspecified units are written as `nd` |
| `wfdbdesc` | prints "not specified" for an unspecified frequency (with lengths in sample intervals only) and ADC resolution, "uncalibrated" for gain 0 (C: "uncalibrated; assume 200"), and `adu/nd` for unspecified units |
| `wfdb2mat` | uncalibrated signals stay uncalibrated in the output header (C: 200 adu/mV); unspecified units are written as `nd` (C: `mV`) |
| `revise` | a missing ADC resolution stays unspecified (C: 12 bits) |
| `sampfreq` | prints 0 for a record whose header does not give a frequency (C: 250) |
| `parsescp` | writes the sampling frequency given in the SCP file (C always wrote 500 Hz) and does not write a record if the file gives none (C assumed 500 Hz) |

The messages are "`TOOL: sampling frequency of record RECORD is not
specified`" (followed by "` (use -F)`" for the tools that have that option),
"`TOOL: signal N of record RECORD is uncalibrated`", "`TOOL: ADC resolution
of signal N of record RECORD is not specified`", and "`TOOL: the ... must be
specified (-X)`" for a missing required option.

**High-level API** (`read_record`, `read_annotations`, `write_record`, in
every language):

* `write_record` requires the sampling frequency (> 0), the gains, the ADC
  resolutions, and the units of the calibrated signals; there are no
  defaults. A gain of 0 declares a signal uncalibrated, which is allowed
  only for samples given in ADC units.
* `read_record` reports an unspecified frequency as 0 and fails for time
  strings that need it; with physical units, it fails if a selected signal
  is uncalibrated. Unspecified ADC resolutions are reported as 0 and
  unspecified units as missing.
* `read_annotations` takes an optional sampling frequency, used (like the
  `-F` option of the tools) when the record has no header or its header
  does not give one; without one, its result reports a frequency of 0, and
  time strings that need the frequency fail.

### What does not change

* Values defined by a data format, not by an assumption about the signal:
  the record lengths and time offsets of the AHA database formats (35
  minutes, 3 hours, 5:00 and 2:30:00), and `md2a`'s default length.
* Values read from the input: the sampling frequency and resolution of a
  WAV file, and the parameters of an EDF file.
* Analysis settings that are documented options, such as the measurement
  windows of `sigamp`.

## Files are found only where they are named

### Why

The C library finds a file by searching the **WFDB path**: a list of
locations, tried in order until the file is found. Its default is
`. /usr/local/database http://physionet.org/physiobank/database`: the
current directory, an installation directory and, in builds with network
support (libcurl), PhysioNet. `rdsamp -r 100` therefore reads `100` from
whichever of these places has it first, and fetches it from PhysioNet if no
local copy exists. That was convenient, but fragile, and it caused problems
that are easy to miss:

* **Wrong files, silently.** A search opens the first copy it finds. A
  stale or partial copy of a record in the current directory, or in a
  directory earlier on the path, is read instead of the intended one, and
  nothing says so. A signal file missing next to its header is replaced by a
  file of the same name found anywhere else on the path.
* **Silent failures and silent network access.** Whether a record is read
  from disk or downloaded, and from where, depends on the environment (the
  `WFDB` variable, the current directory, network availability), not on the
  code. The same script can read different data on two machines, and a
  missing local file turns into a network request instead of an error.
* **Privacy.** For every record it reads, the library also looks for an
  optional `.info` file and, when there is no local one, asks the last
  entry of the path, PhysioNet, for it. An absolute record name is joined
  to the URL as it is, so the request contains the full local path
  (`GET /physiobank/database//Users/.../rec.info`); a missing header is
  requested in the same way. (In wfdb-x, only the Python implementation had
  network support, like a C build with libcurl; the other five, and the
  reference build, had none.)
* **Security.** A header names its signal files, and the library opened
  those names wherever they pointed. A downloaded or crafted header could
  make it read other local files (`../../.ssh/id_rsa`) or contact a
  third-party server.
* **Outdated defaults.** The default URL is no longer where PhysioNet serves
  its files (`https://physionet.org/files/<database>/<version>/`).

### What wfdb-x does instead

A name says exactly where the file is, and nothing else is tried:

| The name is | Read from | Written to |
|---|---|---|
| an absolute path: `/data/100`, `C:\data\100`, `\\server\share\100` | that path | that path |
| a home path: `~/data/100`, `~user/data/100` | the home directory (expanded by wfdb-x) | the same |
| a URL: `https://.../100` | that URL, if network access is on | (not possible) |
| anything else: `100`, `mitdb/100`, `../other/100` | the **input directory** + the name | the **output directory** + the name |

**Whatever is set as the input directory, a local directory or a URL,
prefixes every relative name that is read; the output directory prefixes
every relative name that is written.** Both default to the current
directory. A name given as a full path (`/Users/...`), a `~` path or a URL
is used as given. Nothing is ever searched.

| Setting | Function | Environment variable | Default |
|---|---|---|---|
| input directory (a directory, `~...`, or a URL) | `wfdbx_set_input_dir`, `wfdbx_get_input_dir` | `WFDBX_INPUT_DIR` | the current directory |
| output directory (local) | `wfdbx_set_output_dir`, `wfdbx_get_output_dir` | `WFDBX_OUTPUT_DIR` | the current directory |
| network access | `wfdbx_set_network`, `wfdbx_get_network` | `WFDBX_NETWORK=1` | off |

A function call overrides the environment variable. The high-level
functions take the same settings as options (`input_dir`, `network`, and
`dir` for the output directory), which apply for the duration of the call.
The tools use the environment variables.

* **Files named in a header** (signal files, and the segments of a
  multi-segment record) are found **relative to the header**, as they are
  written in it (`100.dat`, or `data/100.dat`), on disk or at the header's
  URL. That is where the original looked first; the difference is that a
  file missing there is an error instead of a search elsewhere. Such a name
  must stay inside the header's directory: a header that names a file with
  `..`, an absolute path, a `~` path or a URL is rejected (`init: file ...
  named in the header of record ... is not in the header's directory`).
  The null segment `~` of multi-segment records keeps its meaning.
* **Network access is off by default.** A URL is opened only when it has
  been turned on (`wfdbx_set_network(1)`, `WFDBX_NETWORK=1`, or the
  `network` option); otherwise the library says once that network access is
  disabled. All six implementations can read URLs (C++ and Rust through the
  system `curl` program, which they run without a shell; a missing `curl`
  is reported when a URL is opened). Remote files are read-only.
* **`..`** means one level up, from the input or output directory, in names
  given by the user (the original refused every name containing `..`).
* **`setwfdb` and `getwfdb`** set and return the input directory: `setwfdb`
  accepts a single directory (as `setwfdb(".")`), and a path of several
  entries is an error that points to `wfdbx_set_input_dir`. The `WFDB`
  environment variable is used only in legacy mode; when it is set, the
  library says once that it is ignored.

### The cost: PhysioNet is chosen explicitly

Reading PhysioNet records now has to be asked for, by setting the input
directory to the database's URL and turning network access on:

```python
wfdbx.wfdbx_set_network(1)
wfdbx.wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
rec = wfdbx.read_record("100")
```

(or `WFDBX_NETWORK=1 WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/
rdsamp -r 100` with the tools). `rdsamp -r 100` alone reads `./100` and
nothing else. A script that relied on the WFDB search path, for example on
`WFDB=". /data/mitdb /data/nsrdb"`, has to name its directories instead.
In return, every program reads exactly the files it names, the same on
every machine, and never contacts a server it was not told to contact.

In legacy mode, the WFDB search path works as in the original reference
build, which has no network support: `WFDB`, the default path, `%r`
substitution, `@file` indirect paths, absolute names joined to the path
entries, and names containing `..` refused; URLs are not opened.

## Out-of-order annotation files are sorted in-process

When an annotation file written by the library is not in time order, the C
library sorts it when the file is closed by running the `sortann` program
(`system("sortann -r. REC -a ANN")`), unless the environment variable
`WFDBANNSORT` is 0. That makes the result depend on which `sortann`, if
any, is found on the `PATH`, starts a separate process from inside a
library, and passes the record and annotator names through a shell
unquoted, so a name with a space or a shell character breaks it.

wfdb-x sorts the file itself, in the same process. The file it writes is
byte-for-byte the one `sortann` writes (except where the original loses
annotations; see the next section): the same order (by time, then
annotation number, then channel; a later annotation with the same time,
number and channel replaces the earlier one), the same treatment of
`NOTQRS` annotations (they are dropped) and of the time resolution, and the
same encoding. The messages and the status of the library are the same
(`Rearranging annotations for output annotator ANN ...done!`, or the
`Use the command: sortann ...` advice when sorting is disabled or fails),
except that the messages the separate `sortann` printed itself are gone:
for a record without a header, for example, the original printed `init:
can't open header for record REC` in the middle of that line, because
`sortann` looked the header up. `WFDBANNSORT=0` still turns sorting off.

In legacy mode the library runs `sortann`, as the original does, with one
change: the program is started without a shell, its arguments passed
directly (the MATLAB/Octave and R implementations, which can start programs
only through a shell, quote them instead). Without a shell, a `sortann`
that cannot be found is reported only by the library's own messages
(`Annotations still need to be rearranged.` and the `Use the command: ...`
advice); the shell's `sortann: not found` line is gone. When the library
writes into an output directory (see [Additions](#additions)), the program
is run in that directory, so that it finds the file.

## Sorting does not lose annotations

The original `sortann` silently loses annotations (see
[`KNOWN_C_BEHAVIORS.md`](KNOWN_C_BEHAVIORS.md)): when an annotation at time
0, with annotation number 0 and channel 0, arrives after later ones, it is
dropped, and so are the annotations later inserted directly behind it
(input sample times 5, 0, 3 give a file containing only 5). The search for the
insertion point mistakes the list's empty head entry for an annotation at
that location. The same happens when the library sorts a file it wrote,
since it runs `sortann`.

wfdb-x never compares the head entry with an annotation, so such an
annotation is put at the beginning of the list, where it belongs (5, 0, 3
give 0, 3, 5). Nothing else about the sorting changes: the order, the
replacement of an annotation by a later one at the same time, number and
channel, the dropping of `NOTQRS` annotations, and the messages are those
of the original. This applies to the `sortann` tool and to the library's
automatic sorting.

In legacy mode, both lose these annotations as the original does. **Do not
use legacy mode to sort annotation files** unless reproducing the
original's results, losses included, is the point: nothing in the output
says that annotations were dropped.

## An output file is never one of the input files

A record's files can be shared: the segments of a multi-segment record are
other records, so `xform -i vlay -o fmt16` reads `fmt16.dat` (a segment of
`vlay`) and writes `fmt16.dat` (the output record `fmt16`), although the
two record names differ. The original opens the output file, which
truncates it, while still reading it: the input is destroyed, and what is
read depends on how much of it the C library had read ahead (on glibc,
4096-byte blocks), so the result differs between platforms.

wfdb-x refuses to create an output signal file that is the same file as a
signal file of the record open for reading (the same file, not the same
name: links and different spellings of a path are recognized), with the
message `osigfopen: output file NAME is also an input file`; nothing is
written. Every tool and high-level writer is protected, since the check is
in the library, and the behavior is identical in all six implementations
(it is part of the conformance suite). Legacy mode does not check, as the
original.

## Additions

These are new features, not changes of the original behavior, so they
have no legacy counterpart:

* **An output directory for the high-level writers.** `write_record` and
  `write_annotations` take an output directory (`dir`). The files are
  created there, and the header names the record and its signal file
  without the directory, so the record opens from that directory under its
  plain name. With the C library (and wfdb-x's C-style API and tools,
  which follow it), writing to another directory means giving a record
  name such as `out/rec`, which the header then records as `out/rec`, so
  the record cannot be opened from inside `out/`; the alternative,
  changing the current directory, is not safe in a multi-threaded program.
  The library functions `wfdbx_set_output_dir(dir)` (returns the previous
  setting) and `wfdbx_get_output_dir()` set and return the directory in
  which output files are created; the high-level functions set it for the
  duration of the call.
* **Faster writing in Python** (and in the other implementations where
  writing was slow): `write_record` writes whole arrays at once instead of
  frame by frame, producing exactly the same files.
* **Read errors in the high-level readers.** `read_record` and the other
  high-level readers raise an error (`can't read signal data of record REC
  (getvec status S)`) when a signal file ends before the length its header
  gives, or cannot be read, instead of returning the samples read so far as
  if the record ended there. A checksum error (all samples read, but their
  sum differs from the header's checksum) is a warning instead: every frame
  is returned, the last one included (the C-style `getvec` reports the
  error on that frame, and `rdsamp` stops before printing it), with the
  warning `checksum error in record REC: the signal data do not match the
  checksums in its header` in each language's usual way (Python `warnings`,
  R `warning()`, Julia `@warn`, MATLAB/Octave `warning()`, the standard
  error in C++ and Rust). The `checksum_warning` option turns it off. Both
  behave identically in all six implementations. The C-style functions
  and the tools report these as the original does.

## Legacy mode

For compatibility, the C reference (with
[`divergences.patch`](../tests/reference/divergences.patch)) can also behave
exactly as the original package, on request; the default is the behavior
described above.

* **Tools.** `--legacy` as the *first* argument of any of the tools
  (`rdsamp --legacy -r 100s -t 10`, `rdann --legacy -r 100s -a atr`, ...) is
  removed before the options are parsed, and the tool then behaves exactly
  as the original one: same options (the options added by wfdb-x, such as
  `-F` in `rdann` or `-R` in `wrsamp`, are unrecognized), outputs, messages,
  help texts and exit statuses. `--legacy` anywhere else is not recognized.
* **Library.** `wfdbx_set_legacy(1)` turns legacy mode on and
  `wfdbx_set_legacy(0)` off (each returns the previous setting), and
  `wfdbx_get_legacy()` returns the current one; `wfdbx_legacy_args(&argc,
  &argv)` is the function the tools call to recognize and remove `--legacy`.
  In legacy mode, every library divergence listed above behaves as in the
  original: a header without a frequency means 250 Hz, a missing ADC
  resolution is inferred from the format or taken as 12 bits, the time
  conversions use 1 sample per second when no frequency is known, `setifreq`
  reports "no open input record", the unit conversions assume a gain of
  200 (and a baseline of 0 for invalid signal numbers), files are found
  through the WFDB search path (without network access), out-of-order
  annotation files are sorted by running `sortann` (without a shell), which
  loses annotations as the original does, and an output file may be one of
  the input files.
* **High-level API** (an addition of wfdb-x, not part of the C package).
  `read_record`, `read_header`, `read_annotations`, `write_record` and the
  related functions of each language take a legacy option. They behave as
  wfdb-x's high-level API did before the redesign when the option is set
  or when the library is in legacy mode (`wfdbx_set_legacy(1)`). With the
  option, the library's legacy mode is on during the call, and the previous
  setting is restored afterwards. In that mode, `write_record` uses a gain
  of 200 and units are optional. Its default ADC resolution is the storage
  width of the format (8 bits for formats 80 and 508, 10 for 310 and 311,
  12 for 212, 24 for 24 and 524, 32 for 32), and 16 bits for every other
  format. That differs from `wrsamp --legacy` only for format 8, which
  gets 12 bits there, as in the original `wrsamp`.

Legacy mode reproduces the original package exactly, and it is tested
against its results: the legacy suite of the conformance tests
([`tests/conformance/legacy`](../tests/conformance/legacy), 868 cases, run
with `harness.py check --legacy`) runs the original package's cases with
`--legacy` and compares them with results produced by the unmodified C
package, and the library's legacy values are checked in
[`tests/reference/api_expect.c`](../tests/reference/api_expect.c).

It is kept for compatibility only. The values it assumes are exactly the
silent defaults this project removed, so results produced with it carry the
same risks: any time, interval, resampled signal or physical value computed
from an assumed frequency, gain, resolution or unit is wrong if the
assumption is, and nothing in the output says so.
