# Third-party sources

The original WFDB Software Package, version 10.7.0, kept unmodified as the
reference implementation of the WFDB-x tests:

* `wfdb-main.zip`: the C sources of the library and tools (by George B.
  Moody, Benjamin Moody and contributors), including the WFDB Programmer's
  Guide. Library: GNU Library General Public License, version 2 or later;
  tools: GNU General Public License, version 2 or later.
* `wag.pdf`: the WFDB Applications Guide, which describes the tools.

The official WFDB software is maintained by the WFDB project
(https://wfdb.io/software/) and distributed by PhysioNet
(https://physionet.org/content/wfdb/).

## libFLAC

The FLAC decoders of all seven implementations of WFDB-x are translations of
the stream decoder of libFLAC 1.4.3 (`src/libFLAC/stream_decoder.c` and
`bitreader.c`, and the restore functions of `fixed.c` and `lpc.c`), by Josh
Coalson and the Xiph.Org Foundation, distributed under the BSD-3-Clause
license. They are translated so that damaged FLAC files are decoded,
resynchronized and reported exactly as by the C library, which uses libFLAC;
WFDB-x needs no external library at run time. The FLAC encoders are WFDB-x's
own code.

Each decoder source file carries libFLAC's copyright and license notice:
`python/src/wfdbx/_flac.py`, `cpp/src/flac.cpp`, `cpp/src/flac.hpp`,
`rust/src/flac.rs`, `julia/src/flac.jl`, `r/R/flac.R`,
`matlab/+wfdbx/+internal/flac_decoder.m` and
`kotlin/src/commonMain/kotlin/wfdbx/Flac.kt`. libFLAC's sources are not
included in this repository (they are available from https://xiph.org/flac/).
