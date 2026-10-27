# WFDB-x for Julia: implementation notes

These notes describe how the Julia implementation is organized. They
complement [`docs/porting-guide.md`](../docs/porting-guide.md) (the C
semantics every implementation must reproduce). Julia compiles to native
code and has fixed-width integer types that wrap like C's, so the closest
models are the C++ (`cpp/`) and Rust (`rust/`) implementations; the Python
implementation (`python/src/wfdbx/`) shows how each undefined C behavior
was resolved. All implementations must behave identically (the conformance
suite checks this).

## Requirements

* Julia 1.9 or later; **no package dependencies** beyond Julia's standard
  libraries (and only where they help: e.g. `Printf` is *not* used for C
  formatting, see below). `Test` is a test-only dependency.
* Linux, macOS, Windows (raw file descriptors are used for I/O; the
  Windows code paths are untested).
* Fast: after precompilation, tools must start quickly and run at C-like
  speed.

## Layout

`julia/` is a Julia package named **`WFDBX`** (module `WFDBX`):

| Path | Contents |
|---|---|
| `Project.toml` | package metadata (name, uuid, version, compat) |
| `src/WFDBX.jl` | the module: includes (in dependency order), core exports, `__init__` |
| `src/cstd.jl` | C standard library emulation (glibc-exact `printf`, `strtol`, `strtod`, `sscanf`, `strtok`, glibc `rand`, the standard streams, `cexit`) |
| `src/types.jl` | `abstract type Wfdb`, the types, constants and structures of `wfdb.h` |
| `src/ecgcodes.jl` | annotation codes and the `<ecgmap.h>` functions (state: `EcgMaps`) |
| `src/wfdbio.jl` | port of `lib/wfdbio.c` (state: `IoState`) and `WfdbFile` |
| `src/signal.jl`, `src/annot.jl`, `src/calib.jl`, `src/wfdbinit.jl`, `src/flac.jl` | the other library files (states `SigState`, `AnnState`, `CalState`) |
| `src/wfdb.jl` | `WfdbLib`, the concrete `Wfdb` (assembles the states), the default instance `lib()` |
| `src/highlevel.jl` | high-level API (`read_header`, `read_record`, `read_annotations`, `write_record`, `write_record_physical`, `write_annotations`) |
| `src/check.jl` | `check_record`: checks a record and its annotation files and reports every problem |
| `src/cli.jl` | the driver (`main_cli`), `run_tool`, `tool_function`, `tools()` |
| `src/apps/<tool>.jl` | the command-line tools: `<tool>_main(args)` and the tool's precompilation workload; every `.jl` file in `src/apps/` is included automatically |
| `src/precompile.jl` | the precompilation workload registry and helpers |
| `bin/wfdbx.jl` | command-line driver: `julia --startup-file=no --project=julia julia/bin/wfdbx.jl TOOL ARGS...` |
| `test/runtests.jl` | unit tests (`Test` standard library) |

Each file starts with a comment saying what it is, then that it is part
of WFDB-x, an independent reimplementation of the WFDB Software Package in
Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. A file that
translates a C file says so ("It is a Julia translation of lib/<file>.c
from the WFDB Software Package 10.7.0, by ..."), lists its "Changes from
the original" (each marked `wfdb-x:` in the code; `docs/DIVERGENCES.md`
gives the reasons), and gives the copyright of the original C code, as in
`docs/AUTHORS.md`, and of the Julia translation (Reza Sameni, 2026). Code
with no C original says "It has no counterpart in the original package."
Every header ends with the license: GNU GPL 3 or later (`LICENSE`).

The docstring of a WFDB library function ends with "Translation of the C
function NAME() (lib/FILE.c, WFDB 10.7.0): same arguments and results."
(plus "Differences: ...; see docs/DIVERGENCES.md." where WFDB-x differs);
that of a WFDB-x addition ends with "Part of WFDB-x; not in the original
WFDB package."

## Data representation

