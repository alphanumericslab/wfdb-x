# Changes

The versions of WFDB-x, shared by its seven implementations (Python, C++,
MATLAB/Octave, Rust, Julia, R and Kotlin). WFDB-x follows
[semantic versioning](https://semver.org): a new patch number (1.1.x) for
corrections only, a new minor number (1.x.0) for new features that do not
change existing behavior, and a new major number (x.0.0) for changes that
can break existing code. Every version implements version 10.7.0 of the
WFDB Software Package.

## 1.2.2

Corrections from the fourth review of version 1.2.1, two corrections of
remote files, and three found by a review of the user's manual, in all seven
languages. The C-style functions and the command-line tools keep the
behavior of C, except for `getinfo`, the URL schemes and `time2sec` without
a sampling frequency (below).

* **Truncated records.** A signal file that ends before the length that its
  header gives (or cannot be read) is a read error of `read_record` (`can't
  read signal data of record REC (getvec status -3)`) even when the
  checksum of a signal is verified at the incomplete frame: `getvec`
  returns the checksum status (-4) for that frame, which replaced the end of
  file (-3), so `read_record` returned the incomplete frame as data (a
  format-16 file holding the samples 1 and 2, whose header gives 3 samples,
  was read as 1, 2, 257, with a checksum warning). The high-level readers
  now track a read failure separately from the checksum, and never return
  an incomplete frame; `check_record` reports such a file as shorter than
  its header says, without a checksum error for the incomplete frame. A
  checksum error alone is still a warning.
* **`read_record` allocates no more than it can read.** The result was
  allocated from the length that the header gives (a header giving 10^12
  samples for a file of 4 bytes attempted to allocate 3.64 TiB); at most
  2^26 samples are now allocated in advance, and the array grows as the
  samples are read.
* **The writers check everything before touching any file, and leave the
  existing files intact after a failure.** `write_record` refuses, before
  any file is opened, arrays that are not 1-D or 2-D, baselines, ADC zeros
  and ADC resolutions that are not whole numbers within the range of a
  32-bit integer (a fraction was truncated, NaN failed after the signal
  file was written), and a record name, signal names, units or comments
  that cannot be written as header text (a character that is not
  Latin-1 in Python: `units="μV"` left the existing header empty).
  `write_annotations` refuses arrays of times that are not 1-D (a 2-D
  array truncated the existing file), the annotation codes 59 to 63 (the
  control codes `SKIP`, `NUM`, `SUB`, `CHN` and `AUX` of the MIT format,
  which corrupted the file) and any code outside 0 to 58, and the times
  -2^63 and 2^63 - 1, which `putann` refuses ("time overflow"): they were
  dropped, and success reported. An error that `putann` reports is now an
  error of `write_annotations`. Both writers write their files to
  temporary files in the destination directory, renamed over the
  destinations when all of them are complete, and removed after a failure;
  the files written are unchanged, byte for byte.
* **`read_annotations` checks `sampfrom` and `sampto`** as `read_record`
  does (whole numbers, `sampfrom` not negative; a fraction, NaN or an
  infinite value is an error, before the file is opened), and closes the
  annotation file whatever happens.
* **Where the record line of a header is.** `getinfo` took the first line
  that does not begin with `#` for the record line, while the header
  parser (`readheader`) takes the first line that holds a token not
  beginning with `#`; for a header whose first line is empty or blank, the
  comments before the record line were returned as info strings (in
  `comments` and in the notes of `wfdbdesc`). `getinfo` now finds the
  record line as `readheader` does, except in legacy mode, a deliberate
  divergence from the C package (`tests/reference/divergences.patch`;
  [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md)). The metadata functions
  follow the same rule in every mode. Four new cases of the conformance
  suite and three of the legacy suite (now 886), and seven new cases of
  the metadata tests (now 56), check it; `tests/metadata/check_c.py`
  checks the headers with the C reference of WFDB-x, or, with
  `--original`, with the unmodified package.
* **A remote file that could not be read is requested again.** A download
  that failed (a server error, a timeout, a file not yet published) was
  remembered until the process ended, so the file could not be read even
  after the server recovered. Only the files that have been read are now
  kept; the next open of a file that could not be read requests it again.
* **Only `http://` and `https://` URLs.** A name that begins with another
  URL scheme (`ftp://`, `sftp://`, `file://`, ...) was opened as a local
  path (`ftp://h/db/100` as the directory `ftp:`, then `h/db/100`), so that
  a local directory named `ftp:` could be read in place of the server. Such
  a name is now refused in normal mode, with or without network access,
  with the message `WFDB-x: can't open NAME: only http:// and https:// URLs
  can be read (mount the server as a local folder, or download the files)`;
  so too an input directory, a file named in a header, the files that a
  tool reads or creates itself, and an output directory with such a scheme.
  A one-letter prefix (`c://x`, like a drive letter) is not a scheme. FTP
  and SFTP are not supported; a server reached by them can be mounted as a
  local folder (`sshfs`, `rclone mount`). Legacy mode is unchanged (every
  name containing `://` is refused, as by the original library built
  without network support). 13 new cases of the conformance suite check
  both corrections.
* **`time2sec -r` needs the sampling frequency of the record.** For a
  record whose header gives no sampling frequency, `time2sec -r REC TIME`
  divided by 0 and printed `-9223372036854775808` with the exit status 0;
  it now exits with status 2 (`time2sec: sampling frequency of record REC
  is not specified`), as do the other tools that need the frequency (also
  when the header cannot be read). A deliberate divergence from the C tool,
  which converted the time at its default of 250 Hz, a result unrelated to
  the record, since WFDB-x assumes no frequency that a record does not give
  ([`docs/DIVERGENCES.md`](docs/DIVERGENCES.md)); legacy mode keeps the C
  behavior. Three new cases of the conformance suite (now 1155) check it.
* **`write_annotations` requires a label for each annotation**, in every
  language: with one annotation or more and neither symbols nor codes, it
  is an argument error ("symbols or codes must be given"; in R, whose
  arguments are `symbol` and `code`, "symbol or code must be given"),
  before any file is touched. C++, Rust and Julia wrote such annotations
  with the code 0, which is not an annotation code; Python, R and Kotlin
  refused even an empty list of annotations, which now writes an empty
  file.
* **`write_record` removes a trailing `.hea`** from the record name, as the
  readers do: `write_record("x.hea", ...)` writes `x.hea` and `x.dat`.
  Python failed ("can't create signal file for record x.hea"), and the
  other languages named the signal file `x.hea.dat`.
* **Website.** The website of WFDB-x is now
  [wfdb-x.org](https://wfdb-x.org); the README, the user's manual,
  `CITATION.cff` and the package metadata (Python, Rust, C++, R, Kotlin)
  give it.
* **NOTICE.** A [`NOTICE`](NOTICE) file at the root of the repository says
  which parts are under which license (the tools under the GPL, version 3
  or later; everything else under the LGPL, version 2.1 or later), and
  gives the copyright notice and license (BSD-3-Clause) of libFLAC 1.4.3,
  whose stream decoder WFDB-x translates. It ships, with `LICENSE` and
  `LICENSE-GPL`, in every package: the Python wheel and source
  distribution, the R package (`inst/NOTICE`), the C++ installation
  (`share/doc/wfdbx`), the Rust crate, the Julia and MATLAB/Octave
  directories, and the `META-INF` of every Kotlin jar. The license
  expressions of the Python, Rust and Kotlin packages and of
  `CITATION.cff` add `BSD-3-Clause` for the translated decoder.
* **C++ package.** The installation provides `wfdbxConfigVersion.cmake`,
  so `find_package(wfdbx 1.2.2 CONFIG REQUIRED)` works; the `wfdbx` target
  requires C++17 of the programs that link it
  (`target_compile_features`); the tests that run the tools find them in
  the build directory of multi-configuration generators (Visual Studio,
  Ninja Multi-Config).
* **Permissions of changed headers.** The metadata functions, and the
  writers' temporary files, never make a file more readable than the file
  it replaces: Kotlin and R create their temporary files owner-only, and
  MATLAB/Octave keeps the permissions of a header whatever characters its
  name contains (without running a shell command).
* **License labels.** The R package declares `License: file LICENSE`
  instead of `GPL (>= 3)`: its new file `LICENSE` states which parts are
  under the LGPL (the library) and which under the GPL (the tools). In
  MATLAB/Octave, the dispatcher of the `wfdbx` command
  (`+wfdbx/+internal/cli_main.m`, `app_run.m`), which only the tools use,
  is under the GPL, as the launchers of the other languages are.

## 1.2.1

* **C++ on Windows** builds again: the code that runs a program (for URLs, through
  `curl`) called its argument-quoting function by a former name.
* **License.** The library is now distributed under the GNU Lesser General
  Public License, version 2.1 or later ([`LICENSE`](LICENSE)), so that
  programs under any license, proprietary ones included, may use it on the
  LGPL's terms; it follows the license of the original C library (the GNU
  Library General Public License, version 2 or later). The command-line
  tools (each language's `apps` and the `wfdbx` command), translations of
  the original tools (GPL version 2 or later), stay under the GNU General
  Public License, version 3 or later ([`LICENSE-GPL`](LICENSE-GPL)). Each
  source file states its license; the package metadata (Cargo, Python, Maven,
  R, CITATION) says so.

## 1.2.0

New features, in all seven languages:

* **Header metadata.** `read_metadata`, `get_metadata`, `set_metadata`,
  `remove_metadata` and `update_metadata` (`readMetadata`, ... in Kotlin)
  read and change the `Key: value` info strings of a header, such as
  `# Age: 63`, without changing anything else in it. `read_header`
  returns them (`metadata`), and `write_record` writes them (its `metadata`
  argument). The rules are in [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md)
  (Additions) and [`tests/metadata/README.md`](tests/metadata/README.md);
  the seven implementations pass the same 49 cases and write
  byte-identical headers, which the original C programs read as before.
* **User's manual.**
  [`docs/user-manual/wfdb-x-user-manual.pdf`](docs/user-manual/wfdb-x-user-manual.pdf),
  built from the LaTeX sources in [`docs/user-manual/`](docs/user-manual/):
  a complete manual, for the users of each language, with every function of
  the high-level API, the C-style library functions and the command-line
  tools.
* **How to cite.** The preprint that describes WFDB-x, as a BibTeX entry in
  the [README](README.md#how-to-cite) and in [`CITATION.cff`](CITATION.cff).

Also in this version: the corrections from the second and third reviews of
version 1.1.0 (listed in `docs/DIVERGENCES.md` and
`docs/KNOWN_C_BEHAVIORS.md`), and benchmarks that compare WFDB-x with the
original C library and tools ([`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)).
No existing function or tool changes behavior, except for the corrections
below.

Corrections:

* **The files that a tool reads or creates itself follow the input and
  output directories.** The `-i` file of `wrsamp`, `edf2mit`, `wav2mit`,
  `a2m` and `ad2m`, the input files of `ahaecg2mit` and the `-S` script of
  `xform` are read from the input directory (`WFDBX_INPUT_DIR`), and the
  WAV file of `mit2wav`, the EDF file of `mit2edf`, the master header of
  `snip -m` and the `.des`, `.ecg`, `.key` and `.txt` files of `parsescp`
  are created in the output directory (`WFDBX_OUTPUT_DIR`), as the files of
  the library are; `wfdbdesc` measures a signal file of unknown length in
  the header's directory. They were opened relative to the current
  directory: with `WFDBX_OUTPUT_DIR` set, `mit2wav` left a header-only WAV
  file in the current directory and a WAV file without its header in the
  output directory. In legacy mode, input files are opened as named, and
  the output directory is a prefix of every output name. New library
  functions: `wfdbx_input_path` and `wfdbx_output_path`. 43 new
  conformance cases (37 in the suite, 6 in the legacy suite).
* **`osigopen(record, NULL, 0)`** returns 0 in every language (Python
  raised `IndexError`; the C function reads out of bounds).
* **The high-level functions leave the annotation time resolution and the
  getvec mode as they were.** After `read_header("100s.edf")` (or any
  high-level function that opens an EDF record), a later
  `write_annotations` in the same process no longer records the EDF
  record's frequency (360 Hz) as the time resolution of its file, and the
  getvec mode (`getgvmode`) no longer stays in high resolution; the C-style
  functions keep the behavior of C.

## 1.1.0 (28 October 2026)

* Faster reading and writing of records in every language: whole blocks of
  samples, including records with several sampling frequencies and
  multi-segment records.
* Signal names without the spaces that some headers put at either end of
  them, in the high-level readers.
* Write errors and frame checks in the high-level writers.
* Benchmarks of the seven languages ([`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)).

## 1.0.1 (27 October 2026)

* The project is called WFDB-x in help texts, messages and documentation.
* The Kotlin Multiplatform implementation (Android, iOS, JVM), the seventh
  language.

## 1.0.0 (16 October 2026)

* The first version: the WFDB library, its 33 command-line tools and a
  high-level API in Python, C++, MATLAB/Octave, Rust, Julia and R,
  checked against the original C programs by the conformance suite.
