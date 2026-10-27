# wfdb-x for MATLAB and GNU Octave: implementation notes

These notes describe how the MATLAB/Octave implementation is organized. They
complement [`docs/porting-guide.md`](../docs/porting-guide.md) (the C
semantics every implementation must reproduce). The Python implementation
(`python/src/wfdbx/`) is the model: the MATLAB code follows its structure,
module by module, and must behave identically (the conformance suite checks
this).

## Requirements

* Runs unchanged on **GNU Octave 6 or later** and **MATLAB R2019b or later**
  (no toolboxes). Only language features common to both are used:
  functions, package folders (`+wfdbx`), `classdef` handle classes, `persistent`
  variables, `fopen`/`fread`/`fwrite`. No `string` objects (use `char`;
  the public functions convert MATLAB strings given as arguments with
  `isa(x, 'string')` and `char`, or `wfdbx.internal.strarg`), no
  `arguments` blocks, no Octave-only syntax (`#` comments, `!`, `++`, `+=`,
  double-quoted strings, `end_if`/`endfunction`, default arguments, ...).
* No dependencies.

### Portability rules

Only Octave 8 is available for testing here, so these rules (learned from
an audit of the code against the documentation of both products) must be
followed by reading, not by running MATLAB:

* **Functions.** Only core functions present in both MATLAB R2019b and
  Octave 6.1; when in doubt, use the older one. Not available in Octave 6
  (forbidden): `string`/`strings`/`"..."`, `contains`, `startsWith`,
  `endsWith`, `newline`, `isStringScalar`, `datetime`/`duration`, `rng`,
  `isenv`, `unique(..., 'stable')`, `sum(..., 'all')`, `'omitnan'`
  options, `fopen` with an encoding argument, `arguments` blocks. Usable:
  `isfolder`/`isfile` (Octave 5, R2017b), `repelem`, `cummax`/`cummin`,
  `pow2`, `typecast`, `accumarray`, the legacy `cellfun('isempty', ...)`
  forms. Octave-only functions (`argv`, `OCTAVE_HOME`, `fflush`, `hash`,
  `isguirunning`, `rows`, `columns`, `index`, `printf`, `puts`, `fdisp`,
  `unwind_protect`, ...) may be used only in a branch guarded by
  `wfdbx.internal.is_octave()` with an equivalent MATLAB branch (the
  current ones: `cout`/`cerr`/`WFDBFile.flush` (`fflush`), `stdin_bytes`
  (reading fid 0), `md5` (`hash`; Java in MATLAB, `md5_pure` otherwise),
  `tool_command`, `wfdb_fopen` (MATLAB can open directories)).
* **`&&` and `||`** need scalar operands. Octave applies `all()` to an
  array operand (and treats `[]` as false) where MATLAB throws an error,
  so a non-scalar operand passes the tests and fails in MATLAB.
* **Indexing.** No indexing of a call result or of an indexing result
  (`size(x)(2)`, `a(1)(2)`, `f(x).field`, `[1 2 3](k)`, `'abc'(1)`).
* **`bitand`/`bitor`/`bitxor`/`bitshift`** only on non-negative integer
  values below 2^53 (or on integer classes): MATLAB throws an error for a
  negative double, Octave silently returns a wrong value (`bitand(-1,
  4095)` is 0). Use `mod(x, 2^k)` for `x & (2^k - 1)` when `x` may be
  negative.
* **`regexp` on data.** Octave's `regexp` works on UTF-8 (a two-byte
  character is one `.`) and throws an error for invalid UTF-8 (any lone
  byte above 127), MATLAB's on characters. Apply regular expressions only
  to ASCII text, or to a copy in which the bytes above 127 are replaced by
  a character that no pattern tells apart from them (e.g. `char(127)`),
  and take the strings from the original (see `wrann`, `strtod`).
  Patterns may use `(?:...)`, `(?!...)`, possessive quantifiers, `\d`,
  `\t`, `\xNN`; `.` matches newlines in both. `$` also matches before a
  final newline in Octave (PCRE), not in MATLAB: do not rely on it.
* **Files.** Always open files in binary mode (`'rb'`, `'wb'`, `'ab'`):
  `'r'`/`'w'` are text mode in Octave on Windows. Read text as bytes with
  `fread(..., 'uint8=>uint8')` (MATLAB's `fgets`/`fgetl`/`fscanf`
  transcode characters). `exist(name, 'file')` and `exist(name, 'dir')`
  search the MATLAB path for relative names: use `isfile`/`isfolder` for
  files relative to the current directory (`exist` only with absolute
  names, or `'builtin'`).
* **`system`** prints the output of the command on the standard output in
  MATLAB and lets it through in Octave: capture it (`[s, out] =
  system(cmd)`) and write it explicitly.
* **Environment.** `getenv` returns `''` for unset and empty variables
  alike (`isenv` is R2022b and not in Octave): `cgetenv` reports both as
  unset everywhere.
* **Strings vs characters.** Character codes are 0-255 (bytes); MATLAB's
  `upper`/`lower` also convert Latin-1 letters, Octave's only ASCII: use
  them only on ASCII text (option names, format conversions).
* **Integers.** Do not mix integer classes in one operation or
  concatenation, and do not use `*`, `/`, `^` (matrix operations) on
  non-scalar integer arrays (MATLAB throws errors). 64-bit integer
  arithmetic saturates in both.

## Layout