* **Integer types** follow the C reference platform: `WFDB_Sample` is
  `Int32`, `WFDB_Time` is `Int64`, C `int` is `Int32`, `long` is `Int64`,
  `char` is `Int8` (signed), `unsigned` is `UInt32`. Julia's fixed-width
  integer arithmetic wraps around like C's, so C expressions are ported with
  the same types (beware of promotion: `Int32 + Int` is `Int64`, and integer
  literals are `Int` (64-bit); write `x + Int32(1)` or convert the result
  with `% Int32`, which truncates like a C cast; `Int32(x)` *throws* if `x`
  does not fit). C's `/` and `%` on integers are `div` and `rem` (`÷`, `%`
  in Julia: both truncate toward zero); `cdiv`/`cmod` also handle
  `MIN / -1`. Conversions from `Float64` to integers follow C on x86
  (`d2i`: out-of-range and NaN give `typemin(Int32)`; `d2l`), not Julia's
  `InexactError`-throwing `Int32(x)` / `round`.
* **Strings are bytes.** WFDB files are not UTF-8, so byte strings of the
  C API are `Vector{UInt8}`. Public functions also accept `String`
  arguments: annotate them `::ByteStr` (`Union{AbstractString,
  AbstractVector{UInt8}}`) or `::OptByteStr` (also `nothing`, C's `NULL`),
  and convert with `bytes(x)` (no copy for a `Vector{UInt8}`) or
  `cstr(x)` (up to the first NUL). Results that are text are
  `Vector{UInt8}`, or `String` where the C library documents ASCII-only
  results (e.g. `timstr`). A C `NULL` string is `nothing`. Byte literals:
  `b"..."` (a read-only `CodeUnits`; compare with `==`, convert with
  `Vector{UInt8}(b"...")` to store or mutate). `bstr(v)` makes a `String`
  from bytes (for file names and `ENV`).
* **Structures** of the C API: mutable structs `Siginfo`, `Calinfo`,
  `Anninfo`, `Annotation`, `Seginfo` (`types.jl`) with the C field names
  and C's zero values as defaults (keyword constructors). An annotation's
  `aux` is `nothing` or a `Vector{UInt8}` whose first byte is the length of
  the data that follows.
* Functions that fill caller-supplied arrays take them as mutable
  arguments (`isigopen(record, si::Vector{Siginfo}, nsig)`,
  `getvec(v::Vector{Int32})`, `getann(an, a::Annotation)`), with
  `nothing` for C's `NULL` where the C function allows it.
* C output parameters (`int *`) are `Ref`s (`Ref{Int32}`), as for
  `csscanf`.

## Library state and the API pattern

The state of the C library is held by an object of the abstract type
**`Wfdb`**; its one concrete type, `WfdbLib` (`wfdb.jl`), has one field
per C source file, whose type is defined in the file that ports it:

| field | type | defined in |
|---|---|---|
| `io` | `IoState` | `wfdbio.jl` (WFDB path, errors, current record name) |
| `sig` | `SigState` | `signal.jl` |
| `ann` | `AnnState` | `annot.jl` |
| `cal` | `CalState` | `calib.jl` |
| `maps` | `EcgMaps` | `ecgcodes.jl` (the `<ecgmap.h>` tables) |

Each state is a `mutable struct` whose zero-argument constructor gives the
state at program start. Add fields to your own module's state only; read
another module's state through its functions where possible.

Every C library function (including library-private ones such as
`wfdb_open`, `wfdb_checkname`, `wfdb_setirec`, useful to tools) is a
function with the C name taking the library state as its first argument
**annotated `w::Wfdb`** (the abstract type: the methods are compiled for
`WfdbLib`), plus a method without it that uses the default instance:

```julia
"""
    sampfreq([w], record) -> Float64

C `sampfreq(record)`: ...
"""
function sampfreq(w::Wfdb, record::OptByteStr)
    ...
    wfdb_error(w, "sampfreq: can't read header for record %s\n", record)
    ...
end
sampfreq(record::OptByteStr) = sampfreq(lib(), record)
```

* Give the default-instance method explicit argument types (an untyped
  `f(args...) = f(lib(), args...)` recurses forever on bad arguments).
* Inside the library, always pass `w` along (never call `lib()` from a
  function that has a `w`): independent `Wfdb()` instances must work.
* `wfdb_error(w, fmt, args...)` formats like C's `wfdb_error` (so `%` in a
  message must be `%%`); `wfdb_error_msg(w, msg)` records a message that is
  already formatted.
* Files: `wfdb_open(w, type, record, mode)` returns a `WfdbFile` or
  `nothing`; `wfdb_fopen(name, mode)`, `cfopen(name, mode)` (plain C
  `fopen`) need no state.
