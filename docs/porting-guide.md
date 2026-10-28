# Porting guide

This document describes how every WFDB-x implementation is organized, and the
details of the C implementation that an implementation must reproduce to pass
the conformance suite. The Python implementation (`python/src/wfdbx/`) is the
template for the others.

## Structure

Each implementation mirrors the C sources, file by file:

| C source (`third_party/wfdb-main.zip`) | Python module | Contents |
|---|---|---|
| `lib/wfdbio.c` | `_wfdbio.py` | input and output directories, network access, the WFDB path of legacy mode, `wfdb_open`, error reporting, binary I/O helpers |
| `lib/signal.c` | `_signal.py` | headers, signal I/O in all formats, time/date conversion, units |
| `lib/annot.c` | `_annot.py` | annotation I/O (MIT and AHA formats), mnemonics |
| `lib/calib.c` | `_calib.py` | calibration list |
| `lib/wfdbinit.c` | `_wfdbinit.py` | `wfdbinit`, `wfdbquit`, `wfdbflush` |
| `lib/ecgcodes.h`, `lib/ecgmap.h`, the mapping functions of `lib/annot.c` | `_ecgcodes.py` | annotation codes and mapping tables |
| FLAC support in `lib/signal.c` (libFLAC) | `_flac.py` | the FLAC support of the signal functions, a translation of libFLAC 1.4.3's stream decoder, and WFDB-x's own FLAC encoder |
| `app/*.c`, `convert/*.c` | `apps/*.py` | command-line tools |
| (C standard library) | `_cstd.py` | `strtol`, `strtod`, `strtok`, `sscanf`, `fgets`, glibc `rand`, `printf` details |

Ports of the library keep the C library's global state and its function
names, so that ports of the applications can follow the C sources line by
line. A high-level API in the idiom of the language is built on top.

## C semantics to reproduce

Reference platform: x86-64 Linux, glibc, `-DWFDB_LARGETIME`.

* **Integer types.** `WFDB_Time` and `long` are 64-bit; `int` and
  `WFDB_Sample` are 32-bit (wrap-around matters in checksums, format 8
  accumulation, and putvec slew limiting). `char` is **signed** (format 8
  differences, `r8()`, AHA codes, `edf2mit` byte handling).
* **Division** truncates toward zero; `%` takes the sign of the dividend.
* **Conversions** from `double` to integer truncate toward zero; out-of-range
  conversions to `int` yield `INT_MIN` on x86 (`d2i` in `_cstd.py`).
* **Parsing**: `strtol`/`strtod`/`atoi`/`atof` accept leading whitespace and
  stop at the first invalid character; `sscanf` returns `EOF` (-1) when the
  input ends before the first conversion, and leaves the remaining variables
  unchanged (several tools rely on stale values).
* **`strtok`** skips leading delimiters, and the header parser relies on its
  exact behavior (e.g. a signal description is the rest of the line after the
  single delimiter that ended the previous token).
* **`printf`**: `%g`, `%.12g`, `%f`, `%e` must match glibc exactly (correct
  rounding); NaN prints as `nan` or `-nan` according to its sign bit
  (`0.0/0.0` is `-nan` on x86); `%ld` and `%d` are printed the same way.
* **`fgets`** with a buffer of N bytes splits longer lines into pieces of N-1
  bytes.
* **glibc `rand()`** (used for dither by `wrsamp -d` and `xform -d`) after
  `srand(0)`: see `GlibcRand` in `_cstd.py`.
* **Text** is handled as bytes (ISO-8859-1 in Python): no encoding or
  newline translation anywhere. Header files are written with `\r\n` line
  endings.

## Library details that are easy to get wrong

* `readheader` (header parsing): record-name check quirks, `xSPF:SKEW+START`
  suffix parsing, default ADC resolution by format, units truncated to 50
  and descriptions to 100 characters, default description
  `record REC, signal N`.
* Skew is converted from samples to frames with rounding; deskewing uses a
  ring buffer of `skewmax + 1` frames.
* `getskewedframe`: the checksum of a signal is verified (with an error
  message and status -4) at the frame where its sample count reaches zero;
  end-of-file handling; invalid-sample values per format and `WFDB_GVPAD`.
* Bit-packed formats (212, 310, 311): the extra bytes written at the end of
  a file (`f212`, `f310`, `f311`) and the "extra zero sample" of format 310.
* `isgsetframe`: alignment of bit-packed groups when seeking; block-aligned
  seeks; non-seekable inputs.
* Multi-segment records: segment switching at end of file, variable-layout
  records and `sigmap()` rounding (halfway cases rounded up), null (`~`)
  segments.
* Multi-frequency records: `WFDB_LOWRES` averaging (`meansamp` rounding) and
  `WFDB_HIGHRES` zero-order hold; `setifreq` resampling.
* Time strings (`timstr`, `mstimstr`, `strtim`): elapsed vs. absolute
  times, the `[hh:mm:ss dd/mm/yyyy]` form, prefixes `c`, `e`, `f`, `i`, `o`,
  `s`, Julian date conversion (`datstr`, `strdat`).
* Annotations: the 16-bit word encoding with `SKIP`, `NUM`, `SUB`, `CHN`,
  `AUX` pseudo-annotations; modification labels (`NOTE` annotations at time
  0) consumed by `annopen`; the time-resolution record written when
  `setafreq` was called; out-of-order output sorted when the file is closed
  (in this process, with the result of `sortann`; by running `sortann` in
  legacy mode, as the original does).
* The counter frequency and base count are not reset by `wfdbquit()`.

## Applications

Each tool is a line-by-line port of its C source. Several C programs rely on
stale buffer contents, modify their arguments in place, or have undefined
behavior; [`KNOWN_C_BEHAVIORS.md`](KNOWN_C_BEHAVIORS.md) lists them, with the
behavior chosen by WFDB-x where C's is undefined.

Messages that include the program name use the name the program was invoked
by (`argv[0]` or its last path component, as the C source does). Ports must
arrange for this to be the tool's name (e.g. `rdsamp`), as the conformance
suite expects.