| Path | Contents |
|---|---|
| `+wfdbx/*.m` | the WFDB library API: one function per C function (`wfdbx.isigopen`, `wfdbx.getvec`, `wfdbx.strtim`, ...), annotation code constants (`wfdbx.NORMAL`, ...), and the high-level API (`wfdbx.read_record`, `wfdbx.read_annotations`, `wfdbx.write_record`, `wfdbx.write_annotations`, `wfdbx.check_record`) |
| `+wfdbx/+internal/` | implementation: library state (handle classes), C standard library emulation, file I/O, signal formats, FLAC codec |
| `+wfdbx/+apps/<tool>.m` | the command-line tools: `status = <tool>(args)` (`args` without the program name) |
| `bin/wfdbx_cli.m` | Octave command-line driver: `octave-cli bin/wfdbx_cli.m TOOL ARGS...` |
| `bin/wfdbx_matlab.sh` | MATLAB command-line driver (`matlab -batch`) |
| `tests/` | unit tests (`run_tests.m`) |

Package functions call each other with their full names (`wfdbx.internal.x`),
as both MATLAB and Octave require.

Every `.m` file starts with its `function` (or `classdef`) line (the
package listing `+wfdbx/Contents.m` and the script `bin/wfdbx_cli.m`
start directly with their help), an H1 line (`%NAME Short
description.`) and help text in the MathWorks style (syntax lines with
upper-case argument names, inputs, outputs and return codes, an example
where useful, a "See also" line), and as the last paragraph of the help one
line on its origin: "Translation of the C function isigopen() (lib/signal.c,
WFDB 10.7.0): same arguments and results." (with "Differences: ...; see
docs/DIVERGENCES.md." where wfdb-x behaves differently; for a tool, "the C
program rdsamp (app/rdsamp.c, ...): same options and output"; for an
internal function, "Translation of the C function edfparse() (...)." or
"Part of the translation of lib/signal.c (WFDB 10.7.0)."), or "Part of
wfdb-x; not in the original WFDB package." Then, after a blank line, as a
separate comment block that `help` does not show, comes the file header,
with the exact authors and years of [`docs/AUTHORS.md`](../docs/AUTHORS.md):

```matlab
% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.
```

* "Changes from the original" lists, in one short sentence each, how the
  file differs from the C code ("Each change is marked "wfdb-x:" in the
  code; docs/DIVERGENCES.md gives the reasons."), or says "none, apart from
  the language.";
* tools (`+wfdbx/+apps/`) say "original program" and "Original C program:
  app/<tool>.c", and "This program is free software";
* wfdb-x's own code (C library emulation, high-level API, drivers, FLAC
  codec, tests) says, after the first sentence, "It has no counterpart in
  the original package." (tests: "It tests wfdb-x; it has no counterpart
  in the original package."), then "Copyright (C) 2026 Reza Sameni." and
  the license paragraph.

Only `%` comments; every
function ends with `end`.

Numeric constants are named (local variables at the top of the function,
with the C name where C has one: `ACMAX = 49;`, `WFDB_DEFGAIN = 200;`,
`SKIP = 59 * CODE1;`) or explained by a short comment; a local variable
costs nothing, while a call of `wfdbx.ACMAX()` costs about 10
microseconds. Shared tables are functions (`wfdbx.internal.fmt_bits`: the
sample width of each format).

Do not give a package function the name of an Octave *built-in* function
(e.g. `isspace`, which is why the C `isspace` is `cisspace`): Octave then
prints a "shadows a built-in function" warning on the standard error
output, which breaks the conformance tests. Check new names with
`exist(name, 'builtin')` in Octave.

## Data representation

* **Samples and times** are `double` values (exact for all 32-bit sample
  values and for times up to 2^53). Where C arithmetic wraps around
  (`int` overflow, `unsigned` conversions, `short`/`char` casts), the
  helpers of `wfdbx.internal.c*` (`cint32`, `cuint32`, `cint16`, `cint8`,
  `cuint8`, `cdiv`, `cmod`, `d2i`) are applied explicitly. Never rely on
  MATLAB integer classes for wrap-around: they saturate.
* **Strings** are `char` row vectors whose characters are the bytes of the
  C strings (codes 0-255, i.e. ISO-8859-1). Files are read with
  `fread(..., 'uint8=>uint8')` and converted with `char(...)`; text is
  written with `fwrite(fid, uint8(s))`. Never use `fprintf`/`fgetl` on file
  contents (MATLAB would transcode non-ASCII bytes).
* **Escapes**: in MATLAB, `'\n'` is a backslash and an `n`. Write control
  characters as `char(10)`, `sprintf('\r\n')`, etc. when comparing or
  building strings (and for `Strtok` delimiters). Only *formats* given to
  `csprintf`/`cprintf`/`ceprintf`/`wfdb_error`/`sprintf` interpret `\n`,
  `\t`, `\\`, as C string literals do; data must therefore always be
  passed through `%s`, never inside a format.
