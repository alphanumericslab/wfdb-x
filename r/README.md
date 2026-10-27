# WFDB-x for R

The R package `wfdbx` reads and writes physiological signal records in the
WFDB format used by [PhysioNet](https://physionet.org). It is a complete R
implementation of the WFDB Software Package 10.7.0: the library and all of
its command-line tools. It reads and writes the same files as the original C
library, and its tools print the same output.

You can use it in three ways:

* **High-level functions** that read and write whole records and annotation
  files as R matrices and data frames: `read_record`, `read_header`,
  `read_annotations`, `write_record`, `write_annotations`, and `check_record`,
  which checks a record.
* **Command-line tools** such as `rdsamp`, `rdann` and `wrsamp`, run through
  the driver script `wfdbx.R` or from R with `wfdbx_tool`.
* **The WFDB library functions** under their C names (`isigopen`, `getvec`,
  `getann`, ...), for programs written against the C library.

The package is written in base R only: it needs no other package and has
nothing to compile. It needs R 4.1 or later, and runs on Linux and macOS.
On Windows, see [Notes](#notes).

WFDB-x is part of a project that provides the same package in seven languages
with identical behavior; see the
[project README](https://github.com/alphanumericslab/wfdb-x#readme).

## Installation

From a copy of the repository, install the package from its `r/` directory
with this shell command:

```sh
R CMD INSTALL r
```

You can also install it from R, giving the path of the `r/` directory:

```r
install.packages("r", repos = NULL, type = "source")
library(wfdbx)
```

## Quick start

WFDB-x includes a sample record, `100s`, in the `tests/data` directory of
the repository: the first minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with
two ECG signals at 360 Hz and its beat annotations. This example reads it
and writes part of it as a new record. Replace the path with the
`tests/data` directory of your copy of the repository.

```r
library(wfdbx)

# Read the sample record from the repository's tests/data directory.
wfdbx_set_input_dir("wfdb-x/tests/data")

rec <- read_record("100s", physical = TRUE)   # signals in physical units
rec$fs                                        # 360
rec$names                                     # "MLII" "V5"
dim(rec$signals)                              # 21600 2

hdr <- read_header("100s")                    # the header only, no samples
hdr$nsig                                      # 2
hdr$nsamples                                  # 21600

ann <- read_annotations("100s", "atr")        # beat annotations
nrow(ann)                                     # 75
head(ann$symbol, 3)                           # "+" "N" "N"
head(ann$sample, 3)                           # 18 77 370

# Write the first 10 seconds as a new record, "copy", in the current directory.
x <- read_record("100s", sampto = "0:10")     # ADC units
write_record("copy", x$signals, fs = x$fs, fmt = 16, gains = x$gains,
             baselines = x$baselines, adcres = 11, units = "mV", names = x$names)
```

## Reading and writing records

### Reading signals: `read_record`

The examples of this section read the sample record `100s` (see
[Quick start](#quick-start)) from the `tests/data` directory of a copy of
the repository; replace the path with that directory. This call reads the
signal `MLII` from 10 to 20 seconds, in physical units:

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
rec <- read_record("100s", channels = "MLII", sampfrom = "0:10", sampto = "0:20",
                   physical = TRUE)
```

| Argument | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `channels` | signals to read, by number (starting at 0) or by name, as in `names` | all signals |
| `sampfrom`, `sampto` | first sample, and the sample after the last one: a sample number or a time string (see below) | the whole record |
| `physical` | return physical units instead of ADC units | `FALSE` |
| `highres` | read a multi-frequency record at its highest sampling frequency | `FALSE` |
| `pad` | replace invalid samples by the previous valid one | `FALSE` |
| `checksum_warning` | warn when the data do not match the header's checksums | `TRUE` |
| `input_dir`, `network` | input directory and network access for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `FALSE` |

Times can be sample numbers or WFDB time strings: `"0:10"` (10 seconds),
`"1:02:03.5"`, `"s3600"` (sample 3600) or `"e"` (the end of the record).

The result is a list with these elements:

| Element | Contents |
|---|---|
| `signals` | numeric matrix, one row per sample and one column per signal, in ADC units, or in physical units with `physical = TRUE` |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `names`, `gains`, `baselines` | description (without the white space that a header may put at either end of it), gain (ADC units per physical unit; 0 means uncalibrated) and baseline of each signal, as vectors |
| `units` | physical units of each signal, as a list (`NULL` where the header gives none) |
| `siginfo` | the full signal specifications: one `siginfo` list per signal (its `desc` without the white space at either end) |
| `name` | the record name |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `c(year, month, day)` |
| `comments` | the info strings of the header |
| `checksum_ok` | `FALSE` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `NULL` when the header does
not give them. Invalid samples are `WFDB_INVALID_SAMPLE` (-32768), or `NA`
in physical units.

### Reading a header: `read_header`

`read_header(record)` reads the header of a record without opening its
signal files. It returns a list of class `"wfdbx_header"` with these
elements: `name`, `fs`, `counter_freq`, `base_counter`, `nsamples` (0 if
the header does not give the length), `nsig`, `siginfo`, `base_time`,
`base_time_ms`, `base_date` and `comments`. They have the same meaning as in
the result of `read_record`. It takes the same `input_dir`, `network` and
`legacy` arguments.

This example prints the description, storage format, gain and units of
each signal:

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
hdr <- read_header("100s")
for (s in hdr$siginfo) cat(s$desc, s$fmt, s$gain, s$units, "\n")
```

### Reading annotations: `read_annotations`

This call reads the annotations from 10 to 30 seconds:

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
ann <- read_annotations("100s", "atr", sampfrom = "0:10", sampto = "0:30")
```

`annotator` is the file suffix (`"atr"` reads `100s.atr`). The optional `fs`
gives the sampling frequency when the record has no header, or its header
gives none. `input_dir`, `network` and `legacy` are as in `read_record`.

The result is a data frame with one row per annotation, in file order:

| Column | Contents |
|---|---|
| `sample` | annotation times, in samples |
| `symbol`, `code` | annotation mnemonics (`"N"`, `"V"`, ...) and codes (`NORMAL`, `PVC`, ...) |
| `subtype`, `chan`, `num` | subtype, channel and annotator number of each annotation |
| `aux` | auxiliary text of each annotation, or `NA` |

The data frame also has the attributes `record`, `annotator` and `fs`.
`attr(ann, "fs")` is the frequency in which `sample` is counted (0 if
unknown).

### Writing a record: `write_record`

This example writes 10 seconds of random signals, given in physical units,
as a new record, `rand`, in the current directory:

```r
x <- matrix(rnorm(7200), ncol = 2)
write_record("rand", x, fs = 360, fmt = 16, physical = TRUE,
             gains = 1000, adcres = 16, units = "mV", names = c("A", "B"))
```

This writes the header `rand.hea` and the signal file `rand.dat`. You must
give the sampling frequency, the gain and ADC resolution of each signal, and
the units of each calibrated signal; there are no defaults. A gain of 0
marks a signal as uncalibrated, which is only allowed for samples given in
ADC units. Per-signal arguments take one value for all signals, or a vector
with one value per signal.

| Argument | Meaning |
|---|---|
| `signals` | matrix with one row per sample and one column per signal; ADC units, or physical units with `physical = TRUE` (`NA` is written as an invalid sample) |
| `fs` | sampling frequency in Hz |
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `base_time`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `samps_per_frame` | samples per frame of each signal, for a multi-frequency record |
| `dir` | directory in which to create the files |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) |

`write_record` returns `NULL`, invisibly.

### Writing annotations: `write_annotations`

This call writes three beat annotations for the record `rand` (written by
the previous example) to the file `rand.qrs`:

```r
write_annotations("rand", "qrs", sample = c(100, 460, 820), symbol = c("N", "N", "V"))
```

Give the annotation types as `symbol` or as `code`. `subtype`, `chan`,
`num` and `aux` are optional, and `fs` records the frequency in which
`sample` is counted. `sample` can also be a data frame returned by
`read_annotations`, which then gives all the fields.

If the annotations are not in time order, the file is sorted when it is
written. `sort = FALSE` keeps the order you gave (without the library's
advice to run `sortann`) and `sort = TRUE` always sorts, for that call
only. Without `sort`, the `WFDBANNSORT` environment variable decides
(sorting is on unless it is `0`).

### Errors and warnings

* A record, header or annotation file that cannot be read or written stops
  with an R error, such as "can't read record REC".
* A signal file that is shorter than its header says stops with an error:
  "can't read signal data of record REC (getvec status -3)".
* An annotation file that ends unexpectedly (or cannot be read to its end)
  stops `read_annotations` with an error: "can't read annotation file ANN
  of record REC (getann status -3)". With `sampto`, only the part of the
  file read before `sampto` must be intact.
* A record or annotation file that cannot be written completely (for
  example, when the disk is full) stops `write_record` with the error "write
  error on record REC", and `write_annotations` with "write error on
  annotator ANN for record REC", after the library's message (such as
  "osigclose: write error in signal group 0").
* In `write_record`, each `samps_per_frame` value must be an integer of 1
  or more ("samps_per_frame must hold integers >= 1"), and `signals` must
  have `sum(samps_per_frame)` columns ("signals has N columns, but
  samps_per_frame adds up to M"). These are checked first, and nothing is
  written.
* Invalid arguments, and a value the operation needs but the record does not
  give, stop with an error. For example, a time string such as `"0:10"`
  needs the sampling frequency, and `physical = TRUE` needs the gain of each
  signal.
* When the data do not match the checksums in the header, `read_record`
  returns all the data and issues an R warning: "checksum error in record
  REC: the signal data do not match the checksums in its header".
  `checksum_warning = FALSE` turns the warning off; `rec$checksum_ok` is
  `FALSE` either way. Checksums are only checked when a read reaches the end
  of the record.
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file". `write_record`
  reads nothing, so it overwrites any existing files of the same name.

Use `tryCatch` to handle these errors and warnings in a program. The
high-level functions call `wfdbquit()`, which closes anything opened with
the WFDB library functions.

### Checking a record: `check_record`

This example checks the sample record `100s` (see
[Quick start](#quick-start)) and its beat annotations:

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
report <- check_record("100s", "atr")
report
```

`check_record(record, annotators)` checks the header of a record, its signal
specifications, every sample of its signal files, and the annotation files
you name. It reports each problem it finds. It never stops with an error
for a problem in the record. It checks for problems similar to those found
by Benjamin Moody's [wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a list of class `wfdbx_check_report`. `report$ok` is `TRUE`
if there is no error. `report$issues` is a data frame with one row per
problem and the columns `severity`, `code` (such as `"checksum"`), `where`
(`""` for the record, `"signal 1"`, `"segment s2"`, `"annotator atr"`) and
`message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

Printed, the report has one line per problem, or the line
`no problems found`:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

`format(report)` returns these lines as a character vector. The lines are
the same in the seven languages of WFDB-x. The checks run in normal mode, even if legacy mode is on, and the library
prints no messages during the call.

What is checked:

* the header: that it can be read, the sampling frequency, the length, lines
  of at most 255 characters, and the record name it gives;
* each signal: description, gain, units, ADC resolution and range, storage
  format, and signal file name;
* the signal files: that they can be read, samples outside the ADC range,
  invalid samples, checksums, and the length given in the header;
* each segment of a multi-segment record, and its signals against the
  record's;
* the annotation files: that they can be read to the end, time order,
  annotation codes, and annotations after the end of the record.

The sample record `100s` gives two warnings: its header gives no units.

## Where files are read and written

WFDB-x reads and writes files exactly where you name them, and nowhere else:

| The name is | It is read from | It is written to |
|---|---|---|
| a full path: `/data/mitdb/100` | that path | that path |
| a home path: `~/data/100` | your home directory | your home directory |
| a URL: `https://.../100` | that URL, if network access is on | (URLs cannot be written) |
| anything else: `100`, `mitdb/100`, `../data/100` | the **input directory** | the **output directory** |

In this table, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` for its record 100.

The input and output directories are both the current directory unless you
set them:

| Setting | Function | Option of the high-level functions | Environment variable |
|---|---|---|---|
| input directory: a local directory, `~/...` or a URL | `wfdbx_set_input_dir(d)` | `input_dir =` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx_set_output_dir(d)` | `dir =` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx_set_network(1)` | `network = TRUE` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. Each `set` function returns the previous setting.
`wfdbx_get_input_dir()`, `wfdbx_get_output_dir()` and `wfdbx_get_network()`
return the current settings, and passing `NULL` to a `set` function restores
the default.

This example reads record 100 from `/data/mitdb`, which stands for a local
copy of the MIT-BIH Arrhythmia Database, and writes annotations into the
directory `out`, which must exist:

```r
wfdbx_set_input_dir("/data/mitdb")
rec <- read_record("100")          # reads /data/mitdb/100.hea and 100.dat
write_annotations("100", "qrs", sample = c(100, 460), symbol = c("N", "N"),
                  dir = "out")     # writes out/100.qrs
```

The signal files that a header names are read from the header's directory.

### Record names

A record name is made of letters, digits, `_`, `-` and `~`. `/` separates
directories, and the names of directories may contain any characters, such
as dots: `my.data/rec` is a valid record name, `rec.1` is not. A name whose
last part contains a dot is the name of a file: `100s.hea` is read as the
header of record `100s`, and `100s.edf` as an EDF file.

Records can be written under any such name: `write_record("my.data/rec",
...)` creates `my.data/rec.hea` and `my.data/rec.dat`. The header names the
record and its signal file without the directory (`rec`, `rec.dat`), so the
record can be read under any path that leads to it. Annotator names may
contain letters, digits, `_`, `-` and `~`.

### Reading from PhysioNet

Set the input directory to the URL of the database and turn network access
on. The URL of a database is `https://physionet.org/files/<database>/<version>/`.
This example reads record 100 of the MIT-BIH Arrhythmia Database:

```r
rec <- read_record("100", input_dir = "https://physionet.org/files/mitdb/1.0.0/",
                   network = TRUE)
```

Remote files are read once and kept for the rest of the R session. A
download gives up when it cannot connect, or receives nothing, for 30
seconds.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, you must give it: in
`write_record`, as the `fs` argument of `read_annotations`, or as an option
of the tools (see below). A record whose header gives no frequency has
`fs = 0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

The tools are run by the driver script `wfdbx.R`, with `Rscript`. In a copy
of the repository, the script is `r/inst/bin/wfdbx.R`, and it runs without
installing the package. In an installed package, R gives its path with
`system.file("bin", "wfdbx.R", package = "wfdbx")`. A shell alias makes it
convenient:

```sh
alias wfdbx='Rscript /path/to/wfdb-x/r/inst/bin/wfdbx.R'
```

With this alias, these commands run three tools on the sample record `100s`
(see [Quick start](#quick-start)), read from the `tests/data` directory of
a copy of the repository:

```sh
export WFDBX_INPUT_DIR=wfdb-x/tests/data   # the directory of 100s
wfdbx rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
wfdbx rdann -r 100s -a atr         # print the annotations
wfdbx --list                       # list the tools
```

From R, `wfdbx_tool` runs a tool with its arguments as a character vector,
and returns its exit status. `wfdbx_tools()` lists the tools.

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
wfdbx_tool("rdsamp", c("-r", "100s", "-t", "s3"))
```

The tools have the options and output of the original WFDB tools, which are
described in the *WFDB Applications Guide*
([`third_party/wag.pdf`](https://github.com/alphanumericslab/wfdb-x/tree/main/third_party)):

* signals: `rdsamp`, `wrsamp`, `wfdbdesc`, `sigamp`, `snip`, `xform`,
  `sampfreq`, `signame`, `signum`, `wfdbcat`, `wfdbwhich`
* times: `wfdbtime`, `time2sec`
* annotations: `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann`
* converters: `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
  `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
  `revise`, `parsescp`

The tools use the environment variables of the table above. To read record
100 of the MIT-BIH Arrhythmia Database from PhysioNet:

```sh
export WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/
export WFDBX_NETWORK=1
wfdbx rdsamp -r 100 -t 0:05
```

Tools that write signal parameters require them as options:

| Tool | Required options |
|---|---|
| `wrsamp` (with `-o`) | `-F` frequency, `-G` gain, `-R` ADC resolution, and `-U` units for calibrated signals |
| `wav2mit` | `-G` gain, and `-U` units unless the gain is 0 |
| `ad2m`, `ahaecg2mit` | `-F`, `-G`, `-R`, and `-U` unless the gain is 0 |
| `a2m`, `rdann`, `ann2rr`, `sortann`, `m2a` | `-F` frequency, when the record's header does not give one |

For example, this command writes the record `rec` from the text file
`samples.txt` (one line of samples per frame):
`wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`.

## The WFDB library functions

Every function of the WFDB library is available under its C name, with the
same arguments and meaning, so programs and documentation written for the C
library carry over directly. Where a C function fills an array that you
pass, the R function returns it instead, in a list with the C return value.
This example reads the sample record `100s` (see [Quick start](#quick-start)):

```r
wfdbx_set_input_dir("wfdb-x/tests/data")   # the sample record 100s (see Quick start)
r <- isigopen("100s", 2)               # r$nsig signals; r$si, their specifications
while ((g <- getvec())$stat > 0) {     # g$v: one sample per signal
  # ...
}

annopen("100s", list(anninfo("atr", WFDB_READ)))
while ((g <- getann(0))$stat == 0)
  cat(g$annot$time, annstr(g$annot$anntyp), aux_string(g$annot$aux), "\n")
wfdbquit()
```

Differences from C that come from the language:

* Numbers are doubles. Signal, group and annotator numbers start at 0, as
  in C.
* Strings are character strings, and C `NULL` is `NULL`. Text is handled
  as bytes (ISO-8859-1), so every byte sequence round-trips unchanged.
* C structures are lists with the C field names, made by `siginfo()`,
  `anninfo()`, `annotation()`, `calinfo()` and `seginfo()`.
* A function that fills arrays in C returns them: `isigopen` returns
  `list(nsig, si)`, `getvec` and `getframe` return `list(stat, v)`, and
  `getann` returns `list(stat, annot)`. The help page of each function
  gives its result.
* An annotation's `aux` is `NULL`, or a raw vector whose first byte is the
  length of the text that follows, as in C. `aux_string(aux)` returns the
  text.
* The C function `sample` is `wfdb_sample`, so that it does not mask R's
  `sample`.
* `getframes(n)` reads up to `n` frames at once. It returns `list(v, stat)`:
  a matrix with one row per frame, and the `getvec` status of the first
  frame it could not read. `putframes(m)` writes the rows of a matrix.
* Errors are reported by return values, as in C, not by R errors.
  `wfdberror()` returns the last message, and `wfdbquiet()` stops the
  messages from being printed.
* `wfdbx_write_errors()` (a WFDB-x addition) returns the number of output
  files that the library could not write, flush or close, plus those
  counted by `wfdbx_note_write_error()` (also an addition), which a program
  that writes a file itself calls. The tools exit with status 1 when the
  count goes up or the standard output cannot be written ("TOOL: write
  error on standard output"); in legacy mode they keep status 0, as in C.
* The library keeps the open record and annotators between calls, as in C.
  `wfdbquit()` closes them; the directory and network settings are kept.

The annotation codes (`NORMAL`, `PVC`, ...; `ecgcodes()` lists them) and
the functions of `<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are also
provided; the mapping functions take vectors. The help pages `?isigopen`,
`?timstr`, `?annopen`, `?calopen` and `?getwfdb` list the functions of each
part of the library.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `wfdbx rdsamp --legacy -r 100s`,
  run in the directory of the sample record `100s` (`tests/data` in a copy
  of the repository). Legacy mode finds files through the WFDB path, which begins with the
  current directory, and does not use the input directory;
* high-level functions: `legacy = TRUE`;
* the whole library: `wfdbx_set_legacy(TRUE)`.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written in R, without any external library. The C library reads files
  written by WFDB-x with identical sample values, although the compressed
  bytes differ from those of libFLAC.
* **Speed.** Reading and writing whole records is vectorized: `read_record`
  and `write_record` handle 200,000 frames of 2 signals in a few hundredths
  of a second.
* **Tool output from R.** `wfdbx_tool` writes to the standard output and
  error of the R process. `sink` and `capture.output` do not capture it, and
  a graphical console may not show it. To capture the output, run the
  driver script with `system2("Rscript", c(driver, "rdsamp", ...), stdout =
  TRUE)`.
* **Start-up cache.** When run from a copy of the repository, the driver
  script keeps a compiled copy of the sources in `~/.cache/R/wfdbx/`, so
  that a tool starts quickly. Set `WFDBX_NO_CACHE=1` to turn this off.
* **Downloads.** Remote files are downloaded with the `curl` program if it
  is installed, and with R's `url()` otherwise.
* **Recognizing the same file.** To tell whether an output file is one of
  the input files, R compares the full paths of the files, with symbolic
  links resolved. For two different paths to files of equal size and
  modification time, it asks the `stat` program for their device and inode
  numbers. Where there is no `stat` program, as on Windows, a hard link to
  an input file is not recognized.
* **Legacy mode on macOS.** When a legacy-mode tool writes over a file it
  is reading, such as `xform --legacy -i vlay -o fmt16`, R reads more of
  the old file than the C library does on Linux, so the result differs.
  Outside legacy mode such a command is refused.
* **Windows.** The tools write their output in binary through
  `/dev/stdout` and `/dev/stderr`. On Windows these do not exist, so the
  output is written as text and NUL bytes are lost.

## Testing

These commands, run from the root of the repository, run the unit tests,
the conformance suite and its legacy part, and the package check:

```sh
Rscript r/tests/run_tests.R
python3 tests/conformance/harness.py check --impl r -j8
python3 tests/conformance/harness.py check --legacy --impl r -j8
R CMD build r && R CMD check --no-manual wfdbx_*.tar.gz
```

The conformance suite runs the tools and compares their output with that of
the original C programs. [DEVELOPING.md](DEVELOPING.md) describes how the
package is organized.

## Authors and license

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. The header of each source file names the authors of the
C code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The R implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its R code is a
translation of the C code of the WFDB Software Package into R,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
