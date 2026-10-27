# Authors

wfdb-x ports the C code of the WFDB Software Package, version 10.7.0
(`third_party/wfdb-main.zip`), to Python, C++, MATLAB/Octave, Rust, Julia,
R and Kotlin. **wfdb-x was developed by Reza Sameni (2026), through AI-assisted
development, cross-language verification and unit testing; the C code it ports was written by George B. Moody,
Benjamin Moody and the other authors credited below.** This file says who wrote the C code
that each part of wfdb-x is a port of.

## File headers

The header comment of every wfdb-x source file that translates a C file
gives the same credit in short form, in the same order in every language:

1. that the file is part of wfdb-x, an independent reimplementation of the
   WFDB Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and
   Kotlin;
2. the C file or files it translates and their authors (for example, "It is
   a Python translation of lib/annot.c from the WFDB Software Package
   10.7.0, by George B. Moody");
3. "Changes from the original": how the file differs from the C code (each
   change is marked "wfdb-x:" in the code, and
   [`DIVERGENCES.md`](DIVERGENCES.md) gives the reasons), or "none, apart
   from the language";
4. the copyright of the C file, with its revisers (for example, "Copyright
   (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin Moody"), and
   "*Language* translation and changes: Copyright (C) 2026 Reza Sameni";
5. the license: the GNU General Public License, version 3 or later.

Tests and other code with no C original (see
[below](#code-that-wfdb-x-doesnt-port-from-a-wfdb-c-file)) say instead that
they have no counterpart in the original package, and carry only the wfdb-x
copyright and the license.

## Where these credits come from

* **Author and dates.** The first line of every C source names its author and
  the date it was first written (`/* file: signal.c  G. Moody  13 April
  1989`). The second line gives the date of the last revision (`Last revised:
  18 May 2022`).
* **Copyright.** The `Copyright (C)` line of each C header comment. Every
  ported file names George B. Moody as the only copyright holder, except
  `parsescp.c`, which names George B. Moody and Edna S. Moody, and
  `ahaecg2mit.c`, which has no copyright or license notice.
* **Revisions after 2013.** The "Last revised" dates after 2013 come from
  changes made by Benjamin Moody, who maintained the package from 2014 to
  2022. The C sources don't name him; the evidence is the upstream git
  history (`github.com/bemoody/wfdb`, tag `10.7.0`). In that history, George
  B. Moody's commits are whole releases ("Version 10.x.y", 2000-2014), and
  the individual commits from 2014 on are by Benjamin Moody. The table counts
  only commits that change code. It leaves out commits that only changed
  comments, such as "Update WFDB contact information" and "Remove outdated
  FSF postal address" (2018). Patches he contributed before 2014 are credited
  in `NEWS` and in the "Recent Changes" chapter of the WFDB Programmer's
  Guide (`doc/wpg-src/wpg0.tex`), and those years are included.
* **Contributions in the sources.** Comments that credit someone ("Thanks
  to", "contributed by", ...) in the ported C sources, and the
  acknowledgments in `NEWS`, `README.NETFILES` and the WFDB Programmer's
  Guide.

Licenses of the C package: the library (`lib/`) is under the GNU Library
General Public License, version 2 or later (`lib/COPYING.LIB`). The
applications (`app/`, `convert/`) are under the GNU General Public License,
version 2 or later (`COPYING`). This was checked in each file's own
notice. The one exception is `ahaecg2mit.c`,
which has no notice; it is covered by the package's `COPYING` (GPL), like
the rest of `convert/`.

## Library (LGPL-2+)

| C file | Author (first written) | Last revised | Copyright | Revisions and contributions |
|---|---|---|---|---|
| `lib/wfdbio.c` | G. Moody (18 Nov 1988) | 11 Apr 2022 | (C) 1988-2013 George B. Moody | Revised 2010-2022 by Benjamin Moody (e.g. `resetwfdb` work, 2010; `wfdb_getline`, 2022). The HTTP/FTP "NETFILES" code was first written by Michael Dakin (1999, libwww) and rewritten by Benjamin Moody (2005, libcurl); wfdb-x doesn't port it: its network access (off by default, URLs only; see [`DIVERGENCES.md`](DIVERGENCES.md)) is its own. Fred Geheb supplied a patch for indirect (`@FILE`) WFDB paths (2004). The idea of inserting path components at the head in `wfdb_addtopath` came from David Brooks. |
| `lib/signal.c` | G. Moody (13 Apr 1989) | 18 May 2022 | (C) 1989-2013 George B. Moody | Revised 2011-2022 by Benjamin Moody. His work includes `fstrtim`, `ftimstr` and `fmstimstr` and the base-time precision fixes (10.5.8, 2011), the `putinfo` fix (2012), the `strtim` bracket fix (2013), variable-layout records (per the WFDB Programmer's Guide) and **FLAC signal formats 508/516/524 (2020)**. Other contributions: `edfparse` overflow fix from Joonas Paalasmaa, `make_vsd` leak fix from Yinqi Zhang (2008), `getspf` rounding reported by Guido Muesch (credited in a comment), `isigopen` search optimization suggested by David Brooks (2011). `datstr`/`strdat` are "based on similar functions in chapter 1 of *Numerical Recipes* (Press, Flannery, Teukolsky and Vetterling)" (comment in the source). |
| `lib/annot.c` | G. Moody (13 Apr 1989) | 4 Nov 2020 | (C) 1989-2013 George B. Moody | Revised 2015-2020 by Benjamin Moody. Virginia Faro-Maza fixed a bug in `iannsettime` (2012). |
| `lib/calib.c` | G. Moody (4 Jul 1991) | 11 Apr 2022 | (C) 1991-2013 George B. Moody | Revised 2019-2022 by Benjamin Moody (wildcard `*` entries, no line-length limit). |
| `lib/wfdbinit.c` | G. Moody (23 May 1983) | 28 Apr 2020 | (C) 1983-2012 George B. Moody | Revised 2012-2019 by Benjamin Moody (`putinfo` fix, 2012). |
| `lib/wfdb.h` | G. Moody (13 Jun 1983) | 18 May 2022 | (C) 1983-2013 George B. Moody | Revised 2010-2020 by Benjamin Moody. |
| `lib/wfdblib.h` | G. Moody (13 Apr 1989) | 11 Apr 2022 | (C) 1989-2012 George B. Moody | Revised 2017-2022 by Benjamin Moody. |
| `lib/ecgcodes.h` | **T. Baker and G. Moody** (Jun 1981) | 29 Apr 1999 | (C) 1999 George B. Moody | none |
| `lib/ecgmap.h` | G. Moody (8 Jun 1983) | 4 May 1999 | (C) 1999 George B. Moody | none |

## Applications (`app/`, GPL-2+)

| C file | Author (first written) | Last revised | Copyright | Revisions and contributions |
|---|---|---|---|---|
| `app/rdsamp.c` | G. Moody (23 Jun 1983) | 18 May 2022 | (C) 1983-2010 George B. Moody | Revised 2017-2020 by Benjamin Moody. Ikaro Silva reported a format-32 overflow, with a test case (2010). |
| `app/wrsamp.c` | G. Moody (10 Aug 1993) | 18 May 2022 | (C) 1993-2014 George B. Moody | Revised 2020 by Benjamin Moody (FLAC formats). |
| `app/rdann.c` | **T. Baker and G. Moody** (27 Jul 1981) | 27 Apr 2020 | (C) 1981-2010 George B. Moody | Revised 2017-2018 by Benjamin Moody. |
| `app/wrann.c` | G. Moody (6 Jul 1983) | 24 Apr 2020 | (C) 1983-2010 George B. Moody | Revised 2018 by Benjamin Moody. |
| `app/sortann.c` | G. Moody (7 Apr 1997) | 24 Apr 2020 | (C) 1997-2010 George B. Moody | Revised 2017-2018 by Benjamin Moody. |
| `app/ann2rr.c` | G. Moody (16 May 1995) | 4 Nov 2020 | (C) 1995-2009 George B. Moody | Revised 2018-2020 by Benjamin Moody. |
| `app/rr2ann.c` | G. Moody (29 Nov 1999) | 6 Dec 2000 | (C) 2000 George B. Moody | none |
| `app/wfdbdesc.c` | G. Moody (Jun 1989) | 12 May 2020 | (C) 1989-2012 George B. Moody | Revised 2018-2020 by Benjamin Moody. |
| `app/wfdbtime.c` | G. Moody (16 Feb 2009) | 27 Apr 2020 | (C) 2001 George B. Moody (sic: before the file date) | Revised 2017-2018 by Benjamin Moody. |
| `app/time2sec.c` | G. Moody (9 Jul 2003) | 14 Mar 2009 | (C) 2003-2009 George B. Moody | none |
| `app/sampfreq.c` | G. Moody (7 Jun 1998) | 29 Jul 2012 | (C) 1998-2012 George B. Moody | none |
| `app/signame.c` | G. Moody (9 Apr 2008) | (none given) | (C) 2008 George B. Moody | The header line says `file: signum.c` (copied from `signum.c`). |
| `app/signum.c` | G. Moody (9 Apr 2008) | 27 Sep 2021 | (C) 2008 George B. Moody | Revised 2021 by Benjamin Moody (output format). |
| `app/sigamp.c` | G. Moody (30 Nov 1991) | 27 Apr 2020 | (C) 1991-2009 George B. Moody | Revised 2018 by Benjamin Moody. |
| `app/snip.c` | G. Moody (30 Jul 1989) | 18 Aug 2021 | (C) 1989-2013 George B. Moody | Revised 2011-2021 by Benjamin Moody (multi-segment and output-format patches in 10.5.9/10.5.11, 2011-2012; later fixes). |
| `app/xform.c` | G. Moody (8 Dec 1983) | 18 May 2022 | (C) 1983-2010 George B. Moody | Revised 2017-2020 by Benjamin Moody (multi-frequency fixes, FLAC formats). |
| `app/wfdbcat.c` | G. Moody (3 Mar 2000) | 18 May 2018 | (C) 2000 George B. Moody | Revised 2018 by Benjamin Moody. |
| `app/wfdbwhich.c` | G. Moody (20 Jun 1990) | 5 May 1999 | (C) 1999 George B. Moody | none |

## Format converters (`convert/`, GPL-2+)

| C file | Author (first written) | Last revised | Copyright | Revisions and contributions |
|---|---|---|---|---|
| `convert/edf2mit.c` | G. Moody (16 Oct 1996) | 18 Nov 2008 | (C) 1996-2004 George B. Moody | none |
| `convert/mit2edf.c` | G. Moody (2 Nov 2002) | 18 May 2022 | (C) 2002-2014 George B. Moody | Revised 2020 by Benjamin Moody (FLAC formats). |
| `convert/rdedfann.c` | G. Moody (14 Mar 2008) | 5 Mar 2014 | (C) 2008-2014 George B. Moody | **Luca Citi** contributed a bug fix and the `-x` option (10.5.23, 2014). |
| `convert/wav2mit.c` | G. Moody (12 Feb 2003) | 23 Dec 2004 | (C) 2003-2004 George B. Moody | none |
| `convert/mit2wav.c` | G. Moody (12 Feb 2003) | 22 Mar 2018 | (C) 2003-2010 George B. Moody | Revised 2018 by Benjamin Moody (multi-frequency input). Greg Downs fixed an uninitialized variable (2009). |
| `convert/wfdb2mat.c` | G. Moody (26 Feb 2009) | 16 Jun 2021 | (C) 2009-2013 George B. Moody | Revised 2014-2021 by Benjamin Moody ("version 5" .mat output, multi-frequency input, etc.). |
| `convert/a2m.c` | G. Moody (9 Jun 1983) | 27 Jul 2010 | (C) 1983-2010 George B. Moody | none |
| `convert/m2a.c` | G. Moody (9 Jun 1983) | 26 Apr 2001 | (C) 2001 George B. Moody | none |
| `convert/ad2m.c` | G. Moody (26 Aug 1983) | 20 Dec 2007 | (C) 1983-2007 George B. Moody | none |
| `convert/md2a.c` | G. Moody (19 Jul 1983) | 26 Apr 2001 | (C) 2001 George B. Moody | none |
| `convert/ahaecg2mit.c` | G. Moody (7 May 2008) | 11 Dec 2017 | **none** (no copyright or license notice) | Revised 2017 by Benjamin Moody (printf format fix). |
| `convert/makeid.c` | G. Moody (19 Jul 1983) | 5 Jun 2003 | (C) 2003 George B. Moody | none |
| `convert/readid.c` | G. Moody (8 Aug 1983) | 9 Jun 2005 | (C) 1983-2005 George B. Moody | none |
| `convert/revise.c` | G. Moody (8 Feb 1991) | 18 May 2018 | (C) 1999 George B. Moody | Revised 2018 by Benjamin Moody. |
| `convert/parsescp.c` | **G. Moody and E. Moody** (10 Jan 2000) | 4 Nov 2020 | (C) 2000-2014 **George B. Moody and Edna S. Moody** | Revised 2016-2020 by Benjamin Moody. |

## Code that wfdb-x doesn't port from a WFDB C file

Some files are wfdb-x's own code and credit no C author. These include the C
standard-library emulation (`_cstd.py`, `rust/src/cstd*`,
`matlab/+wfdbx/+internal/c*.m`, `kotlin/src/commonMain/kotlin/wfdbx/cstd/`, ...), the high-level APIs, the command-line drivers and the tests.

The FLAC codec (`cpp/src/flac.cpp`, `rust/src/flac.rs`, `julia/src/flac.jl`,
`kotlin/src/commonMain/kotlin/wfdbx/Flac.kt`, the codec parts of
`python/src/wfdbx/_flac.py` and `r/R/flac.R`, and the MATLAB `flac_crc`,
`flac_decode`, `flac_encode_frame`, `flac_streaminfo` and `flac_block_end`
functions) is also wfdb-x's own: an independent implementation of the FLAC
format. The C library uses libFLAC instead. The code that connects FLAC to
the WFDB signal functions is different: it translates the FLAC support of
`lib/signal.c`, written by Benjamin Moody (2020), and is credited to him.

## Package-level acknowledgments

The WFDB Programmer's Guide (`doc/wpg-src/wpg0.tex`, "Many friends have
contributed to the development of the WFDB library") thanks the following
people:

* **Contributors:** Paul Albrecht, Ted Baker, Phil Devlin, Scott Greenwald,
  Thomas Heldt, Isaac Henry, David Israel, Roger Mark, Joe Mietus, Warren
  Muldrow, Ikaro Silva, Wei Zong, and "especially Paul Schluter, whose
  elegant 8080 assembly language functions inspired these (long live
  getann!)".
* **Bug reports and fixes:** Omar Abdala, Winton Baker, David Brooks, Bob
  Farrell, Virginia Faro-Maza, Ion Gaztañaga, Fred Geheb, Mathias Gruber,
  Thomas Heldt, Isaac Henry, Justin Leo Chang Loong, Benjamin Moody, Guido
  Muesch, Joonas Paalasmaa, Tony Ricke, Dave Schaffer, Dan Scott, Allavatam
  Venugopal, Mauro Villarroel, Andrew Walsh, Piotr Wlodarek and Yinqi Zhang.

The guide also credits several pieces of work that wfdb-x doesn't port:

* Mike Dakin wrote the first NETFILES (HTTP client) implementation, which
  Benjamin Moody later reimplemented with libcurl.
* Benjamin Moody also implemented variable-layout records, which wfdb-x
  does port, in `signal.c`.
* Pat Hamilton and Bob Farrell made the classic Mac OS and MS Windows
  ports.
* Jose Garcia Moros and Salvador Olmos made the Matlab/Octave
  reimplementations.
* Jonas Carlson wrote the Matlab wrappers, and Michael Craig wrote the WFDB
  Toolbox for Matlab.
* Isaac Henry wrote the SWIG wrappers.

## wfdb-x

The Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin reimplementations were
developed by Reza Sameni (2026), through AI-assisted development,
cross-language verification and unit testing (see "How wfdb-x was
developed" in the project README). They are distributed under the GNU
General Public License, version 3 or later (`LICENSE`), which the "or later"
terms of the C code's licenses allow.
