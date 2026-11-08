# Changes

The versions of WFDB-x, shared by its seven implementations (Python, C++,
MATLAB/Octave, Rust, Julia, R and Kotlin). WFDB-x follows
[semantic versioning](https://semver.org): a new patch number (1.1.x) for
corrections only, a new minor number (1.x.0) for new features that do not
change existing behavior, and a new major number (x.0.0) for changes that
can break existing code. Every version implements version 10.7.0 of the
WFDB Software Package.

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
