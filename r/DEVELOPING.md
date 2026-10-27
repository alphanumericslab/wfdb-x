# wfdb-x for R: implementation notes

These notes describe how the R implementation is organized. They complement
[`docs/porting-guide.md`](../docs/porting-guide.md) (the C semantics every
implementation must reproduce). The models are the Python implementation
(`python/src/wfdbx/`, closest in style: an interpreted language with
vectorized bulk paths) and the MATLAB/Octave implementation (`matlab/`,
which solved the same problems for another vector language: C `printf`
emulation, byte strings, bulk decoding). All implementations must behave
identically (the conformance suite checks this).

## Requirements

* R 4.1 or later, **base R only** (no package dependencies; `utils`,
  `stats`, `tools` are part of base R and may be used if useful).
* Linux, macOS, Windows.

## Layout

`r/` is an R package named **`wfdbx`**:

| Path | Contents |
|---|---|
| `DESCRIPTION`, `NAMESPACE` | package metadata; exports |
| `R/*.R` | the library: `cstd.R` (C emulation, stdio), `wfdbfile.R` (WFDB_FILE objects), `wfdbio.R`, `signal.R`, `wfdbinit.R`, `annot.R`, `calib.R`, `flac.R`, `ecgcodes.R`, `highlevel.R`, ... |
| `R/apps_<tool>.R` | the command-line tools: `app_<tool>(args)` |
| `R/cli.R` | `cli_main(args)` (the dispatcher), `wfdbx_tool()`, `wfdbx_tools()` |
| `inst/bin/wfdbx.R` | command-line driver: `Rscript r/inst/bin/wfdbx.R TOOL ARGS...` |
| `man/` | documentation (hand-written Rd: roxygen2 is not used) of the exported objects |
| `tests/run_tests.R`, `tests/unit/test_*.R` | unit tests (plain base-R assertions) |

The driver works both with the package installed (`library(wfdbx)`) and
from the source tree (it then sources `R/*.R` itself), so that the
conformance harness can run it without installation:
`Rscript r/inst/bin/wfdbx.R rdsamp -r 100s` (`100s` is the sample record
of `tests/data`, the first minute of record 100 of the MIT-BIH Arrhythmia
Database; run it there, or set `WFDBX_INPUT_DIR` to that directory). From the source tree it caches
the sourced and byte-compiled functions (`saveRDS` of the environment, in
`~/.cache/R/wfdbx/`, keyed by the names, sizes and modification times of
`R/*.R`; `WFDBX_NO_CACHE=1` disables it; `~` is the home directory of the
user from the password database, not `$HOME`, which the conformance
harness sets to a directory of its own for each case; `$XDG_CACHE_HOME`
replaces `~/.cache` if set). Consequences for the sources:

* **Top-level code must not depend on the environment** (environment
  variables, current directory, time, files): it runs once when the cache
  is built. Initialize such state on first use (see `getwfdb`).
* Module state lives in environments created at top level (`.wfdb_io`,
  `.cstd`, `.ecgmap`, ...), each with a reset function (`wfdbio_reset()`,
  `ecgmap_reset()`, `sig_reset()`, ...), used at load time and by the
  tests. `wfdbquit()` resets only the state that C's `wfdbquit` resets.
* Files are sourced in C-locale alphabetical order (as `R CMD INSTALL`
  collates them); top-level code may only use functions defined in the same
  file or in files sorted before it.
* Non-base functions are called as `pkg::fun` only for `utils`, `stats`,
  `tools`, `compiler`, and then must be added to `Imports:` (`tools`:
  `tools::md5sum` in `flac.R`).

The driver sets `LC_CTYPE` and `LC_COLLATE` to `C` (byte semantics for
strings, C sort order), sets `options(warn = -1)` (an R warning on the
standard error output would break the conformance tests), and quits with
the tool's status. Startup (foundation only, idle machine): about 0.18 s
per tool invocation with the cache, about the time of `Rscript -e 0`
itself (0.17 s); 0.23 s without the cache. Sourcing grows with the code,
the cache does not much. Tool functions are named `app_<tool>`; `app_run`
is the runner, not a tool.

## File headers and help pages

The header comment of each file follows the same pattern in all seven
languages. A file that translates C code gives its purpose; the line
"This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and
Kotlin."; the C file(s) it translates and their authors; "Changes from the
original:", a short list of how this file differs from the C code (each
change is marked `wfdb-x:` in the code, and `docs/DIVERGENCES.md` gives the
reasons), or "none, apart from the language."; the copyright of the
original C code (from `docs/AUTHORS.md`) and "R translation and changes:
Copyright (C) 2026 Reza Sameni."; and the GPL-3 notice. A file with no C
original (the high-level API, `check.R`, `cli.R`, `cstd.R`, the driver,
the tests) says "It has no counterpart in the original package." (tests:
"It tests wfdb-x; ...") and gives only Reza Sameni's copyright. Keep the
in-code `wfdb-x:` comments where each change happens.

