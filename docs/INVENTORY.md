# Inventory: tools and library functions by language

This table lists every command-line tool and every library function of
wfdb-x, what it does, and its status in each implementation. The original
C code (WFDB Software Package 10.7.0, `third_party/`) is the reference: the
expected results of all tests were produced by it, with the deliberate
divergences of wfdb-x applied ([`DIVERGENCES.md`](DIVERGENCES.md)).

Legend: **✓** implemented and tested.

* *Tools* are tested by the conformance suite (`tests/conformance/`): the
  number of cases is given; every implementation marked ✓ reproduces the
  C results (standard output, standard error, exit status, files) byte for
  byte in all of them.
* *Library functions* are tested by the unit tests of each implementation
  (`python/tests/`, `cpp/tests/`, `matlab/tests/`, `rust/tests/`,
  `julia/test/`, `r/tests/`), with expected values produced by the C
  library (`tests/reference/api_expect.c`), and through the tools that use
  them. A differential test (about 10,000 random tool invocations and 950
  library-level scripts, each run with the C library and every
  implementation) found no remaining differences.

MATLAB/Octave status: tested with GNU Octave 8.4 (MATLAB was not
available; the code follows the MATLAB R2019b+ compatibility rules of
`matlab/DEVELOPING.md`).

## Command-line tools

