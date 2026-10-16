\name{wfdbx_set_legacy}
\alias{wfdbx_set_legacy}
\alias{wfdbx_get_legacy}
\alias{wfdbx_legacy_args}
\title{Legacy Mode: the Original Package's Behavior}
\description{
  wfdb-x has no built-in signal parameters: it never assumes a sampling
  frequency, a gain, an ADC resolution or units.  For compatibility, legacy
  mode (a wfdb-x addition) restores the behavior of the original WFDB
  library 10.7.0, with its built-in defaults.  \code{wfdbx_set_legacy}
  turns it on or off, \code{wfdbx_get_legacy} tells whether it is on, and
  \code{wfdbx_legacy_args} recognizes the \option{--legacy} option of the
  tools.
}
\usage{
wfdbx_set_legacy(on)
wfdbx_get_legacy()
wfdbx_legacy_args(argv)
}
\arguments{
  \item{on}{\code{TRUE} to turn legacy mode on, \code{FALSE} to turn it
    off.}
  \item{argv}{the argument list of a tool, a character vector whose first
    element is the program name.}
}
\details{
  In legacy mode, a header without a sampling frequency means 250 Hz
  (\code{\link{WFDB_DEFFREQ}}), a missing ADC resolution is inferred from
  the storage format or taken as 12 bits (\code{\link{WFDB_DEFRES}}), the
  time conversion functions (\code{\link{strtim}}, \code{\link{timstr}},
  \code{\link{mstimstr}}) use 1 sample per second when no frequency is
  known, \code{\link{setifreq}} reports \dQuote{no open input record}, and
  the unit conversion functions (\code{\link{aduphys}}, ...) assume a gain
  of 200 (\code{\link{WFDB_DEFGAIN}}) for uncalibrated signals and invalid
  signal numbers (with a baseline of 0 for the latter).  The default is off.

  \option{--legacy} as the \emph{first} argument of any of the tools (see
  \code{\link{wfdbx_tool}}) is removed before the options are parsed, and
  the tool then behaves exactly as the original one (options, outputs,
  messages, help texts and exit statuses); the previous setting is
  restored when the tool ends.  The high-level functions
  (\code{\link{read_record}}, \code{\link{read_annotations}}, ...) have a
  \code{legacy} argument with the same effect for one call.

  Legacy mode reproduces the original package exactly, and is tested
  against its results.  It is kept for compatibility only: the values it
  assumes are exactly the silent defaults this project removed, so results
  produced with it carry the same risks (see \file{docs/DIVERGENCES.md} in
  the wfdb-x sources).
}
\value{
  \code{wfdbx_set_legacy} returns the previous setting and
  \code{wfdbx_get_legacy} the current one (\code{TRUE} or \code{FALSE}).
  \code{wfdbx_legacy_args} returns a list with the components \code{argv}
  (the argument list without \option{--legacy}) and \code{legacy}
  (\code{TRUE} if \option{--legacy} was the first argument after the
  program name, in which case legacy mode has been turned on).
}
\seealso{
  \code{\link{read_record}}, \code{\link{wfdbx_tool}}.
}
\examples{
old <- wfdbx_set_legacy(TRUE)
strtim("1:0")          # 60: 1 sample per second without a record
wfdbx_set_legacy(old)
wfdbx_get_legacy()

a <- wfdbx_legacy_args(c("rdsamp", "--legacy", "-r", "100s"))
a$argv
wfdbx_set_legacy(FALSE)
}
