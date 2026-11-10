# WFDB-x for Rust: implementation notes

These notes describe how the Rust implementation is organized. They
complement [`docs/porting-guide.md`](../docs/porting-guide.md) (the C
semantics every implementation must reproduce). The C++ implementation
(`cpp/`) is the closest model (a statically typed, compiled port with the
same integer types); the Python implementation (`python/src/wfdbx/`) shows
how each undefined C behavior was resolved. All implementations must behave
identically (the conformance suite checks this).

## Requirements

* Rust 2021 edition, stable toolchain (MSRV 1.70, declared as
  `rust-version`); **no dependencies** (only `std`).
* Linux, macOS, Windows.
* As fast as the C library or faster; no `unsafe` unless measurably
  necessary (and then documented).

## Layout

One crate, `wfdbx` (`rust/Cargo.toml`):

| Path | Contents |
|---|---|
| `src/lib.rs` | crate documentation; module list; glob re-exports (`pub use module::*`) of the library modules, so a new public function needs no change to `lib.rs` |
| `src/wfdb.rs` | the `Wfdb` struct, the default instance (`with_default`), `OptBytes`/`NULL` |
| `src/types.rs` | types, constants (`WFDB_*`, `DEFWFDB`, ...) and structures (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`, `Seginfo`) of `wfdb.h` |
| `src/cstd.rs`, `src/cstd/` | C standard library emulation: `printf` formatting (glibc-exact; `printf.rs`, `float.rs`), `strtol`, `strtod`, `atoi`, `atof`, `sscanf`, `strtok`, `fgets` line splitting (`parse.rs`), glibc `rand` (`rand.rs`), standard streams, `exit`, `argv`, environment (`stdio.rs`) |
| `src/wfdbio.rs` | port of `lib/wfdbio.c`: finding files (input/output directories, network access via `curl`, the WFDB path of legacy mode), `wfdb_open`, errors, `WfdbFile` |
| `src/signal.rs` | port of `lib/signal.c` |
| `src/annot.rs` | port of `lib/annot.c` (and the annotation code mnemonics) |
| `src/calib.rs` | port of `lib/calib.c` |
| `src/wfdbinit.rs` | port of `lib/wfdbinit.c` |
| `src/flac.rs` | FLAC decoder and encoder (port of `cpp/src/flac.cpp`; crate-private) |
| `src/ecgcodes.rs` | annotation codes (`NORMAL`, ...) and the `ecgmap.h` functions |
| `src/record.rs` | high-level API (`read_record`, `read_header`, `read_annotations`, `write_record`, `write_record_physical`, `write_annotations`; `Header::metadata` and `WriteOptions::metadata` use `metadata.rs`) |
| `src/check.rs` | `check_record` (a WFDB-x addition; `python/src/wfdbx/check.py` is the reference) |
| `src/metadata.rs` | header metadata: `read_metadata`, `get_metadata`, `set_metadata`, `remove_metadata`, `update_metadata` and their `_with` variants, `MetadataOptions`, and the checks of `WriteOptions::metadata` (a WFDB-x addition; `python/src/wfdbx/metadata.py` is the reference, `tests/metadata/README.md` the rules) |
| `examples/check_cases.rs` | prints the `check_record` reports of a corpus made by `python/tests/check_corpus.py` (its `expected.txt` format) |
| `src/bin/<tool>.rs` | the command-line tools, one binary each |
| `tests/` | integration tests (`cargo test`) |

`cargo build --release` puts the tools in `rust/target/release/<tool>`,
where the conformance harness finds them (`--impl rust`).

## The library object and the C-style API

All the state of the C library (open signals and annotators, WFDB path,
time base, ...) is held by one struct, **`Wfdb`**. Each C library function
is a method of `Wfdb` with the C name (`w.isigopen(...)`, `w.getvec(...)`).
Internal functions are methods too, so they call each other through
`&mut self` (no global borrow is needed).

For line-by-line ports of C programs, every method is also available as a
free function with the same name and arguments (`wfdbx::isigopen(...)`),
operating on a default instance held in a `thread_local!`
`RefCell<Wfdb>`. The free functions are thin wrappers
(`with_default(|w| w.isigopen(...))`); they must not be called from inside
a method (that would borrow the default instance twice).

Several independent `Wfdb` instances can be used at the same time (each
has its own state, unlike the C library); a `Wfdb` is `Send`.

The state of each C source file is a sub-struct of `Wfdb`, defined in the
module that ports it, so that the modules can be written independently:

| field | type | defined in |
|---|---|---|
| `io` | `IoState` | `wfdbio.rs` |
| `sig` | `SigState` | `signal.rs` |
| `ann` | `AnnState` | `annot.rs` |
| `cal` | `CalState` | `calib.rs` |
| `maps` | `EcgMaps` | `ecgcodes.rs` (the modifiable `<ecgmap.h>` tables) |

Each state implements `Default` (the state at program start). Its fields
are private to its module (or `pub(crate)` where another module needs
them); other modules use the methods. A state must not implement `Drop` to
do anything but flush buffers: dropping a `Wfdb` (which `cstd::exit` does
for the default instance) must behave like C's `exit`, which flushes open
streams but does not close records (no annotation end marks, no header
updates).

Methods that are library-private in C (`wfdb_open`, `wfdb_checkname`,
`wfdb_setirec`, ...) are `pub` methods too (they are useful to tools, e.g.
`wfdbcat` uses `wfdb_open`); hooks used only by other modules
(`wfdb_sigclose`, `wfdb_anclose`, `wfdb_osflush`, ...) are `pub(crate)`.

### Writing a library function

```rust
impl Wfdb {
    /// C `sampfreq(record)`: ...
    ///
    /// Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0):
    /// same arguments and results. Differences: ...; see docs/DIVERGENCES.md.
    pub fn sampfreq(&mut self, record: impl OptBytes) -> f64 { ... }
}

/// C `sampfreq` on the default instance (see [`Wfdb::sampfreq`]).
///
/// Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results. Differences: ...; see docs/DIVERGENCES.md.
pub fn sampfreq(record: impl OptBytes) -> f64 {
    with_default(|w| w.sampfreq(record))
}
```

The last paragraph of the documentation of a public function says where it
comes from: "Translation of the C function NAME() (lib/FILE.c, WFDB
10.7.0): same arguments and results.", followed by "Differences: ...; see
docs/DIVERGENCES.md." when the WFDB-x behavior differs; or, for a function
that WFDB-x adds (the high-level API, `check_record`, `getvecs`, the
`wfdbx_*` settings, ...), "Part of WFDB-x; not in the original WFDB
package."

### File headers

Each source file begins with its `//!` module documentation (its purpose),
followed by a `//` header comment. For a file that translates C code, the
header says that the file is part of WFDB-x, names the C file(s) it
translates and their authors, lists the changes from the original ("Changes
from the original: ..."; each is marked `wfdb-x:` in the code, and
`docs/DIVERGENCES.md` gives the reasons), gives the copyright of the C code
(from `docs/AUTHORS.md`) and of the translation, and the license notice
(LGPL-2.1 or later, `LICENSE`; for the tools of `src/bin`, GPL-3 or later,
`LICENSE-GPL`). A file with no C original (the high-level API,
`check.rs`, `cstd`, `flac.rs`, the tests) says "It has no counterpart in the
original package." instead. Copy the header of a similar file when adding
one.

* String arguments that C allows to be `NULL` are `impl OptBytes`
  (implemented for `&str`, `&[u8]`, `&[u8; N]`, `&Vec<u8>`, `&String`,
  `Option<&[u8]>`, `Option<&str>`, `&Option<Vec<u8>>`; `wfdbx::NULL` is a
  typed `None`). Arguments that cannot be `NULL` may be `&[u8]` or
  `impl AsRef<[u8]>`. Treat a byte string as a C string: it ends at its
  first NUL (`cstd::cstr`).
* Errors: `self.wfdb_error(cformat!(b"init: can't open header for record %s\n", rec))`
  (the message is formatted by the caller; `wfdb_error_fmt(fmt, &[Arg])`
  also exists).
* Files: `self.wfdb_open(type, record, WFDB_READ)` returns
  `Option<WfdbFile>`; `self.wfdb_fopen(name, mode)` opens a file by name
  (a URL is fetched in normal mode); inside the library, never call the free
  functions `wfdb_open`/`wfdb_fopen` (they borrow the default instance), and
  use `wfdbio::local_fopen` for a local file that must not depend on the
  settings. Files named in a header are opened with
  `self.wfdbx_open_in(header_dir, ...)` (normal mode: in the header's
  directory, with the containment check). The messages printed once per
  process (the WFDB warning, network off, curl missing, a URL scheme other
  than http:// and https://) and the cache of fetched URLs (successful
  downloads only) are process-wide; all settings are per instance.

## Data representation

* **Integer types** follow the C reference platform: `WFDB_Sample` is
  `i32`, `WFDB_Time` is `i64`, C `int` is `i32`, `long` is `i64`, `char` is
  `i8` (signed). C wrap-around arithmetic is written with `wrapping_*`
  operations; conversions from `f64` to integers follow C on x86
  (`cstd::d2i`: out-of-range values give `i32::MIN`), not Rust's saturating
  `as`.
* **Strings are bytes.** WFDB files are not UTF-8 (they are ISO-8859-1 or
  arbitrary bytes), so every string of the C API is a byte string: inputs
  are `&[u8]` (functions accept `impl AsRef<[u8]>`, so `"100s"` works),
  results are `Vec<u8>`. A C `NULL` string is `None` (`Option<Vec<u8>>`).
* **Structures** of the C API: `Siginfo`, `Calinfo`, `Anninfo`,
  `Annotation`, `Seginfo`, with the C field names and `Default` giving C's
  zero values. An annotation's `aux` is `Option<Vec<u8>>` holding the C
  bytes, **including the leading length byte** (as in the other ports).
* Functions that fill an array supplied by the caller take a mutable
  slice: `isigopen(record, &mut si[..], nsig)`, `getvec(&mut v)`,
  `getann(an, &mut annot)`. An empty slice stands for C's `NULL`.
* Functions that return a pointer to a static string in C return
  `Vec<u8>` (or `Option<Vec<u8>>` if C may return `NULL`).

## Output and errors

* `printf` formatting must match glibc exactly: use the macros
  `cformat!(b"%5d %s\n", x, s)` (gives a `Vec<u8>`), `cprintf!` (buffered
  standard output), `ceprintf!` (standard error), `cfprintf!(f, ...)` (a
  `WfdbFile`), or the functions `cstd::sprintf(fmt, &[Arg])` /
  `sprintf_into(&mut Vec<u8>, fmt, &[Arg])`. Arguments are converted with
  `cstd::ToArg` (integers, floats, byte strings, `&str`,
  `Option<Vec<u8>>`...). As in C, `%d` prints the low 32 bits of its
  argument (`%ld` all 64), `%hd`/`%hhd` 16/8 bits, `%u`/`%x` the unsigned
  value. `%e`, `%f` and `%g` are produced from the exact decimal expansion
  of the `f64` value with round-half-even, as glibc does (including the
  glibc quirk `%#g` of 999999.5 = `1.e+06`); `nan`/`-nan`/`inf` as glibc
  prints them. Verified against glibc on tens of millions of random cases.
* Parsing: `cstd::strtol(s, base) -> (value, end)` (`end == 0`: no
  conversion; parse from an offset with `&s[pos..]`), `strtoul`, `strtod`
  (correctly rounded, hex floats, inf/nan), `strtof`, `atoi`, `atol`,
  `atof`; `csscanf!(input, b"%d%*c%d", &mut a, &mut b)` (glibc semantics:
  -1 for EOF before the first assignment, unreached destinations
  untouched); `Strtok::new(s).next(delims)`; `fgets_lines(data, size)`.
* `cstd::GlibcRand` (or `cstd::srand`/`cstd::rand`): glibc's `rand`.
* `cstd::d2i(f64) -> i32` / `d2l`: C's `(int)`/`(long)` casts on x86
  (`INT_MIN` for NaN and out-of-range values).
* The standard output is buffered (`cstd::out()`, a lock on the shared
  buffer: `out().write(bytes)`, `out().putc(c)`, `out().flush()`); a
  `WfdbFile` opened on `-` for writing writes into the same buffer.
  `cstd::exit(status)` drops the default `Wfdb` instance (flushing its open
  files), flushes the standard output and exits; never call
  `std::process::exit` directly, and close (or drop) the files a tool opened
  itself before calling `exit` (Rust does not run destructors at exit).
  Write errors with `EPIPE` on the standard output end the process with
  status 141, as `SIGPIPE` ends a C program.
* Write errors. The standard output is never written with `print!` or
  `println!` (they panic when it fails): its buffer records the first other
  write error (`out().error()`, C's `ferror(stdout)`) and discards
  everything after it, as if it were the null device. `wfdbx_legacy_args`
  enables a check in `cstd::exit`: in normal mode, it flushes the standard
  output, prints `PROGRAM: write error on standard output` if it failed,
  and turns the status 0 into 1 if it failed or `wfdbx_write_errors()` is
  not 0. `WfdbFile::close` counts a write error for an output file opened
  by `wfdb_open`/`wfdb_fopen` (not `WfdbFile::fopen`); a tool closes the
  files it writes itself with `wfdbx_fclose_output`.
* `cstd::args()` is `argv` as `Vec<Vec<u8>>`; `cstd::prog_name(argv0)` the
  last path component; `cstd::getenv(name)`, `cstd::setenv`.
* `wfdb_error` writes to the standard error (unless `wfdbquiet()`), as in
  C.

## Files: `WfdbFile`

`WfdbFile` is C's `FILE *` / `WFDB_FILE`: `WfdbFile::fopen(name, mode)`
(plain `fopen`), `wfdb_fopen` (the library's checks), `WfdbFile::stdin()`,
`stdout()`, `stderr()`, `from_bytes(Vec<u8>)` (in memory). Methods:
`getc` (inlined; `EOF` = -1), `ungetc`, `read`, `fread`, `getline`,
`fgets`, `read_to_end`, `g16`, `g32`, `putc` (inlined), `write`,
`printf` (and `cfprintf!`), `p16`, `p32`, `flush`, `tell`, `seek(offset,
SEEK_SET|SEEK_CUR|SEEK_END)`, `eof`, `error`, `clearerr`, `close` (C's
`fclose` status), `is_std`. End of file is sticky (as in glibc >= 2.28)
until `clearerr` or a seek. Dropping a `WfdbFile` flushes it. A file on the
standard input never closes it, and gives back the bytes it buffered but
did not consume to the next reader of the standard input.
`wfdbio::freopen_stdin(name)` is C's `freopen(name, "rb", stdin)`: later
readers of the standard input (`WfdbFile::stdin()`, `wfdb_open` of `-`)
read that file instead (used by `a2m` and `ad2m`).

## Tools

Each tool is `src/bin/<tool>.rs`, a line-by-line port of the C program
(`app/<tool>.c` or `convert/<tool>.c`), with the same messages, exit
statuses and files. `argv` is taken with `std::env::args_os()` and kept as
bytes (`cstd::args()`). Messages that include the program name use the
tool's name (`argv[0]`'s last component, as in C).

A file that a tool reads or creates itself, rather than through the
library (the `-i` file of `wrsamp`, `edf2mit`, `wav2mit`, `a2m` and `ad2m`,
the inputs of `ahaecg2mit`, the `-S` script of `xform`, the signal file
that `wfdbdesc` measures; the WAV file of `mit2wav`, the EDF file of
`mit2edf`, the master header of `snip -m`, the `.des`, `.ecg`, `.key` and
`.txt` files of `parsescp`), is opened at the path that
`wfdbx_input_path(name)` or `wfdbx_output_path(name)` returns (`wfdbio.rs`):
where `wfdb_open` would find or create a file of that name, under the input
or output directory (in legacy mode, inputs as named and the output
directory as a plain prefix); `None` for a URL. `wfdbx_output_path` creates
the missing directories when it prefixes the output directory. Messages
name the file as the user gave it.

`oannclose` sorts out-of-order annotation files in the same process
(`sort_ann_file` in `annot.rs`, with the list of `sortann`,
`annot::AnnList`, which the `sortann` tool uses too), with private reader,
writer and definition table objects. In legacy mode it runs the `sortann`
tool (from the directory of the running executable, else from `PATH`), as
the C library runs `sortann`: `wfdbio::run_sortann(record, annotator)`
runs `sortann -r. RECORD -a ANNOTATOR` (without a shell) after flushing the
standard output and error, and returns its exit status.

A tool's `main` reads `let argv = cstd::args();`, writes with `cprintf!` /
`ceprintf!`, and ends with `cstd::exit(status)` (see `src/bin/wfdbwhich.rs`
and `src/bin/wfdbcat.rs`).

## Bulk reading in `getvecs`

`getvecs(buf, n)` reads `n` sample vectors with the semantics of `n` calls
of `getvec`. `Wfdb::bulk_frames` decodes whole frames at once, straight
from the input buffers, where it can: formats 8, 16, 24, 32, 61, 80, 160,
212, 310 and 311 (one format per signal group), and null signals (format 0)
of known length, without deskewing or resampling. This covers records of
several sampling frequencies, in low-resolution mode (averaging the
oversampled signals with `meansamp`) and in high-resolution mode (from the
start of a frame), and the segments of multi-segment records, of fixed or
variable layout (mapped with `sigmap`), null segments included. Only the
complete frames already in the input buffers are decoded: a frame that
crosses the end of a buffer (whose reading refills it), the frame at which
checksums are verified or a null signal ends, the change from one segment
to the next and everything the bulk path does not decode go through
`getvec`, so the files are read in the same blocks, and the statuses,
messages and state (samples, checksums, counts, `gvc`) are those of
frame-by-frame reading. The frames are decoded in tiles of up to 1024
(`BULK_TILE`, whole packed units): a group's raw samples into a small
buffer (`bulk_decode`), then signal by signal into the frames
(`bulk_signal`: invalid samples, the last sample and the checksum, as
`getskewedframe` handles each sample). `wfdbx_bulk_read(false)` turns it
off; `tests/bulk.rs` compares both paths.

## The high-level API (`record.rs`)

* Each high-level function is a method of `Wfdb` and a free function on
  the default instance. It calls `wfdbquit` before and after its work, so
  it closes whatever the C-style API had open in the same instance.
* The per-call options are applied by setting the library settings and
  restoring them afterwards, also on failure: `with_legacy`
  (`wfdbx_set_legacy`), `with_input` (`wfdbx_set_input_dir`,
  `wfdbx_set_network`) and `with_output_dir` (`wfdbx_set_output_dir`; the
  record name must then be a plain name, and the header records it without
  the directory). `AnnWriteOptions::sort` sets `AnnState::sort_override`
  for the call; the environment (`WFDBANNSORT`) is not changed.
* `with_settings` saves `getgvmode()` and `getafreq()` when a high-level
  function (`read_record`, `read_header`, `read_annotations`,
  `write_record`, `write_record_physical`, `write_annotations`, their
  `_with` forms, and `check_record`) is entered, and restores them
  (`setgvmode`, then `setafreq`) when it returns, also on errors: opening
  an EDF record adds `WFDB_HIGHRES` to the getvec mode and sets the time
  resolution of output annotators, and `wfdbquit` resets neither. The
  C-style functions and the metadata functions keep the behavior of C.
* `read_record` reads blocks of vectors with `getvecs_status`: whole
  frames, and a multiple of 6 of them, so that formats 212, 310 and 311 end
  each block on a whole packed unit. Its vector is allocated for the
  number of vectors expected and one such block of 6 frames more: once
  that number is read, the end of the data is found by reading 6 frames,
  without enlarging the vector. The signal descriptions it returns
  (and those of `read_header`) have no white space at either end, and a
  channel given by name is looked up among them first, then with `findsig`.
  A status
  below -1 (for example -3, a signal file shorter than its header says) is
  an error, also in legacy mode, since the high-level API has no C
  counterpart; `getvec` and the tools are unchanged. `getskewedframe` sets
  `SigState::read_failed` wherever its status becomes -3 (a decoder or I/O
  error, an unexpected end of a signal file, a segment that cannot be
  opened), whatever status `getvec` then returns: in the frame at which a
  checksum is verified, the checksum error (-4) replaces -3. While
  `SigState::read_checked` is on (`read_record` and `check_record` set it,
  and clear `read_failed`, before reading, and clear both afterwards),
  `getvecs_status` stops at such a frame without counting it, with status
  -3; so an incomplete frame is never returned (a truncated file gave a
  fabricated last sample), and `check_record` reports `length_short`. The
  vector is allocated for at most 2^26 values in advance, whatever length
  the header (or `to`) gives, and grows as the frames are read. A checksum
  error alone (status -4) is not an error: the last, complete frame is kept,
  `getvec`'s own message is suppressed during the read
  (`SigState::cksum_quiet`), and the warning `WFDB-x: checksum error in
  record REC: ...` goes through `wfdb_error`, so `wfdbquiet` silences it.
  Checksums are verified only when a read reaches the end of the record.
* An output signal file that is one of the signal files of the open input
  record (an open signal file, or a segment of an open multi-segment
  record, even one not opened yet) is refused by `osigfopen`/`osigopen`
  with status -3. Files are compared by identity: device and inode, or, on
  Windows, the canonical path without regard to case. Legacy mode does not
  check.
* Header metadata (`metadata.rs`). The header is opened with `wfdb_open`
  (type `hea`), under the per-call `input_dir` and `network` of
  `MetadataOptions` (applied with `with_input`), and handled as bytes. A
  change is written to a temporary file in the destination's directory
  (`.NAME.hea.XXXX.tmp`, created exclusively, with the permission bits of
  the destination on Unix), which is renamed over the destination, and
  removed on any failure. These functions do not call `wfdbquit`. The
  duplicate-key warning goes through `wfdb_error`, as the checksum warning
  of `read_record`. `read_header` reads the entries after the header
  (from the `.hea` file only; none for an EDF record, which has no `.hea`
  file, or for the standard input, `-`, without reading anything). `write_record` checks
  `WriteOptions::metadata` (`metadata::info_lines`) before any file is
  created, and writes the entries through `putinfo` after the comments.
  `tests/metadata.rs` runs all 56 shared cases of `tests/metadata/cases.tsv`.
  The record line is found as `readheader` finds it, in every mode
  (`Hdr::from_lines`): the first line that has a token (separated by
  spaces, tabs, CRs and LFs, up to a NUL byte) that does not begin with
  `#`. `getinfo` follows the same rule in normal mode (`comment_or_blank`
  in `signal.rs`; a header without a record line gives no info strings
  from the `.hea` file), and C's rule (the first line that does not begin
  with `#`) in legacy mode; this decides the `comments` of `read_header`
  and `read_record` and the notes of `wfdbdesc`.
* The writers check every argument before they touch any file:
  `write_checks` (in the order of the Python reference: record name,
  number of signals, `samps_per_frame`, per-signal lengths, frames, gains,
  ADC resolutions, units, uncalibrated signals in physical units, `fs`,
  finite gains), then the conversion of physical samples, the metadata and
  the base time; `write_annotations` checks the field lengths, `fs`, the
  reserved times (`i64::MIN`, `i64::MAX`), the codes (0 to 58; 59 to 63 are
  the control codes of the format) and the agreement of symbols and codes.
  The checks of the other languages for header text that is not Latin-1 and
  for ADC values that are not whole 32-bit integers have no counterpart
  (bytes and `i32`). A `putann` that fails is a write error.
* Writing through temporary files (`wfdbio::Staging`): while a writer
  writes (`Staging::begin` to `Staging::end`), `local_fopen` (which
  `wfdb_fopen` and the in-process sort of annotation files use) opens each
  destination written (`"wb"`/`"ab"`; keyed by its absolute name, not a
  URL or the standard output) as a temporary file `.NAME.XXXXXXXX.tmp` in
  the directory of the destination (with symbolic links resolved; created
  exclusively, mode 0600; missing directories created as `local_fopen`
  does); reopening the same destination, `"rb"` included, opens the same
  temporary file. A destination that is a directory fails as before; one
  that exists and is not a regular file (`/dev/full`, a FIFO) is opened
  directly. At the end, if nothing failed and no write error was counted,
  each temporary file gets the mode of the file it replaces (or 0666 less
  the umask) and is renamed over it, after all are complete; otherwise all
  are removed, and a failed rename gives the writer's "write error" error.
  The state is thread-local (`STAGING`), and dropping a `Staging` removes
  the files (a panic). In legacy mode, `oannclose` renames a staged
  out-of-order file over its destination before it runs the `sortann`
  program (`staging_commit_one`), and after a write error neither renames
  nor sorts it.
* `wfdbx_legacy_args(&mut argv)` is what the tools call first: it removes a
  leading `--legacy` and turns legacy mode on. In legacy mode the
  high-level functions keep their checks of a read error (see above) and
  their output directory.

## Packaging

`rust/LICENSE`, `rust/LICENSE-GPL` and `rust/NOTICE` are copies of the
files at the root of the repository (keep them identical), so that they are
in the crate (`cargo package --list` shows them); `Cargo.toml` gives the
license expression `LGPL-2.1-or-later AND GPL-3.0-or-later AND
BSD-3-Clause` (the BSD license is that of libFLAC, whose stream decoder
`flac.rs` translates). The version is in `rust/Cargo.toml` and
`benchmarks/rust/Cargo.toml` (see `docs/RELEASING.md`).

## Testing

```sh
cd rust && cargo build --release && cargo test --release
cargo fmt && cargo clippy --release --all-targets         # formatting (rustfmt.toml), lints
python3 tests/conformance/harness.py check --impl rust     # from the repository root
python3 tests/conformance/harness.py check --legacy --impl rust   # legacy mode
```

`cargo test` also runs the examples of the documentation. Most of them read
the sample record `100s` (the first minute of record 100 of the MIT-BIH
Arrhythmia Database) from `tests/data`. Every example that names a record
says what it is and where it is read from: the visible line sets the input
directory to `tests/data` (for a reader at the root of the repository),
inside hidden `# /*` and `# */` lines, and a hidden line before it sets
`../tests/data` (doctests run in the `rust` directory). The legacy values of the
library functions are checked against the C reference
(`tests/reference/api_expect.c`).

The code must build without warnings (`cargo build`, `cargo clippy`).

To build a single tool, use `cargo build --release --bin <tool>`.