* **C positions** are 1-based: `[v, e] = strtol(s, base, pos)` returns the
  index `e` just past the number (C's end pointer + 1); "no conversion" is
  `e == pos`.
* **C `NULL` strings** are `[]` (an empty double); empty C strings are `''`.
  Test with `ischar`.
* **Structures** of the C API (`WFDB_Siginfo`, `WFDB_Anninfo`,
  `WFDB_Annotation`, `WFDB_Calinfo`, `WFDB_Seginfo`) are MATLAB `struct`s
  with the C field names; constructors `wfdbx.siginfo()`, `wfdbx.anninfo()`,
  `wfdbx.annotation()` return them with C's zero values. An annotation's
  `aux` is `[]` or a `uint8` row vector whose first element is the length
  of the data that follows (as in C and in the Python port).
* Functions that fill a C array supplied by the caller return the filled
  array instead: `[nsig, si] = wfdbx.isigopen(record, nsig)`,
  `[stat, v] = wfdbx.getvec()`, `[stat, annot] = wfdbx.getann(an)`.
* `wfdbx.siginfo(n)`, `wfdbx.annotation(n)` and `wfdbx.seginfo(n)` return
  1-by-n struct arrays (default n = 1); `wfdbx.anninfo(name, stat)` and
  `wfdbx.calinfo()` return one structure. `siginfo` fields start as in the
  Python port (`spf` = 1, strings `[]`).
* **Constants.** The file modes are functions: `wfdbx.WFDB_READ()` (0),
  `WFDB_WRITE` (1), `WFDB_AHA_READ` (2), `WFDB_AHA_WRITE` (3),
  `WFDB_APPEND` (4). Internal code may use the literal values with a
  comment (`wfdb_open(s, rec, 0)  % WFDB_READ`), as a function call costs
  about 10 microseconds in Octave.
* **Annotation codes** (`lib/ecgcodes.h`) exist in two forms: one function
  per code (`wfdbx.NORMAL()`, `wfdbx.PVC()`, ..., `wfdbx.ACMAX()`, and the
  position codes `wfdbx.APUNDEF()` ... `wfdbx.APALOW()`), for users and
  for code that runs once; and `C = wfdbx.ecgcodes()`, a structure with all
  of them as fields (cached), for library code and loops (`C.NORMAL`; a
  field access is about 10 times faster than a function call in Octave).
  The mapping functions `wfdbx.isann`, `isqrs`, `setisqrs`, `map1`,
  `setmap1`, `map2`, `setmap2`, `ammap`, `mamap`, `annpos`, `setannpos`
  are ports of the macros of `ecgmap.h`; their modifiable tables are held
  by `wfdbx.internal.ecg_map()` (an `EcgMap` handle with fields `qrs`,
  `mp1`, `mp2`, `annp`, indexed by code + 1). The function versions of
  the C library are also provided under their C names (`wfdbx.wfdb_isann`,
  ..., `wfdbx.wfdb_setannpos`, which call the functions above). The
  mnemonic tables (`annstr`, ...) belong to the annotation module.

## Formatted output

`printf` formatting must match glibc. The MATLAB/Octave `sprintf` is used
for each conversion, through `wfdbx.internal.csprintf(fmt, args...)`, which
adds C semantics: `nan`/`-nan`/`inf` (not `NaN`/`Inf`; the sign of a NaN is
its sign bit, and `0/0` computed at run time is `-nan` as in C on x86),
`%d`/`%ld`/`%lld` of integer-valued doubles (non-integers truncated), `%c`
of a number or a char, `%s` of byte strings (`[]` prints `(null)`), `%u`,
`%x`, `%o` of wrapped values (modulo 2^32, or 2^64 with `l`), `%hd`/`%hhd`,
`%F`, and `*` widths and precisions. Parsed formats are cached; when all
arguments are ordinary (finite double scalars, integers for integer
conversions, non-empty char vectors), one `sprintf` call produces the
result (about 50 microseconds per call in Octave). `%a`, `%n` and `%p`
are not supported. `tests/test_csprintf.m` checks the results against
strings printed by glibc.

Plain `sprintf` is fine where its result is the same as C's (e.g. `%d` of
an integer, `%s` of text) — notably for vectorized output. Octave's
`sprintf` differs from C in: `NaN`/`Inf`/`-Inf` spellings, `%d` of a
non-integer (printed as with `%f`/`%g`), `%lld`/`%hd` (rejected: strip
length modifiers), `%F` and `%a` (rejected), and `%d` of `uint64` values
above 2^53 (printed as a float; use `%u`).

Output to the standard output/error goes through `wfdbx.internal.cout(s)`
/ `wfdbx.internal.cerr(s)` (or `cprintf(fmt, ...)` / `ceprintf(fmt, ...)`),
which write bytes with `fwrite`; tools must not call `fprintf`/`disp`
directly. `cout` buffers its output (flushed when the buffer is large, by
`cout()`, before anything is written by `cerr`, when a tool run by
`app_run` returns, and before the drivers exit); `cerr` is unbuffered.

Large outputs (e.g. `rdsamp`) are formatted in a vectorized way (one
`sprintf` call over a matrix, after substituting the C spelling of special
values) for speed, with the same results.

## Library state

The C library's global state (open signals, annotators, WFDB path, time
base, ...) is kept in handle objects held by `persistent` variables of
accessor functions in `+wfdbx/+internal/` (e.g. `wfdbx.internal.sig_state()`
returns the signal state object). `wfdbx.wfdbquit()` resets them as C does.
The I/O state is `wfdbx.internal.io_state()` (an `IOState`: `wfdbpath`,
`path_prefix`/`path_type`, `error_print`, `error_message`,
`wfdb_filename`, `irec`, the standard stream objects, ...). Handle classes
are defined in `+wfdbx/+internal/` (`IOState.m`, ...) and created by their
accessor on first use. `clear functions` (or `clear all`) resets all the
library state.

## Performance

Octave executes scalar code slowly (around a microsecond per simple
statement), so per-sample loops are avoided on common paths:

* signal files are read with `fread` into memory buffers;
* `wfdbx.getframes(n)` (as in the Python port) decodes many frames at once
  with vector operations, with exactly the semantics of `n` calls of
  `getvec`; it is used by `rdsamp`, `read_record` and other tools that read
  whole records;
* annotation files are decoded in bulk where possible
  (`wfdbx.internal.getann_bulk`, `putann_bulk`; see *Annotations* below).