| Tool | What it does | Cases | Python | C++ | MATLAB/Octave | Rust | Julia | R |
|---|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Signals** | | | | | | | | |
| `rdsamp` | print signal samples (text, CSV, XML; ADC or physical units; time formats) | 282 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wrsamp` | write a record from text (columns, scaling, any storage format) | 67 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbdesc` | describe the signals of a record (header contents) | 47 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sigamp` | measure signal amplitudes (RMS or peak-to-peak, by beat or window) | 41 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `snip` | copy a segment of a record (any format) to a new record | 39 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `xform` | convert records: format, sampling frequency, gain, signal selection | 53 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sampfreq` | print the sampling (or counter) frequency of a record | 21 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `signame` | print signal names | 9 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `signum` | print the number of a named signal | 6 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbcat` | copy a WFDB file (found via the WFDB path) to the standard output | 7 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbwhich` | print the path of a WFDB file | 16 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Time conversion** | | | | | | | | |
| `wfdbtime` | convert between sample numbers, elapsed and absolute times | 8 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `time2sec` | convert a time string to seconds | 20 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Annotations** | | | | | | | | |
| `rdann` | print annotations (filters by time, type, subtype, channel, number) | 77 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wrann` | write an annotation file from text (`rdann` format) | 26 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sortann` | sort an annotation file into time order | 19 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ann2rr` | print RR intervals from annotations | 41 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `rr2ann` | write an annotation file from RR intervals | 13 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Format converters** | | | | | | | | |
| `edf2mit` | convert EDF/EDF+ to a WFDB record | 16 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mit2edf` | convert a WFDB record to EDF | 20 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `rdedfann` | print EDF+ annotations (as `rdann` text) | 11 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wav2mit` | convert a WAV file to a WFDB record | 11 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mit2wav` | convert a WFDB record to a WAV file | 12 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdb2mat` | convert a WFDB record to a MATLAB/Octave .mat file | 27 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `a2m` | convert AHA-format annotations to WFDB format | 14 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `m2a` | convert WFDB annotations to AHA format | 9 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ad2m` | convert AHA-format signals (tape/CD) to a WFDB record | 15 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `md2a` | convert a WFDB record to AHA-format signals | 5 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ahaecg2mit` | convert AHA DVD-format ECG files (binary or text) to WFDB | 9 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `parsescp` | convert SCP-ECG files to WFDB records (and describe them) | 30 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `makeid` | write a record ID block (for AHA conversions) | 4 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `readid` | read a record ID block | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `revise` | convert an old-style header to the current format | 9 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Total** | 33 tools | **987** | 987 | 987 | 987 | 987 | 987 | 987 |

## Library functions

The C library functions keep their C names in every implementation
(Python: `wfdbx.isigopen`; C++: `wfdbx::isigopen`; MATLAB/Octave:
`wfdbx.isigopen`; Rust: `wfdbx::isigopen` or `Wfdb::isigopen`; Julia:
`WFDBX.isigopen`; R: `isigopen`). Each row lists related functions.

| Function(s) | What they do | Python | C++ | MATLAB/Octave | Rust | Julia | R |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Opening and closing** | | | | | | | |
| `annopen` | open annotation files (input and output annotators) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `isigopen` | open the input signals of a record (reads the header) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `osigopen` | open output signals described by an existing header | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `osigfopen` | open output signals described by `WFDB_Siginfo` structures | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbinit` | open annotators and input signals in one call | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbquit` | close all files and reset the library state | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbflush` | flush all output buffers | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Reading and writing signals** | | | | | | | |
| `getvec` | read the next sample of each input signal | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `getframe` | read the next frame (all samples of oversampled signals) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `putvec` | write a sample to each output signal | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `getframes`, `getvecs` | read many sample vectors at once (addition; `getvecs` in C++) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `isigsettime` | skip to a time in all input signals | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `isgsettime` | skip to a time in one signal group | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `tnextvec` | find the next valid sample of a signal at or after a time | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sample`, `sample_valid` | random access to a sample of an input signal | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `findsig` | find a signal by name or number | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `getspf` | samples per frame of the input record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setgvmode`, `getgvmode` | select low/high resolution and padding modes of `getvec` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setifreq`, `getifreq` | resample the input signals to another frequency | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setibsize`, `setobsize` | set the input/output buffer sizes | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Reading and writing annotations** | | | | | | | |
| `getann` | read the next annotation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ungetann` | push an annotation back into an input stream | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `putann` | write an annotation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `iannsettime` | skip to a time in all input annotators | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `iannclose`, `oannclose` | close an input or output annotator (output files are sorted if needed) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setafreq`, `getafreq` | time resolution of output annotation files | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setiafreq`, `getiafreq`, `getiaorigfreq` | time resolution of input annotators | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Annotation codes and mnemonics** | | | | | | | |
| `ecgstr`, `strecg`, `setecgstr` | convert between codes and ECG mnemonics | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `annstr`, `strann`, `setannstr` | convert between codes and annotation mnemonics | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `anndesc`, `setanndesc` | descriptions of annotation codes | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `isann`, `isqrs`, `setisqrs`, `map1`, `setmap1`, `map2`, `setmap2`, `ammap`, `mamap`, `annpos`, `setannpos` | code classification and mapping (`wfdb_*` names in C++ and MATLAB) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Time, date and units** | | | | | | | |
| `timstr`, `mstimstr` | format a time (elapsed or absolute, with or without milliseconds) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `strtim` | parse a time string (sample numbers, elapsed and absolute times) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `datstr`, `strdat` | format and parse dates (Julian day numbers) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sampfreq`, `setsampfreq` | sampling frequency of a record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `getcfreq`, `setcfreq`, `getbasecount`, `setbasecount` | counter frequency and base count | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setbasetime` | base time and date of the record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `adumuv`, `muvadu`, `aduphys`, `physadu` | convert between ADC units and physical units | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Headers, segments and info** | | | | | | | |
| `newheader`, `setheader` | write a header file | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setmsheader`, `getseginfo` | write and read multi-segment records | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `getinfo`, `putinfo`, `setinfo`, `wfdb_freeinfo` | read and write info strings (header comments) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbgetskew`, `wfdbsetskew`, `wfdbsetiskew` | signal skew | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbgetstart`, `wfdbsetstart`, `wfdbputprolog` | byte offset of signal data (prolog) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Calibration** | | | | | | | |
| `calopen`, `getcal`, `putcal`, `newcal`, `flushcal` | read and write calibration files | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **WFDB path, errors, configuration** | | | | | | | |
| `getwfdb`, `setwfdb`, `resetwfdb` | the input directory (one directory; the WFDB search path in legacy mode) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbfile` | path of a WFDB file | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbquiet`, `wfdbverbose`, `wfdberror`, `wfdb_error` | error reporting | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbmemerr`, `wfdb_me_fatal` | behavior on memory errors | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbx_time_needs_freq` | whether `strtim` needs the sampling frequency for a string (addition; see [`DIVERGENCES.md`](DIVERGENCES.md)) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbx_set_legacy`, `wfdbx_get_legacy`, `wfdbx_legacy_args` | legacy mode: the original package's behavior, on request (addition; see [`DIVERGENCES.md`](DIVERGENCES.md)) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbx_set_output_dir`, `wfdbx_get_output_dir` | the output directory: every relative name written is created under it (`WFDBX_OUTPUT_DIR`; the high-level writers' `dir` option); addition, see [`DIVERGENCES.md`](DIVERGENCES.md) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbx_set_input_dir`, `wfdbx_get_input_dir` | the input directory (a directory, `~...` or a URL): every relative name read is found under it (`WFDBX_INPUT_DIR`; the high-level readers' `input_dir` option); addition, see [`DIVERGENCES.md`](DIVERGENCES.md) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbx_set_network`, `wfdbx_get_network` | network access, off by default (`WFDBX_NETWORK`; the high-level readers' `network` option); addition, see [`DIVERGENCES.md`](DIVERGENCES.md) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wfdbversion`, `wfdbldflags`, `wfdbcflags`, `wfdbdefwfdb`, `wfdbdefwfdbcal` | version and configuration strings | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **High-level API (additions; each function takes a legacy option)** | | | | | | | |
| `read_record`, `read_header` | read a record (or part of one) into an array | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `read_annotations` | read an annotation file into arrays | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `write_record`, `write_annotations` | write a record or an annotation file | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

In R, the C function `sample` is exported as `wfdb_sample` (so as not to
mask R's `sample`).
