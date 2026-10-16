# Known behaviors of the original C implementation

wfdb-x reproduces the WFDB Software Package 10.7.0 (C) **exactly**,
including behaviors that may look surprising. This document lists the
notable ones, so that users (and implementers of new language ports) know
they are intentional, and says for each one whether the official
documentation describes it.

Sources checked: the *WFDB Applications Guide* (`third_party/wag.pdf`, built
from the man pages in `doc/wag-src/` of the C sources), the *WFDB
Programmer's Guide* (`doc/wpg-src/wpg0.tex`, cited as WPG), and comments in
the C sources. Where the documentation and the C code disagree, wfdb-x
follows the code.

The one deliberate exception, the absence of a default sampling frequency
and gain, is described in [`DIVERGENCES.md`](DIVERGENCES.md).

A few C behaviors are *undefined* (crashes, infinite loops, reads of
uninitialized memory). wfdb-x cannot reproduce those; for each one, the
behavior chosen by wfdb-x is stated below. The conformance tests never
exercise them.

The reference platform is x86-64 Linux with glibc: `char` is signed,
`long` is 64 bits, and the library is built with `-DWFDB_LARGETIME`
(so `WFDB_Time` is 64 bits).

## Documented behaviors (reproduced)

These look surprising but are described in the documentation.

### Library

- **Format 8 and signed bytes.** `r8()` returns a signed `char`, so format 8
  first differences are signed bytes. signal(5): "Each sample is
  represented as an 8-bit first difference" and differences that do not fit
  "are represented instead by the largest difference of the appropriate sign
  (-128 or +127)".
- **Bit-packed formats and end of file.** A format 212 file with an odd
  number of samples ends with a 2-byte group; format 310/311 files may end
  with a partial group, and format 310 files whose last group holds two
  samples appear to contain an extra zero sample. WPG (changes in 10.6.0):
  "if the total number of samples is not a multiple of 2 or 3,
  `wfdbquit()` will correctly write out the remaining samples, adding padding
  if necessary"; `signal.c` (`f310`): "the file will appear to have an extra
  (zero) sample at the end".
- **Checksums.** When a signal's sample count (from the header) is reached,
  its checksum is verified; on a mismatch, `getvec` prints `getvec: checksum
  error in signal N` and returns -4 *for that frame*. WPG (`getvec`): "-4
  Failure: checksum error (detected only at end of file)". Applications that
  loop while `getvec(...) >= 0`, such as `rdsamp`, therefore stop before
  printing the last frame (this consequence is not documented).
- **Modification labels.** `annopen` consumes the `NOTE` annotations at time
  0 (subtype 0) at the start of an annotation file, so `getann` does not
  return them. WPG (glossary, "Modification label"): "An 'invisible'
  annotation at the beginning of an annotation file ... When `annopen` ...
  opens an annotation file that contains modification labels, it
  automatically calls `setannstr` and `setanndesc`", and "When `annopen` ...
  creates an annotation file, it automatically generates modification labels,
  for each annotation code that has been (re)defined". So reading a file
  whose table redefines mnemonics makes every annotation file written later
  in the same process repeat the table. After `iannsettime(0)` the labels
  are returned like other annotations; rdann(1): "if modification labels are
  present, they are not printed unless `-f 0` is given explicitly".
  (Undocumented details: see the next section.)
- **Time resolution record.** A program that calls `setafreq()` with a
  positive value (e.g. `wrann`, which calls `setafreq(sampfreq(record))`)
  writes a `## time resolution:` NOTE at the start of its output files. WPG
  (changes in 10.6.0): "the time resolution and annotation type definitions
  will not be written until the first time `putann()` is called".
- **Sorting of output annotations.** Out-of-order output annotations (and
  annotations written twice at the same location) are sorted when the file
  is closed by running `sortann` as a separate process, unless
  `WFDBANNSORT=0`; `Rearranging annotations for output annotator ...
  done!` is printed on the standard error output. WPG ("Annotation
  Order", `wfdbquit`, `oannclose`) documents the mechanism and `WFDBANNSORT`;
  the message text is not documented.
- **Variable-layout multi-segment records** are rescaled to the gains and
  baselines of the layout segment. header(5): "the signals of a variable
  layout record are rearranged, shifted, and rescaled as needed". The
  rounding rule (that of `sigmap()`, halfway cases rounded up) and the
  `sigmap_init: loss of precision ...` warning, printed when a segment's
  gain exceeds that of the layout, are not documented.
- **`setcfreq`** is overridden by each header read: WPG: "The effect of
  `setcfreq` is nullified by later invoking any of the functions that read
  header files" (`readheader` sets the counter frequency to the sampling
  frequency when the header gives none).