Orders of magnitude in Octave 8: a simple statement or builtin call takes
1-3 microseconds, a call of a package function about 10, a method call of a
handle object tens of microseconds, `csprintf` about 50, `sprintf` 5.

The per-sample functions (`getvec`, `putvec`, ...) remain exact and are the
reference for the bulk paths.

## Internal API (foundation)

The C-emulation and I/O layer in `+wfdbx/+internal/` (each function has its
help text):

| Function | C equivalent / purpose |
|---|---|
| `cint32`, `cuint32`, `cint16`, `cuint16`, `cint8`, `cuint8` (vectorized) | assignment to `int`, `unsigned`, `short`, `unsigned short`, `char`, `unsigned char` |
| `cdiv(a, b)`, `cmod(a, b)` | integer `/` and `%` |
| `d2i(x)` | `(int)x` (INT_MIN for NaN/out of range) |
| `cisspace(c)` | `isspace` |
| `[v, e] = strtol(s, base, pos, lmin, lmax)`, `[v, e] = strtod(s, pos)`, `atoi(s)`, `atof(s)` | the same; positions 1-based |
| `t = Strtok(s); tok = t.next(delims); t.rest()` | `strtok(s, d)` then `strtok(NULL, d)`; `[]` is NULL |
| `[n, vals] = csscanf(s, fmt)` | `sscanf`: `n` is C's return value (-1 = EOF), `vals` the `n` assigned values (cell); unassigned variables keep their old values |
| `lines = fgets_lines(data, bufsize)` | successive `fgets(buf, bufsize, fp)` results (cell of char) |
| `r = GlibcRand(seed); r.rand(); r.rand(n); r.srand(seed)` | glibc `srand`/`rand` (`GlibcRand.RAND_MAX`) |
| `s = csprintf(fmt, ...)`, `cprintf(fmt, ...)`, `ceprintf(fmt, ...)` | `sprintf`, `printf`, `fprintf(stderr, ...)` |
| `cout(s)`, `cout()`, `cerr(s)` | `fwrite` to stdout (buffered; `cout()` flushes), to stderr |
| `b = stdin_bytes()` | the whole standard input (uint8 row; read once) |
| `v = cgetenv(name)` | `getenv` (`[]` if unset or empty: they cannot be told apart in Octave nor in MATLAB before R2022b) |
| `cexit(status)` | `exit(status)` inside a tool (throws `wfdbx:exit`) |
| `status = app_run(@main, argv)` | runs a tool's `main(argv)` (argv{1} = program name); handles `cexit`; flushes |
| `status = cli_main(args)` | the command-line dispatcher used by both drivers |
| `cmd = tool_command(tool)`, `shell_quote(s)` | shell command running a tool in a new process (for `sortann` from `oannclose`, in legacy mode) |
| `is_octave()` | true in Octave |
| `st = io_state()` | the I/O state (`IOState`) |
| `wfdb_error(fmt, ...)` | `wfdb_error`: saves the message; prints it unless `wfdbquiet` |
| `f = wfdb_open(s, record, mode)` | `wfdb_open`: the one location a name designates (`resolve_name`, `open_at`); in legacy mode, the WFDB path search; returns a `WFDBFile` or `[]` |
| `p = resolve_name(name, output)`, `f = open_at(p, s)`, `expand_home(n)`, `is_url(n)`, `is_absolute_path(n)` | wfdb-x name resolution: a relative name under the input (or output) directory, an absolute, `~` or URL name as given; the file at that location (both spellings) |
| `f = open_in(dir, s, name, record)`, `wfdb_dirname(p)` | a file named in a header, in the header's directory, with the containment check |
| `in_header_dir(name)`, `expand_record(r)`, `output_file(name)` | the containment rule; the trailing-'/' expansion of `wfdb_open`; the local file that an output name designates |
| `is_input_file(fname)` | (signal module) true if an output signal file is a signal file of the open input record, segments included (Octave: `stat` device and inode; MATLAB: `java.nio.file.Files.isSameFile`); `openosig` refuses such a file in normal mode |
| `init_input_dir(st)`, `init_output_dir(st)`, `put_input_dir(st, d)`, `path_components(p)` | the settings (environment variables read once), and the path scanner shared by `wfdb_parse_path` and `setwfdb` |
| `f = fetch_open(url)` | a remote file (network access allowed), fetched once per session (the system program `curl`; if it is not found, `webread` in Octave, `websave` in MATLAB) and served from a temporary file deleted by `close()` |
| `f = wfdb_fopen(fname, mode)` | `wfdb_fopen` (`'rb'`, `'wb'`, `'ab'`) |
| `wfdb_parse_path(p)`, `wfdb_addtopath(s)`, `getiwfdb(p)` | path handling (legacy mode) |
| `wfdb_checkname(p, what)`, `wfdb_setirec(p)`, `wfdb_getirec()`, `wfdb_striphea(p)` | the same |
| `m = ecg_map()` | annotation mapping tables (`EcgMap`) |

`WFDBFile` (the `WFDB_FILE`) methods: `read(n)`, `readall()`, `getc()`,
`write(b)`, `putc(c)`, `printf(fmt, ...)`, `getline()`, `g16()`, `g32()`,
`p16(x)`, `p32(x)`, `seek(off, whence)` (0/1/2 = SEEK_SET/CUR/END),
`tell()`, `flush()`, `feof()`, `ferror()`, `clearerr()`, `close()`;
properties `fp`, `type`, `name`, `is_std`. Bytes are `uint8` rows; lines
are `char`. The standard input (`'-'` for reading) is served from
`stdin_bytes()` and is not seekable (as a pipe in C); writes to the
standard output (`'-'` for writing) go to `cout`. Method calls cost tens of
microseconds in Octave: read data in bulk (`read`, `readall`) and decode it
with vector operations.