* Export the public C API names from your file (`export isigopen, ...`).
  The C standard library emulation (`cformat`, `getc`, ...) is not
  exported.
* Module-level mutable globals other than these states must be reset by
  `__init__` (the precompilation workload runs code whose global state
  would otherwise be saved in the package image). Prefer putting state in
  your `Wfdb` field.

`wfdbquit` does not reset the counter frequency, `setafreq`'s resolution,
the buffer sizes, the mnemonic tables, the `EcgMaps` (see
[`docs/KNOWN_C_BEHAVIORS.md`](../docs/KNOWN_C_BEHAVIORS.md)).

## C standard library emulation (`cstd.jl`)

* **printf**: `cformat(fmt, args...)` (C `sprintf`, returns
  `Vector{UInt8}`), `sprintf!(out, fmt, args...)` (appends to `out`),
  `cprintf(fmt, args...)` (buffered standard output), `ceprintf`
  (standard error), `cfprintf(f::WfdbFile, fmt, args...)`. `fmt` is a
  `String` or bytes. Arguments: any integer, float, `String`, byte vector,
  `nothing` (`NULL` → `(null)`), `Char`. As in C, `%d` prints the low 32
  bits of its argument (`%ld` all 64), `%hd`/`%hhd` 16/8 bits, `%u`/`%x`
  the unsigned value, so pass the value C passes (an `Int32` or `Int64`,
  whichever; the conversion decides). `%e`, `%f`, `%g` are produced from
  the exact value of the `Float64` with round-half-even, as glibc
  (including `%#g` quirks, `nan`/`-nan`/`inf`): verified against glibc on
  more than 100 million random cases (a streaming comparison with the
  output of C programs). The formatter allocates nothing for
  numeric and `String`/`Vector{UInt8}` arguments (~150-250 ns per call);
  it uses module-level scratch buffers and is **not reentrant or
  thread-safe** (the arguments are converted before formatting starts, so
  nested `cformat` calls in the arguments are fine).
* **Parsing**: `strtol(s, base) -> (value, n)` where `n` is the number of
  bytes consumed (0: no conversion; parse from an offset with a view,
  `@view s[pos:end]`), `strtoul`, `strtod`, `strtof` (correctly rounded,
  hex floats, inf/nan, overflow to ±Inf, underflow to ±0), `atoi`, `atol`,
  `atof`; `csscanf(input, fmt, dests...)` with `Ref{T}` destinations
  (`Ref{Int32}` for `%d`, `Ref{Int64}` for `%ld`, `Ref{Float64}` for
  `%lf`, `Ref{UInt8}` for `%c`), `Vector{UInt8}` for `%s`/`%[`/`%Nc`, or
  `nothing`: C return value (-1 when the input ends before the first
  conversion) and unreached destinations untouched; `Strtok(s)` +
  `strtok(t, delims)` (`nothing` at the end; `strtok_pos`, `strtok_rest`);
  `fgets_lines(data, size)`. Character classes for bytes: `c_isspace`,
  `c_isdigit`, `c_isalpha`, `c_isalnum`, `c_isxdigit`, `c_isupper`,
  `c_islower`, `c_isprint`, `c_toupper`, `c_tolower` (Julia's `isspace`
  etc. are for `Char`s and Unicode).
* **rand**: `crand()`, `csrand(seed)` (the process generator),
  `GlibcRand(seed)` + `glibc_rand!(g)`; `RAND_MAX`.
