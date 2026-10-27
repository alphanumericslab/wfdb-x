\name{wfdbx_set_legacy}
\alias{wfdbx_set_legacy}
\alias{wfdbx_get_legacy}
\alias{wfdbx_legacy_args}
\title{Legacy Mode}
\description{
  Legacy mode reproduces the original WFDB package exactly, including its
  assumed signal parameters and its search for files.  Use it only to
  reproduce old results.  \code{wfdbx_set_legacy} turns it on or off for
  the whole library, \code{wfdbx_get_legacy} tells whether it is on, and
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
  \item{argv}{the arguments of a tool, as a character vector whose first
    element is the tool's name.}
}
\details{
  Legacy mode is off by default.  You can also turn it on in two other
  ways:
  \itemize{
    \item for a tool, with \option{--legacy} as its first argument, as in
      \code{wfdbx_tool("rdsamp", c("--legacy", "-r", "100s"))}, which
      prints the sample record \code{100s} (the first minute of record
      100 of the MIT-BIH Arrhythmia Database, included with wfdb-x in the
      \file{tests/data} directory of a copy of the repository) when that
      directory is in the WFDB path (in legacy mode, files are searched
      for in the WFDB path: see \code{\link{setwfdb}});
    \item for one call of a high-level function, with \code{legacy =
      TRUE} (see \code{\link{read_record}}).
  }
  \file{docs/DIVERGENCES.md} in the wfdb-x sources
  (\url{https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode})
  describes what changes in legacy mode.
}
\value{
  \code{wfdbx_set_legacy} returns the previous setting and
  \code{wfdbx_get_legacy} the current one, \code{TRUE} or \code{FALSE}.

  \code{wfdbx_legacy_args} returns a list with two elements: \code{argv},
  the arguments without \option{--legacy}, and \code{legacy}, \code{TRUE}
  if \option{--legacy} was the first argument after the tool's name.  In
  that case it also turns legacy mode on.
}
\section{Origin}{
  Part of wfdb-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_record}}, \code{\link{wfdbx_tool}}.
}
\examples{
old <- wfdbx_set_legacy(TRUE)
wfdbx_get_legacy()
wfdbx_set_legacy(old)

## Only the arguments are parsed: no record is read.
a <- wfdbx_legacy_args(c("rdsamp", "--legacy", "-r", "100s"))
a$argv
wfdbx_set_legacy(FALSE)
}