Public I/O functions in `+wfdbx/`: `getwfdb`, `setwfdb`, `resetwfdb`,
`wfdbquiet`, `wfdbverbose`, `wfdberror`, `wfdbfile`, `wfdbmemerr`,
`wfdbversion`, `wfdbldflags`, `wfdbcflags`, `wfdbdefwfdb`,
`wfdbdefwfdbcal`.

**Finding files** (wfdb-x): nothing is searched in normal mode. The
settings (input directory, output directory, network access) are
properties of `IOState` (`input_dir`, `output_dir`, `network`, ...), each
read from its environment variable when first needed
(`init_input_dir`, `init_output_dir`, `wfdbx_get_network`); `wfdbquit`
does not reset them. The signal module notes the directory of the header
read last (`SigState.hdr_dir`) and of the master header of a
multi-segment record (`msrec_dir`, `msrec_name`), so that signal files and
segments are opened next to their header (`open_in`). Remote files are
read only in normal mode with network access on; legacy mode keeps the
original code (`wfdb_fopen` refuses names containing `..` or `://`).

## Signals (lib/signal.c)

The module follows `python/src/wfdbx/_signal.py` function by function.

**State.** `S = wfdbx.internal.sig_state()` (a `SigState`) holds the
statics of `signal.c` under their C names (`ffreq`, `sfreq`, `cfreq`,
`btime`, `bdate`, `nsamples`, `segarray`, `segp`, `istime`, `ostime`,
`gvmode`, `skewmax`, `dsbuf`, `tspf`, ...). Per-signal data are struct
arrays: `hsd` (header data: `info`, `start`, `skew`; see
`wfdbx.internal.hsdata`), `isd` and `vsd` (input signals: `info`, `samp`,
`skew`, `gvindex`, `gvcount`; `wfdbx.internal.isdata`), `osd` (output:
`info`, `samp`, `skew`), `smi` (sigmap). The `info` fields are
`wfdbx.siginfo` structures; `info.group` is 0-based as in C. Signal
groups (one per signal file) are handle objects in cell rows: `igd{g+1}`
(`IGData`: `fp`, `buf`/`bp`/`be`, `count`, `data`, `datb`, `stat`,
`start`, `bsize`, `seek`, `initial_skip`, `flac`) and `ogd{g+1}`
(`OGData`). Flags replace C pointer tests that cannot be written in
Octave (`==` is not defined for handle objects): `has_dsbuf`,
`has_pinfo`, `outinfo_hdr` (`outinfo` is `oheader`). `plan` caches
per-signal constants for `getskewedframe` (reset by `isigopen` and
`isigclose`).

**Reading.** `wfdbx.internal.readheader` (and `edfparse` for EDF files)
fill `hsd`; `isigopen` opens the groups. A frame is read by
`wfdbx.internal.getskewedframe(S, v)`, which reads the samples of each
group with `wfdbx.internal.ig_read(ig, fmt, n, reset)`: `n` successive
samples with exactly the semantics of C's `r8`/`r16`/`r212`/... (buffer
refills of `bsize` or `ibsize` bytes, the stale bytes returned after the
end of the file, `ig.stat` after each sample); `ig_skip` is the loop of
`r8()` calls of `isgsetframe`. Bit-packed state (`data`, `datb`) is kept
as unsigned 16-bit values (only their low 16 bits matter in C).
`rgetvec` (multi-frequency modes), `getframe_s` (deskewing) and `getvec`
(resampling with `setifreq`) are layered as in C; `getvec` calls
`getskewedframe` directly when none of them is needed. Internal functions
take the state object `S` as an argument (a `sig_state()` call costs
about 10 microseconds).

**Bulk reading.** `[v, stat] = wfdbx.getframes(n)` (the array first, as
in Python) is exactly `n` calls of `getvec` (stopping at the first
negative status). It calls `wfdbx.internal.bulk_frames`, which decodes
whole frames from the bytes of each group with vector operations
(including multi-frequency records in `WFDB_LOWRES` mode, averaged as
`meansamp`, and `WFDB_HIGHRES` mode, `ispfmax` vectors per frame; FLAC
groups through `flac_getsamps`; `WFDB_GVPAD`) and stops before any frame
that needs special handling: the frame at which a checksum is verified,
the end of a file, a partial bit-packed group, a partial frame in
`WFDB_HIGHRES` mode. `getframes` then calls `getvec` for one vector and
tries the bulk path again. Skewed records (`dsbuf`), variable-layout
multi-segment records (`sigmap`), signals without files (format 0),
`setifreq` resampling and unskipped prologs use `getvec` throughout.