Each Rd page ends (before See Also) with a section "Origin": "Translation
of the C function(s) ... (lib/FILE.c, WFDB 10.7.0): same arguments and
results.", followed, when the behavior differs, by "Differences: ...; see
docs/DIVERGENCES.md."; for wfdb-x additions, "Part of wfdb-x; not in the
original WFDB package." An example that names a record says what the
record is and where it is read from (the sample `100s` in `tests/data`, a
PhysioNet database with its URL and network access, a local copy of a
database, or a record written by the example).

## Data representation

* **Numbers are doubles.** R's integers are 32-bit and use `INT_MIN` as
  `NA`, so samples and times are stored as `double` (exact for all 32-bit
  sample values and times up to 2^53). C wrap-around arithmetic (`int`
  overflow, casts to `short`/`char`/`unsigned`) is applied explicitly with
  the helpers of `cstd.R` (`cint32`, `cuint32`, `cint16`, `cint8`, ...).
  `bitwAnd` and friends work on 32-bit signed integers only: use the
  helpers for wider values.
* **Strings are raw vectors.** R character strings cannot contain NUL
  bytes and are subject to encodings, so all byte strings of the C API
  (file contents, descriptions, units, aux data, names read from files) are
  handled as `raw` vectors internally. The public API accepts and returns
  character strings where that is natural (record names, mnemonics, time
  strings), converting with `charToRaw`/`rawToChar` and treating them as
  bytes (ISO-8859-1, never re-encoded). Output is written as bytes
  (`writeBin`) — never with `cat` of re-encoded text.
* **C `NULL`** is `NULL`.
* **Structures** of the C API are lists with the C field names
  (`siginfo()`, `anninfo()`, `annotation()`, `calinfo()` constructors). An
  annotation's `aux` is `NULL` or a raw vector whose first byte is the
  length of the data that follows (as in C and the other ports).
* Functions that fill caller-supplied C arrays return them instead:
  `r <- isigopen(record, nsig)` gives `r$nsig` and `r$si`;
  `getvec()` returns the status and the vector; etc. (documented per
  function).
* **C positions are 1-based**: `strtol(s, base, pos)` returns
  `c(value, end)` with `end` the index just past the number (`end == pos`:
  no conversion). Tools' `argv[1]` is the program name, so C's `argv[i]` is
  `argv[i + 1]`.
* **Setting a list field to `NULL` removes it** (`x$f <- NULL`): write
  `x["f"] <- list(NULL)`.
* **Strings and encodings.** Use byte-safe operations on data strings:
  `nchar(x, type = "bytes")`, `charToRaw`/`rawToChar`, `useBytes = TRUE` in
  regular expressions, `cstr(raw)` to get the C-string view (up to the
  first NUL) of a buffer. The command-line driver runs in the C locale, but
  library code may run in a UTF-8 session where `substr` and regular
  expressions without `useBytes` fail on non-UTF-8 bytes.
* **R integers** are 32-bit with `NA` = `INT_MIN`: `as.integer(-2^31)` is
  `NA`, and `bitwAnd` and friends only take R integers (use arithmetic
  on doubles for unsigned 32-bit values). R's
  `sprintf("%d", x)` fails for doubles outside the int range; `csprintf`
  handles them.
* **NaN signs**: R's `NaN` constant is a positive NaN (C `nan`), `0/0`
  computed at run time is negative (`-nan`, as in C on x86).
* **`as.numeric()` on strings is not correctly rounded** (R's own parser:
  about 3 in 10,000 random decimal strings differ from glibc, including
  short ones such as `"8000.8159627"`): parse numbers with `strtod()`
  (or `atof`, `csscanf`), which are glibc-exact.

## Library state

The global state of the C library is kept in package-level environments,
one per module (`.wfdb_io`, `.sig`, `.ann`, `.cal`, `.ecgmap`, `.cstd`),
created at load time. `wfdbquit()` resets what C's `wfdbquit` resets;
the rest (for example the annotation mnemonic tables and the `ecgmap.h`
tables) persists, as in C.

## Formatted output

`printf` formatting must match glibc. R's `sprintf` is C's `sprintf` for
most conversions (R calls the C library for each conversion of finite
values) but prints `NaN`/`Inf`/`NA`, rejects `%u`, `%c`, `%ld`, `%hd`, and
`%d` of doubles beyond the int range, so all formatting goes through
`csprintf(fmt, ...)` (C semantics: `nan`, `-nan`, `inf`, `%ld`/`%lld`,
`%u`/`%x`/`%o` wrapping modulo 2^32 or 2^64, `%hd`/`%hhd`, `%c`, `*`
widths, `%s` of raw byte strings up to their first NUL, `NULL` as
`(null)`), returning raw bytes. Formats are parsed once and cached; when
all arguments are ordinary, one `sprintf` call produces the result.
`csprintf_v(fmt, ...)` is the vectorized form (vector arguments, character
vector result) for large tables. Both are verified against glibc (see
*Testing*). The format is the C format with R escapes already interpreted
(`"\n"` is a newline in R source): pass data through `%s`, never inside a
format.