### Applications

- **`sortann`** keeps only the last of several annotations with the same
  time, `num` and `chan`, and drops the location entirely if that last one
  is `NOTQRS`. sortann(1): "If the input contains two or more annotations
  with the same *time*, *num*, and *chan* fields, only the last one is
  copied", and "If the input annotations are already in the correct order,
  no output is written unless you have used the `-o` option" (so an
  in-order file keeps its `NOTQRS` annotations unless `-o` is given). A
  duplicate always counts as out of order, so such a file is rewritten.
- **`wrann`** turns an unrecognized mnemonic into a `NOTE` whose aux string
  starts with the mnemonic. rdedfann(1): "Recent versions of wrann copy
  unrecognized mnemonics into the aux field, setting the annotation type to
  NOTE".
- **`mit2edf`** uses the current date and time as the start of a record that
  has none, and writes `Startdate not recorded`. `mit2edf.c`: "start
  date/time not recorded -- use current date"; WPG (`setbasetime`): "If
  *string* is empty or `NULL`, the current date and time are read from the
  system clock".

## Undocumented behaviors of the C code (reproduced)

Neither the man pages nor the Programmer's Guide describe these. Items
marked *bug* are almost certainly unintended by the C authors.

### Library

- **Modification labels (details).** `annopen` consumes *every* time-0,
  subtype-0 `NOTE` at the start of the file, even one that is not a valid
  table entry (aux text that is not `## ...` or `CODE MNEMONIC [DESCRIPTION]`,
  or no aux string at all). It stops at the first other annotation. The
  library ends each table it writes with a time-0 `NOTQRS` marker, so NOTEs
  written by an application after a table are not affected.
- **Time-0 duplicates are not sorted.** `putann` treats an annotation at
  time 0 that follows another at time 0 as in order. Annotations written
  twice at the same time-0 location therefore do not trigger the automatic
  `sortann`, and both copies remain (contrary to WPG, see "Documentation and
  code disagree").
- **`setheader` modifies the caller's `units` and `desc` strings** (it
  calls `strtok` on them, cutting `units` at the first blank and `desc` at
  the first line break), although WPG declares the argument as
  `const WFDB_Siginfo *`. *Bug.*
- **Library state that survives `wfdbquit`.** The counter frequency and
  base counter value (see "Documentation and code disagree"), the output
  annotation time resolution (`setafreq`, which `setifreq` also calls), the
  buffer sizes (`setibsize`, `setobsize`), the mnemonic and description
  tables, and the flags of codes whose mnemonics were modified (which make
  every later output annotation file start with a table) are not reset.
  `resetwfdb` (called by `wfdbquit`) restores the WFDB path to "the value
  that was returned by the first call to getwfdb" (comment in `wfdbio.c`),
  so only if `getwfdb` was called before any `setwfdb`; it restores the
  string only and does not re-parse the search path.