**Writing.** `putvec` encodes a frame into the bytes of each group and
appends them with `wfdbx.internal.og_put(og, bytes)` (which writes the
buffer in chunks of `obuflen` bytes, as C's `w8` does byte by byte).
`wfdbx.putframes(M)` writes the rows of `M` with exactly the effect of
calling `putvec` for each (vector encoding of all formats, continuing any
partial bit-packed group; format 8 differences are clipped sample by
sample only where they exceed [-128, 127], as clipping is sequential).
`wfdb_osflush` (from `wfdbflush` and `osigclose`) writes partial
bit-packed groups and rewinds as C does. `setheader`, `newheader`,
`setmsheader`, `setinfo`, `putinfo` write headers (`\r\n` line ends);
`[stat, si] = setheader(...)` also returns the `units` and `desc` strings
as C's `strtok` leaves them.

**API conventions** (besides those above): `[nsig, si] =
wfdbx.isigopen(record, nsig)` (`nsig <= 0`: only the header is read, `si`
describes `-nsig` signals); `[nsig, si] = wfdbx.osigopen(record, nsig)`;
`n = wfdbx.osigfopen(si, nsig)`; `[stat, v] = wfdbx.getvec(v0)` and
`[stat, v] = wfdbx.getframe(v0)` (`v0` optional: the vector C would
leave unchanged); `wfdbx.getinfo(record)` / `wfdbx.getinfo([])` return
`[]` at the end; `wfdbx.setmsheader(record, segnames)` takes a cell
array; `wfdbx.getseginfo()` returns a `wfdbx.seginfo` struct array.
Constants: `wfdbx.WFDB_INVALID_SAMPLE()`, `WFDB_LOWRES`, `WFDB_HIGHRES`,
`WFDB_GVPAD`, `WFDB_DEFFREQ`, `WFDB_DEFGAIN`, `WFDB_DEFRES`,
`WFDB_MAXRNL`, `WFDB_MAXUSL`, `WFDB_MAXDSL`.
`WFDB_DEFFREQ`, `WFDB_DEFGAIN` and `WFDB_DEFRES` are used only in legacy
mode (below): wfdb-x never assumes a sampling frequency, a gain, an ADC resolution or units
([`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md), defined by
`tests/reference/divergences.patch`); code that needs one and does not
have it reports an error, with the comment "wfdb-x: no default sampling
frequency (C assumed 250 Hz)" or the like. An unspecified ADC resolution
is 0, unspecified units are `[]` (shown as `nd` where a tool must print
them). The converters' `-F`, `-G`, `-R`, `-U` options are parsed by
`wfdbx.internal.opt_sigparam` and checked by `wfdbx.internal.sigparams`;
the files affected by this design say so in the "Changes from the
original" paragraph of their file header.

**Legacy mode** (`--legacy`, docs/DIVERGENCES.md): the flag is the
`SigState` property `legacy_mode` (`wfdbx.wfdbx_set_legacy`,
`wfdbx_get_legacy`; not reset by `wfdbquit`). `app_run` calls
`wfdbx.wfdbx_legacy_args` before a tool's `main` and restores the previous
setting when the tool returns. Every divergence branches on it, with the
original code in the legacy branch (comment "wfdb-x: legacy mode"); in the
tools, options added by wfdb-x are made unrecognized by clearing the
option character before the `switch`, and `help` prints the original text
in legacy mode. The high-level functions take a `'legacy'` option
(`wfdbx.internal.hl_legacy` turns the library's legacy mode on for the
call and restores it with an `onCleanup` object).

**Used by other modules**: the time functions (`wfdbx.sampfreq`,
`setsampfreq`, `strtim`, `timstr`, `mstimstr`, `getcfreq`,
`getbasecount`; `wfdbx.internal.fstrtim`, `fmstimstr`, `ftimstr` take the
frequency as an argument), and `wfdbquit`/`wfdbflush`, which call the
annotation module's `wfdbx.internal.wfdb_anclose` and `wfdb_oaflush`.
The signal module calls `wfdbx.getafreq`/`setafreq` (EDF headers,
`setifreq`) and the FLAC functions. Calls into other modules are guarded
with `wfdbx.internal.pkg_has(name)` (cached), because `exist` does not
find package functions in Octave.

**Files.** C's `fseek` succeeds beyond the end of a file (MATLAB's and
Octave's do not), and `isigsettime` relies on it: `WFDBFile.seek` emulates
it (reads there find the end of the file; a write extends the file with
zeros).

**Speed** (Octave 8): `rdsamp -r 100s` (the sample record of `tests/data`, the first minute of MIT-BIH record 100) runs in 0.2 s in all (process
start included); for a record of 650,000 frames of two format-212
signals, `getframes` takes 0.13 s, `putframes` 0.12 s, and `rdsamp`
(raw or `-p`) 1.0 s in all. `getvec` and `putvec` cost about 0.4 and
0.25 ms per call (a handle property access costs 3-5 microseconds).
`write_record` (which uses `putframes`) writes 216,000 frames of two
signals in about 0.08 s, and `read_record` reads them in about 0.05 s.

## Annotations (lib/annot.c)

State: `wfdbx.internal.ann_state()` (an `AnnState`): `iad` and `oad`, cell
rows of structures for the open input and output annotators (annotator
number `n`, 0-based as in C, is `iad{n+1}`), `oafreq`, `annclose_error`,
and the mnemonic tables (`cstring`, `astring`, `tstring`, `modified`),
which `wfdbquit` does not reset. `wfdbx.wfdbquit` calls
`wfdbx.internal.wfdb_anclose()`, and `wfdbx.wfdbflush` calls
`wfdbx.internal.wfdb_oaflush()`.

* **Reading.** `annopen` reads the whole file and decodes it at once with
  vector operations (`wfdbx.internal.ann_parse`): the result `P` lists the
  successive values that the C variable `ia->ann` takes during one pass
  over the file (times before scaling, codes, subtypes, chan/num carried
  over, the AUX words, and whether the file ends inside the last
  annotation, which makes `getann` report `unexpected EOF`). The input
  annotator structure keeps `k`, the index in `P` of the current
  annotation, plus the other fields of C's `iadata` (`pann`, `ateof`,
  `tmul`, `ann_tt`, `prev_tt`, ...). Bytes read past the end of the file
  are emulated as in `WFDBFile` (255), so truncated files behave as in C.
* **The aux buffer.** In C, `annot.aux` points into a 771-byte buffer used
  as a ring (`auxstr`), and the aux string of an annotation is taken after
  the *next* annotation has been read; stale bytes can therefore be
  visible. This is emulated exactly (`buf`, `index`, `auxpos`;
  `ann_auxput` stores an AUX word, `ann_auxget` returns what C finds at
  `aux`, up to a null). The buffer carries over from one pass to the next
  (`iannsettime` rewinds by starting a new pass, `k = 0`), so it is never
  precomputed.
* `[stat, annot] = wfdbx.getann(an)`; `wfdbx.getann(an, annot0)` returns
  `annot0` unchanged when no annotation is read (C leaves its argument
  unchanged; without it, a zero annotation is returned). A fast path
  handles annotations without aux strings; a call takes about 0.1 ms.
* **Bulk reading.** `[stat, A] = wfdbx.internal.getann_bulk(an, m, noaux,
  nofail)` has exactly the effect of up to `m` calls of `getann` (`m` may
  be `Inf`) and returns a structure of rows (`time`, `anntyp`, `subtyp`,
  `chan`, `num`, and the cell row `aux`); with `noaux` the aux strings are
  not built (for skipping); with `nofail`, the call that would fail is not
  made (`stat` is then 1): tools that may stop early use this, then make
  the failing call themselves only if C would. (Reading an AHA-format
  annotation can print a message, so code that may stop early reads AHA
  files one annotation at a time: C reads only one annotation ahead.)
  400,000 annotations are read in about 0.2 s. `iannsettime` uses it to
  skip annotations.
* **Writing.** `putann` encodes into a byte buffer of the output annotator
  (`obuf`, written by `wfdbx.internal.ann_oflush` when large, by
  `wfdb_oaflush`, and by `oannclose`; output to the standard output is
  written at once, so that it interleaves with other output as in C).
  `wfdbx.internal.putann_bulk(an, A)` writes the annotations of a
  structure of rows `A` (as returned by `getann_bulk`) with exactly the
  effect of calling `putann` for each (vectorized for MIT format).
  When annotations were written out of order, `oannclose` rearranges
  the file (`oa.fname`, the name with which it was created) in the same
  process with `wfdbx.internal.ann_sortfile`, byte for byte as the
  `sortann` tool: the file is decoded into a private input annotator
  structure (`ann_format`, `ann_parse`, `ann_iadata`, `ann_readtable`
  with a private definition table, `ann_defs`, `ann_getbulk`), ordered
  by `ann_sortlist` (insert_ann of `sortann.c`, which the `sortann` tool
  uses too), and written with a private output annotator structure
  (`ann_oadata`, `ann_puttable`, `ann_putbulk`). These functions take and
  return the annotator structures (the library functions `getann_bulk`,
  `putann`, `putann_bulk`, `ann_gettable` call them for the annotators of
  `ann_state()`), so the open annotators, the library's tables and
  `setafreq` are not touched. `ann_sortlist` never compares the list head
  as an annotation (the original did, losing an out-of-order annotation at
  time 0); its `legacy` argument restores that, for the `sortann` tool in
  legacy mode. In legacy mode, `oannclose` runs `sortann --legacy` in a
  separate process (`wfdbx.internal.tool_command('sortann')`), as C does,
  in the output directory if one is set (`cd 'DIR' && ...`).
* The tools `rdann`, `ann2rr`, `wrann`, `rr2ann`, `sortann` read and write
  through the bulk functions and format their output with vector
  operations where the output fields have their usual widths (falling
  back to the per-annotation code otherwise): `rdann` prints 400,000
  annotations in about 2.5 s, `ann2rr` in 0.6 s; `wrann` parses lines with
  regular expressions (the lines that `sscanf` converts completely),
  others with `csscanf`.
* The high-level `wfdbx.read_annotations(record, annotator, name, value,
  ...)` and `wfdbx.write_annotations(record, annotator, samples, name,
  value, ...)` are built on these.

## Calibration (lib/calib.c)

`calopen`, `getcal` (`[stat, cal] = wfdbx.getcal(desc, units)`),
`putcal`, `newcal`, `flushcal`; the list is the property `list` (a struct
array of `wfdbx.calinfo()` structures) of `wfdbx.internal.cal_state()`.

## FLAC (formats 508, 516, 524)

`+wfdbx/+internal/flac_*.m` port `python/src/wfdbx/_flac.py`, without
external libraries:

* `[chans, bps, md5] = flac_decode(bytes, nsig, datb)` decodes a whole
  stream (all FLAC features; CRCs checked); errors are thrown with the
  identifiers `wfdbx:flac:meta|sync|header|crc|unparseable|eof|wfdb`.
  Rice codes are decoded with vector operations (pointer doubling over
  the positions of the one bits); LPC subframes need a loop over the
  samples. The test records decode in 0.1-0.4 s.
* `frame = flac_encode_frame(block, bps, frame_no)` encodes one frame
  exactly as the Python encoder does (the files written are identical to
  Python's, vendor string `wfdb-x`).
* `md5(bytes)` (Octave's `hash`, Java in MATLAB, or the MATLAB code of
  `md5_pure`), `flac_crc(bytes, 8|16)`.

**Glue contract with the signal module** (same functions and arguments as
the Python `_flac.isopen`, `getsamp`, ...). The input group `ig`
(`IGData`) and output group `og` (`OGData`) are handle objects; the FLAC
functions use these properties: `ig.fp` (the open `WFDBFile`, read with
`readall()` on the first read), `ig.start` (offset added to seeks, in
samples), `ig.stat`, `ig.count`, `ig.flac`; `og.fp` (`tell`, `write`,
`seek`), `og.bsize`, `og.buf`, `og.flac`. `ig.flac`/`og.flac` hold the
codec state (a structure; `[]` when the group is not FLAC).

| Function | Called by | Effect |
|---|---|---|
| `stat = flac_isopen(ig, hs, ns)` | `isigopen`, after opening `ig.fp` (`hs`: the group's 1-by-`ns` header data, fields `info.fmt`, `info.spf`) | checks (at most 8 signals, equal `spf`), sets `ig.flac`, `ig.count = 0`; 0 or -1 |
| `v = flac_getsamp(ig)` | `getvec` (per sample) | next sample in WFDB frame order (per frame, `spf` samples of each signal in turn); decodes the stream on first use; at the end returns 0 with `ig.stat = 0` (and the "samples left over" warning once); after a decoding error, 0 with `ig.stat = -2`; `ig.stat` unchanged otherwise |
| `[v, st] = flac_getsamps(ig, n)` | bulk readers | exactly `n` calls of `flac_getsamp` (`st(k)` = `ig.stat` after each, as `ig_read` returns); `n = Inf` returns all remaining samples at once (the bulk accessor for `getframes`) |
| `stat = flac_isseek(ig, t)` | `isgsettime` | positions at frame `t` (+ `ig.start`); sets `ig.stat = 1`, `ig.count = 0`; returns 1, or -1 (out of range or undecodable) |
| `stat = flac_isclose(ig)` | `isigclose` | MD5 check if `WFDB_FLAC_CHECK_MD5` is set |
| `stat = flac_osinit(og, si, ns)` | `osigfopen`, before opening `og.fp` (`si`: 1-by-`ns` siginfo) | checks, sets `og.flac` and `og.bsize = ns * spf * 4`; 0 or -1 |
| `stat = flac_osopen(og)` | after opening `og.fp` | writes the stream header |
| `stat = flac_putsamp(v, fmt, og)` | `putvec` (per sample, frame order) | buffers the sample; encodes and writes each 4096-sample block |
| `stat = flac_putsamps(v, fmt, og)` | bulk writers | the same for a vector of samples |
| `stat = flac_osclose(og)` | `osigclose`, before closing `og.fp` | encodes the rest, rewrites STREAMINFO (seekable files), sets `og.flac = []` and empties `og.buf` |

## Writing a tool

```matlab
function status = rdann(args)
%RDANN Print an annotation file in ASCII form.
%   STATUS = wfdbx.apps.rdann(ARGS) runs the rdann tool ...
%   ... usage as for the C program, example, See also ...
%
%   Translation of the C program rdann (app/rdann.c, WFDB 10.7.0): same
%   options and output. Differences: ...; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/rdann.c from the WFDB Software
% Package 10.7.0, by T. Baker and George B. Moody. ...
%
% Changes from the original: ...
%
% Original C program: app/rdann.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: ... See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'rdann'}, args]);
end

