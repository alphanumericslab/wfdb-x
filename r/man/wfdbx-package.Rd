\name{wfdbx-package}
\alias{wfdbx-package}
\alias{wfdbx}
\docType{package}
\title{wfdb-x: The WFDB Software Package in Pure R}
\description{
  The \pkg{wfdbx} package is the R implementation of wfdb-x, a
  reimplementation of the WFDB Software Package 10.7.0 (the WFDB library
  and its command-line tools).  It reads and writes the signal, header and
  annotation files used by PhysioNet and its databases, in all WFDB
  formats (including EDF and FLAC-compressed signals), exactly as the
  original C library does.  It is written in base R only: there is
  nothing to compile and no other package is needed.

  One deliberate difference: wfdb-x never assumes a sampling frequency, a
  gain, an ADC resolution or units (the C library assumes 250 Hz, 200
  adu/mV, 12 bits and millivolts); functions and tools that need one that
  is not specified report an error.  See
  \file{docs/DIVERGENCES.md} in the wfdb-x sources, \code{\link{strtim}}
  and \code{\link{read_record}}.  The original behavior remains available,
  for compatibility only, in legacy mode (see
  \code{\link{wfdbx_set_legacy}}).
}
\details{
  The package offers three levels of access.

  \strong{High-level functions.}  \code{\link{read_record}},
  \code{\link{read_header}} and \code{\link{write_record}} read and write
  whole records (signals as a matrix);
  \code{\link{read_annotations}} and \code{\link{write_annotations}} read
  and write whole annotation files (as a data frame).  Most users only
  need these.

  \strong{The WFDB library.}  The functions of the C library are available
  under their C names and with their C semantics, as described in the
  \emph{WFDB Programmer's Guide}
  (\url{https://physionet.org/physiotools/wpg/}).  They are grouped in
  these help pages:
  \itemize{
    \item \code{\link{isigopen}}: opening records, reading and writing
      samples, header files, info strings, unit conversion;
    \item \code{\link{timstr}}: conversion of times and dates;
    \item \code{\link{annopen}}: reading and writing annotations;
    \item \code{\link{annstr}}: annotation mnemonics and descriptions;
    \item \code{\link{ecgcodes}} and \code{\link{isann}}: annotation codes
      and their classification;
    \item \code{\link{calopen}}: the calibration list;
    \item \code{\link{getwfdb}}: the WFDB path (where files are searched
      for), error messages and version information;
    \item \code{\link{siginfo}}: the structures used by these functions.
  }
  The translation from C follows a few simple rules.  All numbers are
  doubles.  Signal, signal-group and annotator numbers start at 0, as in
  C.  C structures are lists with the C field names, and C \code{NULL} is
  \code{NULL}.  Functions that fill arrays supplied by the caller in C
  return them instead, usually together with the C return value: for
  example \code{isigopen} returns \code{list(nsig, si)} and \code{getvec}
  returns \code{list(stat, v)}.  Errors are reported as in C, by a
  negative return value and a message on the standard error output (see
  \code{\link{wfdbquiet}}), not by R errors.  The C function
  \code{sample} is exported as \code{\link{wfdb_sample}}, so as not to
  mask \code{base::sample}.  In addition, \code{\link{getframes}} and
  \code{\link{putframes}} read and write many sample vectors at once.

  \strong{The command-line tools.}  The WFDB tools (\command{rdsamp},
  \command{rdann}, \command{wrsamp}, \command{wfdbdesc},
  \command{xform}, \command{mit2edf}, ...) are run from R with
  \code{\link{wfdbx_tool}}, or from a shell with the driver script
  installed with the package, for example:
  \preformatted{Rscript "$(Rscript -e 'cat(system.file("bin", "wfdbx.R", package = "wfdbx"))')" wfdbdesc 100s}
  They accept the same options and produce the same output, byte for
  byte, as the C programs.

  Files are searched for in the directories of the WFDB path (see
  \code{\link{getwfdb}}), which by default begins with the current
  directory.  Records on remote servers (\samp{http://} URLs in the WFDB
  path) are not supported.
}
\section{License}{
  The library code is distributed under the GNU Library General Public
  License, version 2 or later (file \file{LICENSE.LIB}), and the tools
  under the GNU General Public License, version 2 or later (file
  \file{COPYING} in the installed package, \file{LICENSE} in the
  sources).
}
\author{
  The WFDB library and tools were written by George B. Moody, with
  revisions by Benjamin Moody (2010-2022, including FLAC support);
  \command{parsescp} by George B. Moody and Edna S. Moody, and
  \file{ecgcodes.h} and \command{rdann} by T. Baker and G. Moody (see
  \file{docs/AUTHORS.md} in the wfdb-x sources).  The R implementation was
  written by Reza Sameni (October 2026).

  Maintainer: Reza Sameni \email{reza.sameni@gmail.com}
}
\references{
  Moody GB. \emph{WFDB Programmer's Guide}.
  \url{https://physionet.org/physiotools/wpg/}

  Moody GB. \emph{WFDB Applications Guide}.
  \url{https://physionet.org/physiotools/wag/}
}
\seealso{
  \code{\link{read_record}}, \code{\link{read_annotations}},
  \code{\link{isigopen}}, \code{\link{annopen}},
  \code{\link{wfdbx_tool}}.
}
\examples{
## Write a small two-signal record in a temporary directory, then read it
## back with the high-level and the low-level functions.
old <- setwd(tempdir())
x <- cbind(round(100 * sin(2 * pi * (0:999) / 250)), (0:999) \%\% 50)
write_record("demo", x, fs = 250, gains = 200, adcres = 16, names = c("sine", "ramp"),
             units = "mV")
rec <- read_record("demo", sampto = 3, physical = TRUE)
rec$signals

r <- isigopen("demo", 2)            # C-style: open both signals
r$nsig
getvec()$v                          # the first sample of each signal
wfdbquit()                          # close the record

wfdbx_tool("wfdbdesc", "demo")      # run a command-line tool
setwd(old)
}
\keyword{package}