- **`setisqrs` and the other `ecgmap.h` setters** store the new value in a
  `char`, so `wfdb_setisqrs(2, 300)` returns 44. (WPG only says that *x* "is
  the value to be returned when the corresponding mapping macro is
  invoked".)

### Applications

- **`ann2rr -i s|m|h`** prints intervals rounded to the requested number
  of digits and then *adjusts the end time* of each interval to match the
  printed (rounded) value, so rounding errors do not accumulate. The
  adjusted time is also the start of the next interval and the time
  printed by `-v`.
- **`ann2rr -h`** pauses after 23 lines of help (`--More--`), reading a
  line from the standard input (as `nguess`, `pschart` and `psfd` do).
- **`ann2rr`** names the wrong option in its error messages for `-p` and
  `-P` (`must follow -P` for `-p`, and the reverse).
- **`wrann`** keeps the values of the subtype, chan and num fields from
  the previous line when a line omits them.
- **`rr2ann`** reads each line with `sscanf("%lf")`. For an empty or
  all-blank line, `sscanf` returns `EOF` rather than 0, so the *previous*
  value is used again and an extra annotation is written. rr2ann(1) says
  empty lines are ignored. *Bug.*
- **`revise`** rejects an old-style header that describes exactly 32
  signals (`init: too many signals`), because its loop over the signals of
  a group stops at `WFDB_MAXSIG` before counting the last one; 31 signals
  are accepted. `WFDB_MAXSIG` (32) is documented as the "maximum number of
  input or output signals". *Bug.*

### Converters

- **`edf2mit`** reads header fields into one reusable 81-byte buffer and,
  for signal labels, starts removing trailing blanks at byte 15 instead of
  byte 16. A 16-character label is therefore followed by a space and by
  whatever bytes remain in the buffer from earlier (longer) fields, up to
  the next NUL. *Bug.*
- **`rdedfann`** never clears the duration of the previous TAL, so an
  annotation whose TAL has no duration repeats the last duration printed.
  (In EDF+, a duration belongs to its own TAL.) *Bug.*
- **`ahaecg2mit`**, for `.ecg` input, writes the annotation of sample *k* at
  time *k*-1 (its time counter starts at -1 and is incremented after the
  annotation is written). Every annotation is one sample early, and one on
  the first sample is written at time -1, which makes the library sort the
  output file when it is closed. For `.txt` input the counter is
  incremented first and the times are correct. Probably a *bug*.
- **`ahaecg2mit`** names `argv[1]` instead of the failing file in its
  `can't open` message.
- **`parsescp`** reads the encoding type of sections 5 and 6 from byte 4
  of the section data (the high byte of the sample interval) instead of
  byte 5, so a 2000 us interval gives "Encoding type: 7", treated as second
  differences, and it reads the section 6 compression type from byte 5
  (which holds the encoding type in the SCP-ECG layout), so second-difference
  data give "Compression type: 2", treated as bimodal. *Bug* (harmless for
  the SpaceLabs/Burdick files the program was written for).
- **`readid`** prints the whole first word of the 24-byte ID block, even if
  it is longer than 8 characters. (`sscanf("%s")` writes it into a 9-byte
  buffer; strictly this is a buffer overflow, but its result is
  deterministic and is reproduced.)

## Documentation and code disagree

In each case wfdb-x follows the C code.

| Topic | Documentation | C code (and wfdb-x) |
|---|---|---|
| `wfdbquit` | WPG: resets "the factors used for converting between samples, seconds, and counter values ... and the base counter value (reset to 0)" | the counter frequency (`setcfreq`/`getcfreq`) and the base counter value are not reset |
| Annotations at one location | WPG ("Annotation Order"): "only the last annotation written to any given location is retained" | true only when the file is sorted; repeated annotations at time 0 do not trigger sorting, so all copies are kept |
| `setheader` | WPG prototype takes `const WFDB_Siginfo *` | modifies `units` and `desc` in place (`strtok`) |
| `setafreq` | WPG (`setafreq`): no effect on output annotation files "already open" | takes effect for open files until their first `putann` (as WPG's 10.6.0 notes say) |
| `sortann` | sortann(1): automatic sorting is disabled by setting `WFDBNOSORT` | the variable is `WFDBANNSORT=0` (WPG: "`WFDBNOSORT` was replaced by `WFDBANNSORT`"); `WFDBNOSORT` is ignored |
| `rr2ann` | rr2ann(1): empty lines and blanks at the start of a line are ignored | an empty or all-blank line repeats the previous interval |
| `wrsamp -c` | checks that each line has the same number of fields | accepted but has no effect |
| `wrsamp -l n` | reads up to *n* characters per line (default 1024), truncating longer lines with a warning | prints `-l is obsolete, ignored`; lines of any length are read whole |
| `wrsamp` separators | default field separators are spaces and tabs; `-s c` makes *c* the only separator | default separators are space, tab, CR, LF and comma; `-s` takes a *set* of characters |
| `edf2mit` default record name | "use the patient ID field from the input file" | the input file name up to its first `.`, with characters other than letters and digits replaced by `_`, truncated to 50 characters |
| `wav2mit` default record name | "the base name of the input file" | the input file name without `.wav`, including any directory part |
| `parsescp` byte order | `.ecg` and `.dat` samples are big-endian | little-endian on the reference platform (`.ecg`: written with native byte order, since `SWAP` is not defined; `.dat`: written by the library in format 16) |
| `parsescp` missing samples | "each missing sample is assigned a special value (WFDB_INVALID_SAMPLE, or -32768)" | a missing lead is written as zeros (`parsescp.c`: "Allocate an array of zero samples to use for the missing lead(s)"); -32768 appears only with `-z` |
| `revise` | `WFDB_MAXSIG` = 32 is the maximum number of signals | 32 signals are rejected |

## Undefined behaviors (not reproduced)

Where the documentation states what should happen, the last column says
whether the wfdb-x choice matches it.

| Program / function | C behavior | wfdb-x behavior |
|---|---|---|
| time strings whose value is out of the range of `WFDB_Time` (e.g. `1e300` seconds), or frame numbers (`f`*N*) when no record is open (frame frequency 0) | `strtim` converts an out-of-range double (infinite or NaN for `f`*N*) to `WFDB_Time` | `LONG_MIN`, as the x86-64 conversion gives (`[...]` times: the subtraction of the base time wraps around, as `WFDB_Time` arithmetic does on x86-64; the MATLAB/Octave and R ports hold times in doubles, exact up to 2^53) |
| `isgsettime(g, t)` with a group number `g` that is not that of a signal group, when the input pointer is already at `t` | `isgsetframe` reads `igd[g]` past the end of its array before checking `g` (crash, or a return value of 0) | the group number is reported as incorrect (`isgsettime: incorrect signal group number`, -2), as for other times |
| `xform` changing the sampling frequency or gain of samples close to the limits of an `int` (format 32, or large gains) | `int` overflow in the difference of consecutive samples, and conversions of out-of-range doubles to `int` | as on x86-64: the difference wraps around, and out-of-range conversions give `INT_MIN` |
| `edf2mit` with a signal that has 0 samples per data record (sampling frequency 0) | the number of samples per frame is the conversion of 0.0/0.0 (NaN) to `int`; with another signal of nonzero frequency, `gcd()` loops forever | `INT_MIN` (as on x86-64); the loop is not avoided |
| `edf2mit` with a start date or time field that does not hold three numbers (e.g. a NUL byte in the field) | the day, month, year, hour, minute or second not read by `sscanf` is an uninitialized variable | 0 is used |
| `rdsamp -c`/`-X` with a signal description or units string containing `'` or `\` | `escapify()` loops forever or crashes | the characters are escaped with a backslash (the evident intent of `escapify()`; `wrsamp`, which rdsamp(1) says parses `-X` output, treats `\` as an escape) |
| `wrann` input line with no space after column 9 (including fragments of lines longer than 399 bytes) | scans past the end of the line buffer (crash or garbage) | the remainder of the line is treated as empty |
| `wrann` input with a mnemonic longer than 9 characters | buffer overflow | the full mnemonic is used (matches rdedfann(1): unrecognized mnemonics are copied into the aux field) |
| `wrann` description longer than its 256-byte aux buffer | buffer overflow | the aux string is truncated as for shorter overflows (the intent of the truncation code) |
| headers whose format field ends with `x`, `:` or `+` | reads past the end of the token | the empty field is ignored (as if absent; header(5) makes these fields optional) |
| `wrsamp` input line ending with a field separator (e.g. trailing space, or CRLF line endings) | heap corruption (`malloc(): corrupted top size`, abort) | the trailing separator is ignored (matches wrsamp(1): "no special treatment is required for files containing both carriage returns and linefeeds") |
| `wrsamp` line with fewer fields than selected columns | uses a dangling pointer | the missing sample is written as invalid (matches wrsamp(1), which records missing and non-numeric entries as invalid samples) |
| `signame -s N` where N equals the number of signals | reads past the end of an array (segfault) | prints `[INVALID]` (matches signame(1): "If the specified signal does not exist in record, signame outputs `[INVALID]`") |
| `sortann` replacing a duplicate annotation whose earlier copy is at the head of its list (e.g. two time-0 annotations with a negative `num`; or an earlier copy that follows a time-0, `num` 0, `chan` 0 annotation, which `sortann` itself drops) | reads freed memory (the C program then drops the earlier annotations) | the duplicate is replaced and the earlier annotations are kept (matches sortann(1) and WPG: only the last annotation at a location is dropped) |
| `xform -o OREC` without `-M`, where OREC has signals with more than one sample per frame | `putvec` reads one sample per output sample of a frame from an output array that holds only one per signal (reads past its end) | the output signals are (re)opened with one sample per frame, as xform does for output signals specified interactively (without `-M`, xform(1) processes one sample of each signal per frame; with `-n` or `-N`, the new header says so) |
| `md2a` with a multi-frequency record (including EDF files, in which each signal has as many samples per frame as per data record) | `putvec` reads one sample per output sample of a frame from a local array of `WFDB_MAXSIG` elements of which `getvec` sets only the first *nsig*: the others are uninitialized, and frames of more than `WFDB_MAXSIG` samples read past the array (crash) | the array has one element per output sample of a frame (at least `WFDB_MAXSIG`), initially zero: each frame holds the `getvec` samples followed by zeros |
| `snip` with `-a` given more than once | the count of annotators is not reset: the names are the arguments that follow the *last* `-a`, as many as all the `-a` options name together, continuing into the following arguments (e.g. `-a atr -a qrs -f 10` opens annotators `qrs` and `-f`, which fails); past the end of the argument list it reads `argv[argc]` (a null pointer: crash) and beyond | as in C, except that names beyond the last argument are ignored (`-t 5 -a atr -a qrs` copies `qrs` only) |
| `edf2mit` without `-r`, with an input file name that has no `.` and is shorter than 50 characters | the terminating NUL becomes `_` and the loop reads past the end of the name | the record name ends with the file name |
| `wav2mit` without `-r` | the record name contains one uninitialized byte | the input name without `.wav` is used (wav2mit(1): "the base name of the input file") |
| `ahaecg2mit` with `.txt` input | each line is read into a 16-byte buffer that is not NUL-terminated and keeps the bytes of earlier lines; `sscanf` reads past its end (output depends on stack contents) | the buffer is emulated, with bytes beyond it treated as NUL (the buffer, the samples and the annotation start from zero for each input file) |
| `ahaecg2mit` with an input file name of fewer than 4 characters before the extension | the record name is taken from memory before the string | the available characters are used |
| `ahaecg2mit -s` with a record name of fewer than 2 characters | the terminating NUL of the name is incremented, so the name runs into the following memory | the name is left unchanged (the documented renaming, n0nn to n2nn and n1nn to n3nn, applies to 4-digit AHA names) |
| `a2m`, `ad2m` without `-r`, with an input file name ending in `/` | the extension search starts past the end of the (empty) record name | the record name is empty |
| `ad2m` with a record name of more than 7 characters | the signal file name overflows its 12-byte buffer | the full name (`RECORD.dat`) is used |
| `a2m`, `ad2m` with a directory as input file (`-i DIR`) | reads forever | `can't read input file`, exit status 2 |
| `mit2edf`, `makeid` | uninitialized variables in rare cases (e.g. a single annotation) | 0 is used |
| `parsescp -v`/`-x` with a section 7 (global measurements) | the dump of the remaining bytes of section 7 reads one byte past its end (past the end of the input if section 7 is the last section) | bytes beyond the end of the input are read as 0 |
| `parsescp` with a lead shorter than lead 0 (or than 5000 samples), or whose sample count cannot be allocated | reads past the end of the lead's array, or dereferences a null pointer | the missing samples are read as 0, as the C code does for missing leads (parsescp(1) documents -32768 for samples missing from a recording shorter than 10 seconds) |
| `parsescp` with lead indices outside the signal array (a section 3 longer than its lead table, whose entries past the declared number of leads set the indices of leads such as I or V2; or indices left over from an earlier section 3 with more leads) | reads and writes outside the array of signals (heap corruption, abort) | such a lead reads as an array of zero samples, like a missing lead, and its sample count as 0 |
| `parsescp` with a section 3 after section 5 that gives more leads | reads reference beats past the end of their array | the missing reference beats are absent (nothing is added to those leads) |
| `parsescp` with QRS subtraction zones missing from section 4, or zones (shifted by `-s`) outside the signal or the template | uses uninitialized memory, or writes outside the arrays | missing zones are ignored, and samples outside the arrays are skipped |
| `parsescp` with no date or time of acquisition, or an invalid month, in section 1; patient ID, referring physician or comments longer than their 30-, 100- or 200-byte buffers | null pointer dereference, read outside the month table, or an unterminated string | the date or time is left empty, the month is printed as `???`, and the strings are truncated |

## Build-specific values

`wfdbversion`, `wfdbldflags`, `wfdbcflags` and `wfdbdefwfdb` return strings
fixed when the C library is configured and built (installation prefix,
compiler flags), and `wfdberror` (before any error) includes the build date.
All ports of wfdb-x return the values of a release build of 10.7.0
installed in `/usr/local`: `"10.7.0"`, `""`, `""`, `". /usr/local/database
http://physionet.org/physiobank/database"`, and `"WFDB library version
10.7.0 (Jun 10 2022).\n"`. `wfdbdefwfdbcal` is `"wfdbcal"`, as in C.