* **Standard streams**: the standard output is buffered (64 KiB; written
  out when full, by `cflush()`, and at exit; line by line if it is a
  terminal): `cout_write(bytes)`, `cputchar(c)`, `cprintf`; `cout_error()`
  is `ferror(stdout)`. The standard error is unbuffered: `cerr_write`,
  `ceprintf`. A `WfdbFile` on `-` (output) writes into the same buffer.
  Output goes to the file descriptors directly (no libuv), `EPIPE` on the
  standard output ends the process with status 141 (as `SIGPIPE` ends a C
  program). The standard input is read from descriptor 0 as bytes
  (`wfdb_stdin()`, `wfdb_open` of `-`); bytes buffered by a closed reader
  are given to the next one; `freopen_stdin(name)` is C's `freopen(name,
  "rb", stdin)`.
* **Write errors**: the standard output and the files are written with
  raw `write(2)` calls, so a failed write never throws (Julia's own
  streams would); it sets the error flag (`cout_error()`, `ferror`). After
  the first failure of the standard output, descriptor 1 is replaced by
  the null device (`_stdout_failed!`), so that later writes and any flush
  of Julia's own `stdout` at process exit succeed and print nothing.
  `_run_main` (`cli.jl`) then does the exit check of the tools: in normal
  mode, it flushes the standard output, prints "TOOL: write error on
  standard output" if it failed, and turns an exit status of 0 into 1 after
  that or a counted write error (`wfdbx_write_errors`, held in `CProc`, so
  that each `run_tool` starts from 0). Files that a tool writes itself are
  closed with `wfdbx_fclose_output`.
* **exit**: `cexit(status)` throws `CExit(status)`, which the driver
  catches: it then flushes every open output file and the standard output
  (as C's `exit` does, without closing records: no annotation end marks, no
  header updates) and exits. **Never catch `CExit`**: use specific
  exception types in `catch` clauses (`catch e; e isa SystemError ||
  rethrow(); ...`), and do not use `finally` to emulate C cleanup.
* **Environment**: `cgetenv(name)` (bytes or `nothing`), `csetenv(name,
  value, overwrite)`; `prog_name(argv0)`; `cargs(args)` (the arguments as
  byte vectors).

## Files: `WfdbFile`

`WfdbFile` is C's `FILE *` / `WFDB_FILE` (buffered, sticky end-of-file and
error flags as glibc). Functions (C names; the `wfdb_` aliases of
`lib/*.c`, `wfdb_getc`, `wfdb_fclose`, ..., also exist): `getc` (inlined;
`EOF` = -1), `ungetc`, `fread!(f, buf[, n])` (bytes) and `fread!(f, buf,
size, nitems)` (C `fread`), `getline!(f, line)`, `fgets!(f, s, size)`,
`read_to_end`, `wfdb_g16`, `wfdb_g32`, `putc` (inlined), `fwrite(f,
bytes)`, `cfprintf`, `wfdb_p16`, `wfdb_p32`, `fflush`, `ftell`, `fseek(f,
offset, SEEK_SET|SEEK_CUR|SEEK_END)`, `feof`, `ferror`, `clearerr`,
`fclose` (C's status), `is_std`, `set_bufsize!`. Opened with `cfopen`,
`wfdb_fopen`, `wfdb_open`, `wfdb_stdin()`, `wfdb_stdout()`,
`wfdb_stderr()`, `wfdb_memfile(bytes)`. Writable files are registered and
flushed at exit; close the files you open.

## Tools and the command line

Each tool is `src/apps/<tool>.jl`, defining `<tool>_main(args::Vector{String})`
(args without the program name), a line-by-line port of the C program
(`app/<tool>.c` or `convert/<tool>.c`), with the same messages, exit
statuses and files. Conventions (see `apps/wfdbwhich.jl`, `apps/wfdbcat.jl`):

```julia
function rdsamp_main(args::Vector{String})
    argv = cargs(args)          # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1     # C argc
    pname = "rdsamp"            # messages use the tool's name
    ...
    cexit(status)               # or return the status
end
```

* Write with `cprintf`/`ceprintf`/`cout_write`, never Julia's
  `print`/`println` to `stdout` (they bypass the C stdout buffer).
* End with `cexit(status)` (C `exit`), or return the status from
  `<tool>_main`; both flush everything.
* An uncaught Julia exception prints `wfdbx: <message>` on the standard
  error and exits with status 1 (it means a bug: C would not do that).
* `oannclose` sorts out-of-order annotation files with `run_sortann(record,
  annotator)` (`wfdbio.jl`), which runs `bin/wfdbx.jl sortann -r. RECORD -a
  ANN` in a new Julia process (same `julia`, same project), as the C
  library runs `sortann`; under `run_tool` (tests, precompilation) it runs
  `sortann_main` in-process with a fresh library state.
* `run_tool(tool, args; stdin, dir, env)` runs a tool in the current
  process with a fresh library state and captured streams, returning
  `(status, stdout_bytes, stderr_bytes)`: use it in unit tests.
* Register the tool's precompilation workload in its file (see below).

`bin/wfdbx.jl` loads the package (precompiled), runs `main_cli(ARGS)` and
exits with its status; an unknown tool gives a message and status 1.

Julia finds its package depot, which holds the compiled package, through
`HOME`. When `HOME` was changed (to give `~` names another meaning, as the
conformance suite does), `bin/wfdbx.jl` keeps using the depot of the user's
own home directory (from the password database), so that the package is
not compiled again. `JULIA_DEPOT_PATH`, if set, is used as given.

Remote files are read with the `Downloads` standard library, which is
loaded only when the first URL is opened. Each URL is requested at most
once per `Wfdb` instance.

## Startup time

Every conformance case starts a new Julia process, so the package must load
from its precompiled image without compiling anything at run time.
`src/precompile.jl` runs the registered workloads during precompilation
(guarded by `ccall(:jl_generating_output, Cint, ()) == 1`), so that the
native code they exercise is cached (Julia ≥ 1.9 package images). Each
library file or tool registers its workload where it is defined:

```julia
register_workload("rdsamp") do
    with_workload_data() do dir             # temp copy of tests/data, cwd
        workload_tool("rdsamp", "-r", "100s", "-t", "1")   # run_tool, WFDB=.
        workload_tool("rdsamp", "-r", "100s", "-p", "-v", "-t", "0.5")
    end
end
```

Cover each option and code path (signal formats, annotation paths, error
paths), keep the workloads short, and avoid type instabilities (they force
run-time compilation of the unforeseen cases: code reached by a run-time
dispatch is not saved in the package image even if the workload ran it).
Two common causes:

* a closure (including a comprehension or generator such as
  `[zeros(n) for _ in 1:k]`) that captures a local variable assigned more
  than once in the function: the variable is boxed and loses its type in
  the *whole* function. Use a loop or a helper function instead.
* a varargs function declared `f(fmt, args...)`: Julia does not
  specialize it for calls that repeat an argument type (two `Int32`s),
  which then go through a run-time dispatch. Declare such functions
  `f(fmt, args::Vararg{Any,N}) where {N}`, which forces specialization (as
  `cformat`, `cprintf`, `ceprintf`, `cfprintf` and `wfdb_error` are).

Check that a run compiles nothing:

```sh
cd tests/data && julia --startup-file=no --trace-compile=stderr \
    --project=../../julia ../../julia/bin/wfdbx.jl rdsamp -r 100s -t 1 >/dev/null
```

prints every method compiled at run time (there should be none). Measured:
`wfdbwhich` takes about 0.23 s, of which 0.21 s is Julia's own startup
(`julia -e 'exit()'`).

Measured throughput: in one
process, `rdsamp` prints a record of 648,000 two-signal frames (format 212)
in about 0.10 s in raw units and 0.13 s in physical units (`-p`); the C
`rdsamp` takes about 0.13 s and 0.39 s on the same machine. `write_record`
(which calls `putvec` for each frame) writes 216,000 two-signal frames in
0.01-0.02 s in every format, about as fast as `read_record` reads them
back. `getvecs(v, n)` (a WFDB-x addition) reads `n` sample vectors at
once; `read_record` uses it. Its bulk path (`_bulk_frames!` in
`signal.jl`) decodes whole frames straight from the input buffers, one loop
per signal, for every record without deskewing or resampling whose signals
are in the formats 8, 16, 24, 32, 61, 80, 160, 212, 310 or 311 (or null
signals): records of several sampling frequencies (in low- and
high-resolution modes) and the segments of multi-segment records (mapped to
the layout signals when the layout varies) included. The frames it cannot
take (at a buffer boundary, at the checksum frame, at a segment boundary,
in the middle of a frame in high-resolution mode) go through `getvec`; the
results and the library state are identical. The tests turn it off with
`WFDBX._BULK_ENABLED[] = false` and count the vectors it read with
`WFDBX._BULK_VECTORS[]`.

Changing any source file invalidates the package image: the next process
precompiles again (with the workloads; parallel processes wait for it).

## Testing

```sh
julia --project=julia -e 'using Pkg; Pkg.test()'            # unit tests
python3 tests/conformance/harness.py check --impl julia      # conformance
python3 tests/conformance/harness.py check --impl julia rdsamp -v   # one tool
```