The standard output goes through `cout(x)` (raw or character; buffered,
flushed by `cout()`, when the buffer is large, before anything is written by
`cerr`, when a tool run by `app_run` returns, and by the driver); the
standard error through `cerr(x)` (unbuffered). `cprintf(fmt, ...)` and
`ceprintf(fmt, ...)` combine them with `csprintf`. Bytes are written with
`writeBin` to `/dev/stdout` and `/dev/stderr` opened in binary append mode
(R's `stdout()` connection is text-only); tools never call `cat`, `print`
or `message`.

## Performance

R executes scalar code slowly, so common paths are vectorized: signal
files are read with `readBin` into raw buffers and decoded with vector
operations (`getframes(n)`, as in the Python and MATLAB ports, exactly
equivalent to `n` calls of `getvec`); output of large tables (`rdsamp`)
is formatted with vectorized `sprintf`/`csprintf_v`; annotation files are
decoded in bulk.

Orders of magnitude (R 4.3, byte-compiled): a simple statement or builtin
call 0.1-0.5 us, a closure call about 1 us, `csprintf` 6-10 us (fast path;
40 us with special values), `sprintf` 1.5 us, `strtol` 9 us, `strtod` 20 us
(0.5 ms in the rare cases that need exact big-number arithmetic: more than
15 significant digits or large exponents), `csscanf` 60 us, `wf_getc` 1 us,
`wf_read` 3 us, `cout` of a short string 4 us.

Idioms that matter:

* **No class attribute on environments used on hot paths**: `$` on an
  object with a class is dispatched (S3), which makes every field access
  several times slower (`wf_getc` went from 5 us to 1 us without it).
* **Modifying a vector held in an environment copies it** (`e$v[i] <- x`
  costs O(length)). Unbind it while modifying:
  `v <- e$v; e$v <- NULL; v[i] <- x; e$v <- v` (O(1)), or keep it in a
  closure environment and use `<<-`.
* Grow results by preallocating, or by collecting pieces in a list and
  `unlist`/`paste0(collapse = "")` once.

## Tools and the command line

Each tool is a function `app_<tool>(args)` (args: character vector,
without the program name) returning the exit status; it is a line-by-line
port of the C program, written as

```r
app_wfdbcat <- function(args = character(0)) app_run(.wfdbcat_main, c("wfdbcat", args))
.wfdbcat_main <- function(argv) { ...; 0 }      # argv[1] is the program name
```

`app_run(main, argv)` returns `main`'s value (NULL counts as 0), or the
status given to `cexit(status)` (C `exit`, which unwinds with a condition
of class `wfdbx_exit` — not an error, so `tryCatch(error = )` in tool code
does not catch it), and flushes the standard output. R errors propagate to
`cli_main`, which prints `wfdbx: error: MESSAGE` and returns 1
(`WFDBX_DEBUG=1` adds the call stack). Messages that include the program
name use `argv[1]`, the tool's name. Every `app_<tool>` function is a tool
for `cli_main`, `wfdbx_tool` and `--list`. In legacy mode, `oannclose`
sorts out-of-order annotation files by running the `sortann` tool in a
separate process, `system(paste(tool_command("sortann"), ...))`, as the C
library does (`tool_command` gives `'Rscript' 'path/wfdbx.R' 'sortann'`;
base R has no way to run a program without a shell: `system2`, too, passes
a command line to `/bin/sh`, so the arguments are quoted with
`shell_quote`); in modern mode it sorts them in the same process
(`.ann_sort_file`).

## Foundation internal API

Not exported (reach them with `wfdbx:::name` from outside); every function
has a comment describing it in its source file.

`cstd.R` — C emulation:

| Function | C equivalent / purpose |
|---|---|
| `cint32`, `cuint32`, `cint16`, `cuint16`, `cint8`, `cuint8` (vectorized) | assignment to `int`, `unsigned`, `short`, `unsigned short`, `char`, `unsigned char` (exact for \|x\| < 2^53) |
| `cdiv(a, b)`, `cmod(a, b)` | integer `/` and `%` |
| `d2i(x)`, `d2l(x)` | `(int)x`, `(long)x` (INT_MIN / LONG_MIN for NaN and out of range) |
| `cbytes(s)`, `cstr(b)`, `craw(s)` | byte codes of a C string (up to NUL); C-string view of a raw buffer; raw bytes of a string |
| `strtol(s, base = 10, pos = 1, lmin, lmax)` → `c(v, end)`; `strtod(s, pos = 1)` → `c(v, end)`; `atoi(s)`; `atof(s)` | the same, glibc-exact (`s`: character, raw or integer byte codes) |
| `t <- strtok_new(s)`; `strtok_next(t, delims)`; `strtok_rest(t)` | `strtok(s, d)` then `strtok(NULL, d)`; NULL is C NULL |
| `r <- csscanf(s, fmt)` → `r$n` (C return value, -1 for EOF), `r$v` (list of the assigned values) | `sscanf`; unassigned variables keep their old values in the caller |
| `fgets_lines(data, size, as_raw = FALSE)` | successive `fgets(buf, size, fp)` results (character, or list of raw) |
| `g <- glibc_rand_new(seed)`; `glibc_rand(g, n = 1)`; `glibc_srand(g, seed)` | glibc `srand`/`rand` (`RAND_MAX`) |
| `csprintf(fmt, ...)` (raw), `csprintf_v(fmt, ...)` (character vector) | `sprintf` |
| `cout(x)`, `cout()`, `cerr(x)`, `cprintf(fmt, ...)`, `ceprintf(fmt, ...)` | `fwrite`/`printf` to stdout (buffered; `cout()` flushes), to stderr |
| `stdin_bytes()` | the whole standard input (raw; read once; `WFDBX_STDIN=file` substitutes a file, for tests) |
| `stdin_freopen(name)` | `freopen(name, "rb", stdin)` (`a2m`, `ad2m`): `stdin_bytes()` then reads the file, and the library opens `"-"` as a regular, seekable file; FALSE if unreadable (a directory counts as unreadable) |
| `cgetenv(name)` | `getenv` (NULL if unset) |
| `cexit(status)`, `app_run(main, argv)` | `exit` inside a tool; running a tool |
| constants `INT_MAX`, `INT_MIN`, `UINT_MAX`, `LONG_MAX`, `LONG_MIN`, `SHRT_MAX`, `SHRT_MIN`, `DBL_MAX`, `RAND_MAX` | |

`wfdbfile.R` — the `WFDB_FILE` (an environment; `is_wfdb_file(f)`):
`wf_read(f, n)` (raw), `wf_readall(f)`, `wf_getc(f)` (-1 at EOF),
`wf_getline(f)` (raw, with its newline; `raw(0)` at EOF), `wf_write(f, b)`
(raw or character), `wf_putc(f, c)`, `wf_printf(f, fmt, ...)`,
`wf_g16(f)`, `wf_g32(f)`, `wf_p16(f, x)`, `wf_p32(f, x)`,
`wf_seek(f, off, whence)` (0/1/2 = SEEK_SET/CUR/END; positions beyond the
end of the file are allowed as in C), `wf_tell(f)`, `wf_flush(f)`,
`wf_feof(f)`, `wf_ferror(f)`, `wf_clearerr(f)`, `wf_close(f)`; fields
`name`, `type` (`WFDB_LOCAL`, or `WFDB_NET` for a remote file read into
memory: a `rawConnection`, with its `size`), `is_std`, `mode` (`"r"`,
`"w"`, `"a"`). Reads are buffered
in 64 KiB blocks (large reads go directly to the connection); writes are
collected and written in blocks; output files can seek and overwrite. The
standard input (`"-"` for reading) is served from `stdin_bytes()`; as in
C, it is seekable if it is a regular file (`< file`; `stdin_is_file()`,
from `/proc/self/fd/0`), not if it is a pipe (or `WFDBX_STDIN`).  Writes to
the standard output (`"-"` for writing) go to `cout`.

`wfdbio.R` — state `.wfdb_io` (`wfdbpath`, `path_prefix`, `path_type`,
`error_print`, `error_flag`, `error_message` (raw), `wfdb_filename`,
`irec`, `stdin_file`, `stdout_file`, `driver`, and (wfdb-x) the settings
`input_dir`, `output_dir`, `network` with their environment values and
flags, `fetched` (the cache of remote files, by URL); `wfdbio_reset()`):
`wfdb_error(fmt, ...)`, `wfdb_open(s, record, mode)`,
`wfdb_fopen(fname, mode)` (`"rb"`, `"wb"`, `"ab"`), `wfdb_parse_path(p)`,
`wfdb_addtopath(s)`, `getiwfdb(p)`, `wfdb_checkname(p, what)`,
`wfdb_setirec(p)`, `wfdb_getirec()`, `wfdb_striphea(p)`,
`.is_absolute_path(s)`, `.is_url(s)`, `.expand_home(name)`,
`.resolve(name, output)` (the one location of a name, normal mode),
`.open_at(p, s)` (both spellings of a name at one location),
`.open_in(dir, s, name, record)` (a file named in a header, with the
containment check), `.in_header_dir(name)`, `.dirname(name)`,
`.fetch(url)`, `.fetch_open(url)`, `tool_command(tool)`, `shell_quote(s)`;
constants
`WFDB_LOCAL`, `WFDB_NET`, `WFDB_READ`, ..., `WFDB_APPEND`, `DEFWFDB`, `DEFWFDBCAL`,
`WFDB_MAXRNL`, `WFDB_VERSION`. Public: `getwfdb`, `setwfdb`, `resetwfdb`,
`wfdbquiet`, `wfdbverbose`, `wfdberror`, `wfdbfile`, `wfdbmemerr`,
`wfdbversion`, `wfdbldflags`, `wfdbcflags`, `wfdbdefwfdb`,
`wfdbdefwfdbcal`, `wfdbx_set_input_dir`, `wfdbx_get_input_dir`,
`wfdbx_set_output_dir`, `wfdbx_get_output_dir`, `wfdbx_set_network`,
`wfdbx_get_network`.  The resolution rules and the settings are those of
the C reference and the Python port (docs/DIVERGENCES.md); `signal.R`
opens headers with `.open_header` (noting `hdr_dir`, the directory of the
header, and `msrec_dir`/`msrec_name` for the segments of a multi-segment
record) and signal files with `.open_in(hdr_dir, ...)`.

`ecgcodes.R` — the code constants (`NORMAL`, ..., `ACMAX`, `APUNDEF`, ...;
`ecgcodes()` returns them as a list); the vectorized mapping functions
`isann`, `isqrs`, `map1`, `map2`, `ammap`, `mamap(a, s)`, `annpos` and the
setters `setisqrs`, `setmap1`, `setmap2`, `setannpos` (which store a C
`char`), also under their C names `wfdb_isann`, ...; tables in `.ecgmap`
(`qrs`, `mp1`, `mp2`, `annp`, indexed by code + 1; `ecgmap_reset()`); the
structure constructors `siginfo()`, `anninfo()`, `annotation()`,
`calinfo()`, `seginfo()` (keyword arguments, C defaults; for an array use
`replicate(n, siginfo(), simplify = FALSE)`). The mnemonic tables
(`annstr`, ...) belong to the annotation module.

## The signal module

`signal.R` (port of `lib/signal.c`), `wfdbinit.R` (`wfdbinit`, `wfdbquit`,
`wfdbflush`), `highlevel.R` (`read_record`, `read_header`, `write_record`).

State: the environment `.sig` (all file-scope variables of `signal.c`;
`sig_reset()` restores the initial state, for tests). Objects:

| Object | Representation |
|---|---|
| `hsd` | list of `list(info, start, skew)` (header signal descriptions; grows, never shrinks, as in C) |
| `isd`, `vsd`, `osd` | lists of environments: `info` (a `siginfo` list), `samp`, `skew` (`isd`/`vsd` also `gvindex`, `gvcount`) |
| `igd` | list of environments (input groups = signal files): `data`, `datb`, `fp`, `start`, `bsize`, `buf` (raw), `bp` (bytes of `buf` consumed), `be` (valid bytes in `buf`), `count`, `seek`, `initial_skip`, `stat`, `flac` |
| `ogd` | list of environments (output groups): `data`, `datb`, `fp`, `start`, `bsize`, `buf` (raw, preallocated), `nb` (bytes pending in `buf`), `obuflen`, `count`, `seek`, `force_flush`, `nrewind`, `flac` |
| `smi` | the signal map of variable-layout records, as vectors (one element per sample of a frame) |

Signal and group numbers are 0-based as in C (signal `s` is
`isd[[s + 1]]`). Internal functions mirror the C ones (`.readheader`,
`.edfparse`, `.isgsetframe`, `.getskewedframe`, `.getframe`, `.rgetvec`,
`.getvec`, `.sigmap_init`, `.osigclose`, `.wfdb_osflush`, ...); the
readers `.r8`, `.r16`, ..., `.r311` take an input group, the packers
`.p212`, `.p310`, `.p311` update an output group's state and return the
bytes completed, `.og_put(og, bytes)` buffers output bytes.

Public API conventions (beyond the C names):

* `isigopen(record, nsig)` and `osigopen(record, nsig)` return
  `list(nsig, si)`; `osigfopen(siarray, nsig)` takes a list of `siginfo`
  lists; `getvec()` and `getframe()` return `list(stat, v)` (the vector is
  kept between calls, as a C caller's array would be); `putvec(v)`.
* `getframes(n)` returns `list(v, stat)` (matrix, one row per getvec
  vector); exactly equivalent to `n` getvec calls. `.bulk_frames(n)`
  decodes whole blocks with `readBin`/vector arithmetic (all formats,
  multi-frequency records in both modes, `WFDB_GVPAD`, FLAC through
  `flac_navail` and `flac_getsamps`); it declines (NULL, or fewer vectors) where a frame needs
  special handling (end of file, checksum frame, partial bit-packed group,
  skew, variable layout, `setifreq`, prolog not skipped, non-seekable
  input), and `getframes` falls back to `getvec` for the next vector.
  It reads the signal files in whole blocks of the input buffer size and
  leaves each group's buffer as the C library's buffer fills would
  (`.bulk_setbuf`): at the end of a file, the readers return bytes of the
  last block read, which some tools write (e.g. `wfdb2mat` writes the
  vector of the `getvec` call that fails).  FLAC samples are taken only
  once the number of frames available in every group is known, so that
  none is lost when another group is shorter.  The layout of the open
  signals (groups, formats, sample masks) is computed once per `isigopen`
  (`.bulk_layout`, cached in `.sig$bulk_layout`), which keeps the fixed
  cost of a call small (tools such as `sigamp` make many small reads).
* `.getframes_full(n)` (internal) is `n` calls of `getframe` (complete
  frames, `tspf` columns; `.bulk_frames(n, full = TRUE)`), used by
  `mit2edf` and `rdedfann`.
* `putframes(m)` = `putvec` on each row of `m`, vectorized (format 8 slew
  clipping and the packing state of bit-packed formats included).
* `.setheader()` also returns the caller's `siarray` as C leaves it (C's
  `setheader` cuts `units` and `desc` at their first token).
* `sample()` is exported as `wfdb_sample()` (so as not to mask
  `base::sample`); the internal name is `sample`.
* `.fmstimstr_v(t, f)` and `.ftimstr_v(t, f)` are vectorized `mstimstr` and
  `timstr` (used by `rdsamp`, `sigamp`, `rdann` and `ann2rr`).

Used by the annotation module: `sampfreq(NULL)`, `getspf()`, `getifreq()`,
`strtim()`, `timstr()`, `mstimstr()`, `setsampfreq()`, `wfdbquit()`. The
signal module calls the annotation module only through `getafreq`,
`setafreq` (in `.edfparse` and `setifreq`), `annopen` (`wfdbinit`),
`wfdb_anclose` (`wfdbquit`) and `wfdb_oaflush` (`wfdbflush`).

### FLAC glue (contract with `flac.R`)

Formats 508, 516 and 524 are handled by the `flac_*` functions of
`flac.R` (ports of `python/src/wfdbx/_flac.py`; the MATLAB counterparts
are `matlab/+wfdbx/+internal/flac_*.m`), whose contract is given in
[FLAC signal groups](#flac-signal-groups-flacr).  The FLAC code keeps its
own state in `ig$flac` / `og$flac` (`NULL` means "not a FLAC group") and
may use `ig$fp`, `ig$start`, `ig$stat`, `ig$count`, `og$fp`, `og$bsize`;
it must not use `ig$buf`/`bp`/`be` or `og$buf`/`nb`.

## Annotations (`annot.R`, `calib.R`, `highlevel_annot.R`)

As in the MATLAB/Octave port, an input annotation file is read completely
by `annopen` and decoded with vector operations (`.ann_parse`: MIT words
are walked with pointer doubling over the `SKIP`/`AUX`/zero words, so
that `AUX` data is never mistaken for annotation words; AHA records are
fixed-size) into the sequence of values that the C library's "current
annotation" (`ia->ann`) takes in one pass over the file: times in file
units (`tt`), `anntyp`, `subtyp`, `chan`, `num` (`chan` and `num` carry
over, as in C), the `AUX` tokens of each annotation, and whether the file
ends inside the last annotation (`eofend`: `getann` then reports
`unexpected EOF`).  `getann` steps through that sequence and emulates the
771-byte aux ring buffer of `annot.c` exactly (`annot->aux` points into
it in C, so stale bytes after a string and strings overwritten by the next
read are visible to applications).  Input annotators are environments in
`.ann$iad` (fields `P` (decoded file), `k` (index of the current
annotation), `ann`, `ann_tt`, `pann` (pushback), `buf`, `index`,
`auxpos`, `tmul`, `afreq`, ...); output annotators in `.ann$oad`.

* `getann(an)` returns `list(stat, annot)`; `ungetann`, `putann` take an
  `annotation()` (its `aux` a raw vector with the length byte first; a
  character string is also accepted by `putann`).
* Bulk paths: `.getann_bulk(an, m, noaux, nofail)` is exactly `m` calls of
  `getann` (vectors `time`, `anntyp`, ..., `aux` list; `nofail = TRUE`
  stops before the failing call, so that its message is printed only if C
  makes that call); `.putann_bulk(an, A)` is exactly a series of `putann`
  calls (MIT words encoded with vector operations).  The tools read in
  blocks of 4096 annotations (1 for AHA files, where reading an
  annotation may print a message) and format their output with vector
  operations: `.fmstimstr_v(t, .tfreq())` (signal.R), `.aux_strings(aux)`.
* `wfdb_anclose()` and `wfdb_oaflush()` are the hooks that `wfdbquit()`
  and `wfdbflush()` (signal module) call.  The annotation module calls
  the signal module's `sampfreq(NULL)`, `getspf()`, `getifreq()` (time
  resolution: `setiafreq`, the modification labels read by `annopen`),
  `strtim`, `mstimstr` (tools) and `newheader` (`rr2ann`).
* The mnemonic and description tables, the flags of modified codes and
  the output time resolution (`setafreq`) survive `wfdbquit`, as in C;
  `annot_reset(tables = TRUE)` restores them (tests).
* Out-of-order output files are sorted when closed (wfdb-x) in the same
  process by `.ann_sort_file(fname, aname)`: it reads the very file just
  written (`oa$fname`, the name `wfdb_open` created, including any output
  directory) into a private input annotator (`.ann_new_ia`; the
  definitions go to a private table with the default mnemonics,
  `.ann_read_table(ia, defs)`), orders the annotations with
  `.ann_sort_order` (the `insert_ann` list of `sortann.c`, shared with the
  `sortann` tool; wfdb-x: its head is never compared with an annotation,
  so that an out-of-order time-0 annotation is not lost, unless `legacy =
  TRUE`, which the tool passes in legacy mode), and rewrites the file with a private output annotator
  (`.ann_new_oa`, `.ann_put_table(oa, n, freq, defs)`,
  `.putann_bulk(..., oa = )`), byte for byte as `sortann` does; the
  library's annotators and tables are not touched.  In legacy mode,
  `.ann_run_sortann` runs `tool_command("sortann") --legacy -r. RECORD -a
  ANNOTATOR` with `system()`, as the C library does (prefixed with
  `cd 'OUTDIR' &&` when an output directory is set).
* `calib.R`: the calibration list (`calopen`, `getcal` returning
  `list(stat, cal)`, `putcal`, `newcal`, `flushcal`).
* `highlevel_annot.R`: `read_annotations` (a data frame with attributes
  `record`, `annotator`, `fs`) and `write_annotations` (its `sort`
  argument sets `.ann$sort_override` for the duration of the call, after
  the `wfdbquit()` that closes the annotators opened before it;
  `oannclose` uses it instead of `WFDBANNSORT` when it is not `NULL`).

Timings (R 4.3, a file of 400,000 annotations of which 57,000 have aux
strings, `Rscript` command line including startup): `rdann` 4.4 s (17.8 MB
of output; the C tool 0.2 s, Python 2.1 s), `ann2rr` 1.2 s, `ann2rr -i s
-V T -v` 5.7 s, `sortann` 2.8 s, `wrann` 3.3 s (Python 7.0 s), `rr2ann`
1.0 s; in a session `read_annotations` 2.5 s and `write_annotations`
1.3 s.  The emulation of the aux ring buffer (one R call per aux string)
is about a quarter of the reading time of such a file.

## FLAC signal groups (`flac.R`)

`flac.R` is a FLAC decoder and encoder in R (no libFLAC): the decoder
handles all of FLAC (Rice codes decoded with vector operations, LPC
restoration one sample at a time); the encoder writes exactly the bytes of
the Python encoder (fixed predictors, Rice partitions; MD5 signature in
STREAMINFO, `md5_raw` in R, or `tools::md5sum` for inputs of 4 KiB or
more).  `flac_decode(raw)` decodes a whole stream.  The signal module uses it through these functions (same
arguments as in the Python and MATLAB ports), on its input and output
group environments:

| Function | Contract |
|---|---|
| `flac_isopen(ig, hs, ns)` | `ig`: input group with fields `fp` (open WFDB_FILE), `start` (samples to skip at the start of the stream, per signal), `stat`, `count`; `hs`: list of the `ns` signals' header data, `hs[[i]]$info$fmt` (508, 516, 524) and `hs[[i]]$info$spf`.  Checks `ns <= 8` and equal `spf`, sets `ig$flac` (decoder state) and `ig$count <- 0`; returns 0 or -1 (message printed).  The stream is decoded on the first read or seek. |
| `flac_getsamp(ig)` | the next sample, in WFDB frame order (for each frame, `spf` samples of each signal in turn).  At the end: 0, `ig$stat <- 0` (the first time, `getvec: warning: N samples left over at end of file` if the samples do not fill a frame); after a decoding error (message `getvec: unable to decode FLAC ...`): 0, `ig$stat <- -2`.  `ig$stat` is not changed otherwise. |
| `flac_getsamps(ig, n)` | exactly `n` calls of `flac_getsamp` (`n = Inf`: all the remaining samples, without reads past the end): `list(v = samples, st = ig$stat after each call)`. |
| `flac_navail(ig)` | the number of samples that remain to be read (the stream is decoded first if needed), or -1 after a decoding error. |
| `flac_isseek(ig, t)` | position at frame `t` (sample `t * spf + ig$start` of each signal); sets `ig$stat <- 1`, `ig$count <- 0`; returns 1, or -1 (`ig$stat <- -1`) if out of range or undecodable. |
| `flac_isclose(ig)` | with `WFDB_FLAC_CHECK_MD5` set at open, checks the MD5 signature if the whole stream was read without seeking; returns 0, or -1 (`isigclose: warning: incorrect MD5 hash in FLAC input`).  The caller closes `ig$fp`. |
| `flac_osinit(og, si, ns)` | `og`: output group with fields `fp`, `bsize`, `buf`; `si`: list of the `ns` `siginfo()` (`fmt`, `spf`).  Checks as above (`osigfopen: ...` messages), sets `og$flac` and `og$bsize <- ns * spf * 4`; returns 0 or -1. |
| `flac_osopen(og)` | writes the stream header to `og$fp` (STREAMINFO completed at close, VORBIS_COMMENT vendor `wfdb-x`); returns 0. |
| `flac_putsamp(v, fmt, og)`, `flac_putsamps(v, fmt, og)` | append one sample / a vector of samples in WFDB frame order (values wrapped to 8, 16 or 24 bits as `fmt` says); a frame of 4096 samples per signal is encoded and written whenever available; return 0. |
| `flac_osclose(og)` | encodes the remaining complete frames (an incomplete last frame is discarded), rewrites STREAMINFO if `og$fp` can seek, sets `og$flac <- NULL` and `og$buf <- raw(0)`; returns 0.  The caller closes `og$fp`. |

## Details of user-visible behavior

The README leaves out these details, which matter when changing the code.

* **Read errors of `read_record`.** Reading stops with the error "can't
  read signal data of record REC (getvec status S)" when `.getframes`
  ends with a status below -1 other than -4 (for example -3, a signal
  file shorter than its header says, or a decoding or I/O error).
  Reaching the end of the record (-1) before `sampto` is not an error.
  This applies in legacy mode too, since the high-level API is a wfdb-x
  addition; `getvec`, `getframes` and the tools are unchanged.
* **Checksum errors.** Status -4 (the samples are complete, but their sum
  does not match the header's checksums) is a warning, not an error:
  `.getframes(n, keep_checksum_frame = TRUE)` keeps the last frame, and
  `read_record` sets `.sig$cksum_quiet` during the read so that getvec's
  own "getvec: checksum error in signal N" is not printed. `checksum_ok`
  is `FALSE` whether or not the warning is on.
* **Output file identity.** `osigfopen`/`osigopen` refuse an output signal
  file that is one of the files of the open input record, with "osigfopen:
  output file NAME is also an input file" (or `osigopen: ...`) and status
  -3. R has no inode numbers in `file.info()`, so `.same_file` compares
  normalized paths (`normalizePath`; case-insensitive on Windows) and, for
  two files of equal size and modification time only, the "dev:ino" given
  by the `stat` program (`stat -L -c` on GNU, `stat -L -f` on BSD). Legacy
  mode does not check.
* **Downloads.** `.fetch(url)` uses the system program `curl` if
  `Sys.which("curl")` finds it, and base R's `url()` otherwise. Redirects
  are followed, an HTTP status of 400 or more is a failure, and reading
  gives up if connecting takes 30 s or no data arrives for 30 s, with no
  limit on the total time. Each URL is requested at most once per process,
  failures included.
* **`write_annotations(sort = TRUE)` in legacy mode** runs the `sortann`
  tool, as the library's legacy sorting does.
* **Timings** (R 4.3, `Rscript` command line including start-up): `rdsamp`
  prints a 650,000-sample, 2-signal format 212 record in about 2 s, and
  `rdann` 400,000 annotations in about 4.5 s. A `getframes` call has a
  fixed cost of about 0.05 ms (`sigamp -w 0.01` makes 6,000 measurements
  of a 1-minute record in about 1.7 s). `write_record` writes 216,000
  frames of 2 signals in about 0.03-0.08 s, and `read_record` reads them
  back in about 0.02-0.06 s.

## Testing

```sh
python3 tests/conformance/harness.py check --impl r      # conformance
Rscript r/tests/run_tests.R [PATTERN]                    # unit tests
R CMD build r && R CMD check --no-manual wfdbx_*.tar.gz  # package check
```

`tests/run_tests.R` loads the sources (or the installed package, under
`R CMD check`) and runs `tests/unit/test_*.R`, each evaluated as one block
(so `on.exit` works) in an environment whose parent is the package
environment, with the helpers `check(cond, label)`,
`expect_equal(got, expected, label)` (`identical`), `expect_error(expr,
label)` and the variables `.mode` (`"source"` or `"installed"`) and
`.rdir`. Tests that create files work in a temporary directory.

`csprintf` was verified against glibc's `printf` over about 1.5 million
random cases (formats with random flags, widths, precisions, `*`, length
modifiers; random doubles of all magnitudes, special values, halfway
cases; integers up to 2^53 for all integer conversions; `%c`, `%s` with
random bytes and NULL), and `csprintf_v` over the same values; `strtod`
over 1.3 million random strings (long digit strings, extreme exponents,
subnormals, overflow, hexadecimal floats, `inf`/`nan`, trailing garbage;
values and end positions). The generator programs are not part of the
repository; the unit tests keep representative cases.

`test_annotations.R` ports the annotation, calibration and mnemonic
tests of the Python implementation (C-derived values) and checks the
vectorized paths against direct references: the MIT decoder against a
port of `getann`'s word-by-word reading loop on random and truncated
files, `.getann_bulk` against repeated `getann` (random block sizes,
random files with aux strings: the ring buffer), `.putann_bulk` against
repeated `putann`, `wrann`'s vectorized parser against its line-by-line
parser.  `test_flac.R` decodes the FLAC records of `tests/data`
(digests of the samples from the Python decoder), checks that the
encoder's output is identical to the Python encoder's (sizes and MD5 of
the streams for several signals, formats and frame sizes), MD5 (RFC 1321
test suite) and the signal-group functions.  The data-dependent tests are
skipped when `tests/data` is not available (installed package).
