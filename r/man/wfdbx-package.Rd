\name{wfdbx-package}
\alias{wfdbx-package}
\alias{wfdbx}
\docType{package}
\title{WFDB-x: The WFDB Software Package in Pure R}
\description{
  The \pkg{wfdbx} package reads and writes physiological signal records
  in the WFDB format used by PhysioNet.  It is a complete R
  implementation of the WFDB Software Package: the library and all of
  its command-line tools.  It reads and writes the same files as the
  original C library, and its tools print the same output.  It is written
  in base R only.

  WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
  that a record does not give.  Where one is needed, you must give it.
  Legacy mode (\code{\link{wfdbx_set_legacy}}) reproduces the original
  package exactly.  See
  \url{https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md}.
}
\details{
  You can use the package in three ways.

  \strong{High-level functions (recommended).}  \code{\link{read_record}},
  \code{\link{read_header}} and \code{\link{write_record}} read and write
  whole records, with the signals as a matrix.
  \code{\link{read_annotations}} and \code{\link{write_annotations}} read
  and write whole annotation files, as a data frame.

  \strong{Command-line tools.}  The tools (\command{rdsamp},
  \command{rdann}, \command{wrsamp}, \command{wfdbdesc}, \command{xform},
  \command{mit2edf}, ...) are run from R with \code{\link{wfdbx_tool}}, or
  from a shell with the driver script installed with the package.  This
  command describes the sample record \code{100s} (the first minute of
  record 100 of the MIT-BIH Arrhythmia Database, included with WFDB-x in
  the \file{tests/data} directory of a copy of the repository), read from
  that directory:
  \preformatted{WFDBX_INPUT_DIR=wfdb-x/tests/data \\
  Rscript "$(Rscript -e 'cat(system.file("bin", "wfdbx.R", package = "wfdbx"))')" wfdbdesc 100s}

  \strong{The WFDB library functions.}  The functions of the C library
  are available under their C names, as described in the \emph{WFDB
  Programmer's Guide} (\url{https://physionet.org/physiotools/wpg/}).
  They are grouped in these help pages:
  \itemize{
    \item \code{\link{isigopen}}: opening records, reading and writing
      samples, header files, info strings, unit conversion;
    \item \code{\link{timstr}}: conversion of times and dates;
    \item \code{\link{annopen}}: reading and writing annotations;
    \item \code{\link{annstr}}: annotation mnemonics and descriptions;
    \item \code{\link{ecgcodes}} and \code{\link{isann}}: annotation codes
      and their classification;
    \item \code{\link{calopen}}: the calibration list;
    \item \code{\link{getwfdb}}: finding files, error messages and version
      information;
    \item \code{\link{siginfo}}: the structures used by these functions.
  }
  Numbers are doubles.  Signal, group and annotator numbers start at 0, as
  in C.  C structures are lists with the C field names, and C \code{NULL}
  is \code{NULL}.  A function that fills arrays in C returns them: for
  example, \code{isigopen} returns \code{list(nsig, si)} and
  \code{getvec} returns \code{list(stat, v)}.  Errors are reported by
  return values and messages, as in C (see \code{\link{wfdbquiet}}), not
  by R errors.  The C function \code{sample} is
  \code{\link{wfdb_sample}}.  \code{\link{getframes}} and
  \code{\link{putframes}} read and write many frames at once.

  \strong{Where files are read and written.}  A full path, a \code{~} path
  or a URL is used as given.  Any other name is read from the input
  directory and written to the output directory, both the current
  directory by default.  URLs, such as the PhysioNet databases at
  \samp{https://physionet.org/files/<database>/<version>/}, are read only
  when network access is on.  See \code{\link{wfdbx_set_input_dir}}.
}
\section{License}{
  WFDB-x is distributed under the GNU General Public License, version 3
  or later (file \file{COPYING} in the installed package, \file{LICENSE}
  in the sources).
}
\author{
  The WFDB library and tools were written by George B. Moody, with
  revisions by Benjamin Moody (2010-2022, including FLAC support);
  \command{parsescp} by George B. Moody and Edna S. Moody, and
  \file{ecgcodes.h} and \command{rdann} by T. Baker and G. Moody (see
  \file{docs/AUTHORS.md} in the WFDB-x sources).  The R implementation was
  developed by Reza Sameni (2026), through AI-assisted development,
  cross-language verification and unit testing.

  WFDB-x is an independent reimplementation.  Its R code is a translation
  of the C code of the WFDB Software Package into R, written for WFDB-x;
  it is not code by the original WFDB developers.  It follows the
  original's logic and behavior, with the changes described in
  \url{https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md}.
  The authors of the original C code are credited in each file and in
  \url{https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md}.

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
## Write a small two-signal record, "demo" (written by this example), in a
## temporary directory, then read it back with the high-level and the
## low-level functions.
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