function status = main(argv)
% line-by-line port of main(); argc = numel(argv); C argv[i] is argv{i+1}
...
status = 0;
end
```

`exit(n)` in C becomes `wfdbx.internal.cexit(n)` (or `status = n; return`
in `main`). Messages go through `cprintf`/`ceprintf` (C formats, so
`'%s\n'`); a tool must never print with `fprintf` or `disp`. See
`+wfdbx/+apps/wfdbwhich.m` and `wfdbcat.m`.

## Standard input and the command line

Tools read the standard input through `wfdbx.internal.stdin_bytes()`, which
reads it completely on first use (in MATLAB, which cannot read the standard
input, `bin/wfdbx_matlab.sh` saves it to a file named by the `WFDBX_STDIN`
environment variable). The record name `-` refers to the standard input or
output, as in C.

`bin/wfdbx_cli.m` (an Octave script) adds `matlab/` to the path and calls
`wfdbx.internal.cli_main(argv())`, which calls
`status = wfdbx.apps.<tool>(args)`; the script then exits with `status`.
An unknown tool, or a MATLAB error in a tool, gives a message on the
standard error output and status 1. `bin/wfdbx_matlab.sh` saves the
standard input to a temporary file (WFDBX_STDIN), passes the arguments in
hexadecimal (decoded by `wfdbx.internal.hexargs`, so that any bytes arrive
unchanged), and runs `matlab -batch` (`$WFDBX_MATLAB` overrides the MATLAB
command); it waits for the end of its standard input before starting
MATLAB. It could not be tested here (no MATLAB): it has been checked by
running its MATLAB command in Octave. Messages that include the program
name use the tool's name.

Octave starts in about 0.07 s, and running a small tool through
`bin/wfdbx_cli.m` takes about 0.09 s in all; keep startup work minimal (no
work at load time; state is created on first use).
In legacy mode, `oannclose` sorts out-of-order annotation files by
running the `sortann` tool in a separate process (the same interpreter,
`bin/wfdbx_cli.m`).

## Testing

```sh
python3 tests/conformance/harness.py check --impl octave      # conformance
octave-cli --no-gui --norc -q --eval "cd matlab/tests; run_tests"  # unit tests
```

`run_tests` runs every `matlab/tests/test_*.m` (a function without
arguments that throws on failure; `assert_eq(actual, expected, what)` helps)
and exits with status 1 on failure when run non-interactively.
`run_tests('wfdbio')` runs the tests whose names match a pattern.
