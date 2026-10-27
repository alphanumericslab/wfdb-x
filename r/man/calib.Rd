\name{calopen}
\alias{calopen}
\alias{getcal}
\alias{putcal}
\alias{newcal}
\alias{flushcal}
\alias{WFDB_AC_COUPLED}
\alias{WFDB_DC_COUPLED}
\alias{WFDB_CAL_SQUARE}
\alias{WFDB_CAL_SINE}
\alias{WFDB_CAL_SAWTOOTH}
\alias{WFDB_CAL_UNDEF}
\title{Calibration List}
\description{
  The calibration list gives, for each type of signal (such as ECG or
  blood pressure) and physical units, the characteristics of its
  calibration pulses and its customary plotting scale.  It is read from
  and written to calibration files (\file{wfdbcal}, see the \emph{WFDB
  Applications Guide}).  These functions read, search, extend and write
  the list.
}
\usage{
calopen(cfname = NULL)
getcal(desc, units)
putcal(cal)
newcal(cfname)
flushcal()
}
\arguments{
  \item{cfname}{the name of a calibration file.  \code{calopen} reads
    it under the input directory (see \code{\link{getwfdb}}; in legacy
    mode, it looks for it in the WFDB path); a missing file is not an
    error; by default it reads
    the file named by the environment variable \env{WFDBCAL}, or
    \file{wfdbcal}.  A leading \code{"+"} appends the entries of the file
    to the list instead of replacing it.}
  \item{desc}{a signal description, such as \code{"ECG lead II"}, or
    \code{NULL} to match any signal type.}
  \item{units}{physical units, such as \code{"mV"}, or \code{NULL} to
    match any units.}
  \item{cal}{a calibration entry, made by \code{\link{calinfo}}.}
}
\details{
  \code{getcal} returns the first entry of the list whose signal type is a
  prefix of \code{desc} and whose units are \code{units}.  \code{putcal}
  appends an entry to the list, \code{newcal} writes the list to a file,
  and \code{flushcal} empties the list.

  The \code{caltype} field of an entry is the sum of
  \code{WFDB_AC_COUPLED} (0) or \code{WFDB_DC_COUPLED} (1), and the shape
  of the calibration pulse: \code{WFDB_CAL_SQUARE} (2),
  \code{WFDB_CAL_SINE} (4), \code{WFDB_CAL_SAWTOOTH} (6) or
  \code{WFDB_CAL_UNDEF} (8, undefined).
}
\value{
  \code{calopen} returns 0, or -2 if the file cannot be read.

  \code{getcal} returns \code{list(stat, cal)}: \code{stat} is 0 and
  \code{cal} the entry found, or \code{stat} is -1 and \code{cal} is
  \code{NULL} if there is none.

  \code{putcal} returns 0.  \code{newcal} returns 0, or -1 if the file
  cannot be written.  \code{flushcal} returns \code{NULL}, invisibly.
}
\section{Origin}{
  Translation of the C functions calopen(), getcal(), putcal(), newcal()
  and flushcal() (lib/calib.c, WFDB 10.7.0): same arguments and results.
  Differences: the calibration file is read from the input directory,
  not searched for in the WFDB path; see \file{docs/DIVERGENCES.md}.
}
\seealso{\code{\link{calinfo}}.}
\examples{
putcal(calinfo(low = 0, high = 1, scale = 1, sigtype = "ECG", units = "mV",
               caltype = WFDB_DC_COUPLED + WFDB_CAL_SQUARE))
r <- getcal("ECG lead II", "mV")
r$stat
r$cal$scale
getcal("ABP", "mmHg")$stat      # -1: no entry
flushcal()
}
