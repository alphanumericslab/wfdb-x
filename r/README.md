# wfdb-x for R

The R package `wfdbx` is the R implementation of wfdb-x, a reimplementation
of the WFDB Software Package 10.7.0: the WFDB library and its command-line
tools. It reads and writes the same files as the original C library, and its
tools produce byte-identical output (checked by the wfdb-x conformance
suite), with the deliberate exceptions listed in
[docs/DIVERGENCES.md](../docs/DIVERGENCES.md). See the [project README](../README.md) for
the overall design, and [DEVELOPING.md](DEVELOPING.md) for the
implementation notes.

* R 4.1 or later, **base R only**: no package dependencies, nothing to
  compile.
* Linux and macOS (Windows: see [Limitations](#limitations)).

## Installation

From a clone of the repository:

```sh
R CMD INSTALL r
```

or, from R (with the path of the `r/` directory):

```r
install.packages("r", repos = NULL, type = "source")
library(wfdbx)
```

## Command-line tools

The tools are run with the driver script `wfdbx.R`, from the source tree (no
installation needed) or from the installed package:

```sh
Rscript r/inst/bin/wfdbx.R TOOL [ARGUMENTS ...]
Rscript r/inst/bin/wfdbx.R --list                 # list the tools
Rscript "$(Rscript -e 'cat(system.file("bin", "wfdbx.R", package = "wfdbx"))')" wfdbwhich hea 100s
```

A shell alias makes this convenient:

```sh
alias wfdbx='Rscript /path/to/wfdb-x/r/inst/bin/wfdbx.R'
wfdbx rdsamp -r 100s -t 10 -p
```

From the source tree, the driver caches the loaded and byte-compiled sources
in `$XDG_CACHE_HOME/R/wfdbx/` (by default `~/.cache/R/wfdbx/`), so that a
tool starts in about the time of `Rscript` itself. The cache is rebuilt when
a source file changes; set `WFDBX_NO_CACHE=1` to disable it.

From R, a tool is called with its arguments as a character vector, and
returns its exit status:

```r
wfdbx_tool("wfdbdesc", "100s")
wfdbx_tools()                                     # the available tools
```

All the tools of the WFDB Software Package that wfdb-x reimplements are
available: `rdsamp`, `wrsamp`, `rdann`, `wrann`, `sortann`, `ann2rr`,
`rr2ann`, `wfdbdesc`, `wfdbtime`, `time2sec`, `sampfreq`, `signame`,
`signum`, `sigamp`, `snip`, `xform`, `wfdbcat`, `wfdbwhich`, and the format
converters `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
`wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
`revise`, `parsescp`.

The tools never assume a sampling frequency, gain, ADC resolution or units:
see [No built-in signal parameters](#no-built-in-signal-parameters).

## No built-in signal parameters

The original package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits) and units (millivolts) whenever a
record or the user does not give them. These values describe the equipment
of the first PhysioNet databases, not modern recordings, and a silently
assumed value corrupts every time, duration, resampled signal and physical
value derived from it, with nothing in the output to show it. wfdb-x
therefore never assumes them: tools that write them require them, and an
operation that needs a value missing from a record stops with an error
("sampling frequency of record R is not specified", "signal N of record R
is uncalibrated", "ADC resolution of signal N of record R is not
specified") instead of guessing. This deliberate divergence, the same in
every wfdb-x implementation, is described in
[docs/DIVERGENCES.md](../docs/DIVERGENCES.md).

New or now required options:

* `wrsamp`: with `-o`, `-F FREQ`, `-G GAIN` and the new `-R BITS` (ADC
  resolution) are required, and the new `-U UNITS` is required for
  calibrated signals unless the input's second line gives the units (`-G`,
  `-R` and `-U` take a quoted list, one value per signal, the last value
  applying to the remaining signals; `-G 0` declares the signals
  uncalibrated).
* `wav2mit`: new required `-G GAIN` (0: uncalibrated) and `-U UNITS` (unless
  the gain is 0); the frequency and resolution come from the WAV file.
* `ad2m` and `ahaecg2mit`: new required `-F FREQ`, `-G GAIN`, `-R BITS` and
  `-U UNITS` (unless the gain is 0); the options of `ahaecg2mit` precede the
  input files.
* `a2m`: new `-F FREQ`, used when the record header gives no frequency;
  annotation times in milliseconds are converted at the record's frequency
  (C assumed 4 ms per sample).
* `rdann`, `ann2rr`, `sortann` and `m2a`: new `-F FREQ`, used when the record
  has no header or its header gives no frequency.
* `mit2edf` stops if the frequency, a gain or an ADC resolution is not
  specified; `xform` asks for an ADC resolution it cannot take from the
  input; unspecified units are shown as `nd` (by `rdsamp -v`, `wfdbdesc`,
  `wfdb2mat`, `mit2edf` and `xform`), and an unspecified ADC resolution as 0
  (`wfdbdesc`: "not specified").

To reproduce the results of the original tools, give the values they
assumed explicitly, for example:

```sh
wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -o rec -i samples.txt
wfdbx ad2m -F 250 -G 400 -R 12 -U mV -i 1201.dat -r 1201
wfdbx ahaecg2mit -F 250 -G 400 -R 12 -U mV 1201.ecg
wfdbx wav2mit -G 6400 -U mV -i sound.wav     # 16-bit; 12.5 for 8-bit files
wfdbx a2m -F 250 -i 1201.ANO
```

### Legacy mode

The original behavior remains available on request. `--legacy` as the
*first* argument of any tool (`wfdbx rdsamp --legacy -r 100s -t 10`) makes
it behave exactly as the original one: same options (those added by wfdb-x,
such as `-F` in `rdann` or `-R` in `wrsamp`, are unrecognized), outputs,
messages, help texts and exit statuses. In R, `wfdbx_set_legacy(TRUE)` turns
the library's legacy mode on (it returns the previous setting;
`wfdbx_get_legacy()` gives the current one), and the high-level functions
take `legacy = TRUE` for a single call (for example, `write_record` then
defaults to a gain of 200 and a resolution based on the format, and
`read_record` converts uncalibrated signals with a gain of 200). Legacy mode
reproduces the original package exactly, and is tested against its results
(the legacy conformance suite, `harness.py check --legacy`). It is kept for
compatibility only: the values it assumes are exactly the silent defaults
this project removed, so results produced with it carry the same risks.

## High-level API

```r
rec <- read_record("100s", sampto = 1000, physical = TRUE)
dim(rec$signals)                         # 1000 2
rec$names                                # "MLII" "V5"
write_record("copy", rec$signals, rec$fs, gains = rec$gains, physical = TRUE,
             adcres = 11, units = "mV", names = rec$names)

a <- read_annotations("100s", "atr")     # sample, symbol, code, ..., aux
a[a$symbol == "A", ]                     # the atrial premature beats
write_annotations("100s", "cpy", a)
```

`read_record` also takes `channels` (numbers or names), `sampfrom` and
`sampto` (sample numbers or time strings), `highres` and `pad`;
`read_header` returns the signal information of a record.
`read_record` stops with the error "can't read signal data of record REC
(getvec status S)" when reading stops with a getvec status below -1, e.g. -3
for a signal file shorter than its header says, instead of returning the
samples read so far; reaching the end of the record is not an error. This
applies in legacy mode too, since the high-level API is a wfdb-x addition
(`getvec`, `getframes` and the tools are unchanged).
A checksum error (getvec status -4: the samples are complete, but their sum
does not match the checksums in the header) is not an error: `read_record`
returns every frame, the last one included, and warns with
`warning("checksum error in record REC: the signal data do not match the
checksums in its header")` (`checksum_warning = FALSE` turns the warning
off; getvec's own "getvec: checksum error in signal N" is not printed
during the read). The behavior is identical in all six implementations.

The library never creates an output signal file that is one of the files
of the open input record (wfdb-x): `osigfopen`/`osigopen` (and so every
tool and `write_record`) refuse it, with "osigfopen: output file NAME is
also an input file" (`osigopen: ...`) and status -3, leaving the input
intact, e.g. `xform -i vlay -o fmt16` where `fmt16` is a segment of `vlay`
(the original truncated the file it was reading, `xform: can't write output
signals (osigopen: output file fmt16.dat is also an input file)` now). The
files are compared, not their names (other spellings, symbolic and hard
links, the signal files of every segment of a multi-segment record); in R,
which has no inode numbers, by normalized paths and, for files of equal
size and modification time, the device and inode numbers given by the
`stat` program. Legacy mode does not check. The behavior is identical in
all six implementations.

There is no default sampling frequency, gain, ADC resolution or units:
`write_record` requires `fs` (> 0), `gains` (a gain of 0 declares a signal
uncalibrated, which is allowed only for samples in ADC units), `adcres`
(>= 1; "ADC resolution(s) must be specified") and the `units` of every
signal whose gain is not 0 ("units must be specified"); `read_record`
returns `fs = 0` for a record whose header gives no frequency, an ADC
resolution of 0 (`siginfo[[k]]$adcres`) and `NULL` units for signals whose
header lines give none (never millivolts), and fails for time strings
that need it (`wfdbx_time_needs_freq()` tells which do) and for physical
units of an uncalibrated signal; `read_annotations(..., fs = FREQ)` gives
the frequency to use when the record has no header or its header gives
none. The library functions `strtim`, `timstr`, `mstimstr`, `setifreq`,
`aduphys`, `physadu`, `adumuv` and `muvadu` report an error instead of
assuming a value (see `?strtim` and `?aduphys`). See
`?read_record`, `?read_annotations` and the package overview, `?wfdbx`.

## Finding records and files

Every relative name is read under the input directory and written under the
output directory -- whatever you set as the input directory, a local
directory or a URL, prefixes it; a name given as a full path (`/Users/...`),
a `~` path or a URL is used as given; nothing else is searched. (The
original library searched the directories of the WFDB path, and possibly
`http://physionet.org/physiobank/database`: a search can silently open the
wrong file, such as a stale copy earlier in the path, and fails in ways
nobody notices; wfdb-x tries exactly one location.) Relative names may
contain directories and `..` (`"mitdb/100"`, `"../data/100"`).

| Setting | R | Environment variable | Default |
|---|---|---|---|
| input directory (a directory, a `~` path or a URL) | `wfdbx_set_input_dir(d)` (returns the previous one), `wfdbx_get_input_dir()`; `input_dir =` of the readers | `WFDBX_INPUT_DIR` | none: the current directory |
| output directory (local) | `wfdbx_set_output_dir(d)`, `wfdbx_get_output_dir()`; `dir =` of the writers | `WFDBX_OUTPUT_DIR` | none: the current directory |
| network access | `wfdbx_set_network(1)` (returns the previous setting), `wfdbx_get_network()`; `network =` of the readers | `WFDBX_NETWORK` (a non-zero number: on) | off |

A function call overrides the environment variable (read when the setting
is first needed); `NULL` (or `""`; for the network, `NULL` or a negative
number) restores the default, i.e. the environment variable's value if it is
set. A relative or `~` directory is used relative to the current directory
(or expanded) when a file is opened. The high-level readers (`read_record`,
`read_header`, `read_annotations`) set `input_dir` and `network` for the
duration of the call only (and restore the previous values, also on
errors); `NULL` keeps the current setting.

**PhysioNet.** The files of a PhysioNet database are under
`https://physionet.org/files/<database>/<version>/`. Reading from it is an
explicit choice -- wfdb-x never contacts a server unless network access is
on:

```r
wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
wfdbx_set_network(1)
rec <- read_record("100", sampto = "0:10", physical = TRUE)
# or, for one call:
rec <- read_record("100", input_dir = "https://physionet.org/files/mitdb/1.0.0/",
                   network = TRUE)
```

```sh
WFDBX_NETWORK=1 WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/ wfdbx rdsamp -r 100 -t 0:5
```

Remote files are read by the system program `curl` (or with base R's
`url()` if there is none), in full, and kept for the rest of the process (each URL is requested at most once;
redirects are followed, an HTTP status of 400 or more is a failure, and
reading gives up if connecting takes 30 s or no data arrives for 30 s, with
no limit on the total time). They are read-only: a URL cannot be written, nor be the output
directory. With network access off, a URL is not opened, and the first
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
`getwfdb()` returns the input directory, or `"."` if none is
set; `resetwfdb()` restores the value set by the last `setwfdb`
(`wfdbquit()` leaves the settings as they are). The `WFDB` environment
variable is not used: if it is set, the first lookup prints `wfdb-x: the
WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use
legacy mode)`.

**Legacy mode** (`--legacy`, `wfdbx_set_legacy(TRUE)`, `legacy = TRUE`)
keeps the original search of the WFDB path (`WFDB`, `setwfdb` with several
entries, `@file` paths, `%r`, names containing `..` refused), without any
network access (as the reference C build, compiled without network support:
URL names and URL path entries are not opened). The input directory and
`WFDBX_NETWORK` are not used in legacy mode; the output directory is.

### Output directory and annotation order

**Output directory.** `write_record(..., dir = "out")` and
`write_annotations(..., dir = "out")` create their files in the directory
`out` (which must exist: otherwise an error, "directory out does not
exist"), and the header names the record and its signal file without the
directory (`rec 2 360 ...`, `rec.dat ...`), so that the record opens from
that directory under its plain name (`setwfdb("out")`, then
`read_record("rec")`; or `read_record("out/rec")`). The record name must not
contain a directory when `dir` is given ("record name must not contain a
directory when dir is given"). In the library API,
`wfdbx_set_output_dir("out")` makes every output file be created in `out`
(it returns the previous directory; `wfdbx_set_output_dir(NULL)` restores
the default, files created as named, and `wfdbx_get_output_dir()` returns
the current one); the writers set it for the duration of the call (and
restore it, also on errors). The C-style API and the tools are otherwise
unchanged: `newheader("out/rec")` and `wfdbx wrsamp -o out/rec` still record
the name `out/rec`, as in C.

**Annotation order.** Annotations written out of canonical order (by time,
then `num`, then `chan`) are rearranged when the file is closed, in the same
R process, with a result identical byte for byte to that of `sortann` (the
last of several annotations with the same time, `num` and `chan` is kept,
and `NOTQRS` annotations are dropped); `WFDBANNSORT=0` disables it. Unlike
the original `sortann`, neither the sort nor the `sortann` tool loses an
out-of-order annotation at time 0 (written after later ones), nor those
inserted after it. The C library ran the `sortann` program (found in the
`PATH`), as legacy mode does (running the R `sortann` tool, `Rscript
.../wfdbx.R sortann --legacy`, in a new process, in the output directory if
one is set), with the original loss; base R cannot run a program without a
shell, so its arguments are quoted for the shell.

## C library API

The functions of the C library keep their C names and semantics (see the
[WFDB Programmer's Guide](https://physionet.org/physiotools/wpg/)), with
these conventions:

* **Numbers are doubles** (sample values, times, counts); C wrap-around is
  reproduced where C has it. Signal, group and annotator numbers are
  0-based, as in C.
* **Strings**: record names, file types, time strings and the strings of
  the C structures are character strings; byte data (annotation `aux`
  strings) are raw vectors. C `NULL` is `NULL`.
* **Structures** are lists with the C field names, made by `siginfo()`,
  `anninfo()`, `annotation()`, `calinfo()` and `seginfo()`.
* **Output arguments**: functions that fill arrays supplied by the caller
  in C return them instead: `isigopen` returns `list(nsig, si)`, `getvec`
  and `getframe` return `list(stat, v)`, `getann` returns
  `list(stat, annot)`, and so on (see the help pages).
* **`sample`** is exported as `wfdb_sample`, so as not to mask
  `base::sample`.
* Annotation codes are constants (`NORMAL`, `PVC`, ...; `ecgcodes()` lists
  them), and the mapping functions of `<wfdb/ecgmap.h>` (`isqrs`, `map1`,
  `map2`, `ammap`, `mamap`, `annpos`, ...) are vectorized.

Besides the C functions, `getframes(n)` reads up to `n` sample vectors at
once (a matrix, exactly what `n` calls of `getvec` return), and
`putframes(m)` writes the rows of a matrix (as `putvec` on each row).

```r
r <- isigopen("100s", 2)                 # r$nsig, r$si
x <- getframes(Inf)$v                    # all the samples (ADC units)
isigsettime(strtim("0:30"))
v <- getvec()$v
wfdbquit()

annopen("100s", list(anninfo("atr", WFDB_READ)))
while ((g <- getann(0))$stat == 0)
  if (g$annot$anntyp == APC) cat(mstimstr(g$annot$time), "\n")
wfdbquit()
```

The help pages (`?isigopen`, `?annopen`, `?getwfdb`, `?calopen`,
`?strtim`, ...) list the functions of each part of the library.

## FLAC-compressed signals

Formats 508, 516 and 524 are supported in pure R, without libFLAC. Files
written by the C library are read exactly. Files written by wfdb-x are
standard FLAC streams that the C library reads back with identical sample
values; their bytes are those written by the Python implementation of
wfdb-x, not those of libFLAC (whose output depends on its version).

## Performance

R executes scalar code slowly, so the common paths are vectorized: signal
files are decoded with `readBin` and vector arithmetic in blocks, annotation
files are decoded in bulk, and the tools format their output with
vectorized `sprintf`. For example (R 4.3, `Rscript` command line including
start-up), `rdsamp` prints a 650,000-sample, 2-signal format 212 record in
about 2 s, and `rdann` 400,000 annotations in about 4.5 s. Programs that
read many short pieces of a record pay a fixed cost of about 0.05 ms per
`getframes` call (`sigamp -w 0.01` makes 6,000 measurements of a 1-minute
record in about 1.7 s). `write_record` encodes the samples with vector operations too (exactly as
`putvec` on each frame): 216,000 frames of 2 signals are written in about
0.03-0.08 s and read back with `read_record` in about 0.02-0.06 s.

## Limitations

* The standard output and error are written in binary through
  `/dev/stdout` and `/dev/stderr`; where these do not exist (Windows), they
  are written as text, and NUL bytes are lost.

## Testing

From the root of the repository:

```sh
Rscript r/tests/run_tests.R                                  # unit tests
python3 tests/conformance/harness.py check --impl r -j8      # conformance suite
python3 tests/conformance/harness.py check --legacy --impl r -j8   # legacy suite
R CMD build r && R CMD check --no-manual wfdbx_*.tar.gz      # package check
```

The conformance suite runs the tools through `r/inst/bin/wfdbx.R` and
compares their output with that of the C programs.

## Authors and license

The WFDB library and tools were written by George B. Moody, with revisions
by Benjamin Moody and contributions from many others; `parsescp` was written
by George B. Moody and Edna S. Moody, and `lib/ecgcodes.h` and `rdann` by T.
Baker and G. Moody. The header of each source file names the authors of the
C code it ports, and [`docs/AUTHORS.md`](../docs/AUTHORS.md) gives the
details. The R implementation was developed by Reza Sameni (2026), with AI
assistance (see the project README).

The library is distributed under the GNU Library General Public License,
version 2 or later ([LICENSE.LIB](../LICENSE.LIB)); the command-line tools
(`R/apps_*.R`, `R/cli.R`, `inst/bin/wfdbx.R`) under the GNU General Public
License, version 2 or later ([LICENSE](../LICENSE)). The package as a whole
is therefore declared `GPL (>= 2)` in `DESCRIPTION`.
