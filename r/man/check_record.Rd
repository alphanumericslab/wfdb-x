\name{check_record}
\alias{check_record}
\alias{format.wfdbx_check_report}
\alias{print.wfdbx_check_report}
\title{Check a Record}
\description{
  \code{check_record} checks a record (its header, its signal
  specifications, all the samples of its signal files) and the
  annotation files given, and reports every problem it finds, each with a
  severity.  Problems in the record are reported, not raised as errors.
}
\usage{
check_record(record, annotators = character(0), input_dir = NULL,
             network = NULL)

\method{format}{wfdbx_check_report}(x, \dots)
\method{print}{wfdbx_check_report}(x, \dots)
}
\arguments{
  \item{record}{the record name, such as \code{"100s"}.  A full path, a
    \code{~} path or a URL is used as given; any other name is read from
    the input directory (see \code{\link{wfdbx_set_input_dir}}).}
  \item{annotators}{a character vector of the annotators to check, such
    as \code{"atr"}.  By default none.}
  \item{input_dir}{the input directory for this call only: a local
    directory, a \code{~} path or a URL.  \code{NULL}, the default, keeps
    the current setting.}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting.}
  \item{x}{a report returned by \code{check_record}.}
  \item{\dots}{not used.}
}
\details{
  The severities are:
  \tabular{ll}{
    \code{"error"} \tab the record is damaged or does not follow the WFDB
      format; programs will read wrong data or fail \cr
    \code{"warning"} \tab the record can be read, but something is missing
      or unusual, and may give wrong results \cr
    \code{"info"} \tab a fact worth knowing, such as invalid (missing)
      samples \cr
  }
  The text form has one line per problem, \samp{SEVERITY: WHERE: MESSAGE}
  (without \samp{WHERE: } for the record itself), such as
  \preformatted{error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13}
  or the single line \samp{no problems found}.  The lines are the same in
  every implementation of WFDB-x.

  The checks run in normal mode, even if legacy mode is on (see
  \code{\link{wfdbx_set_legacy}}), and the library prints no messages
  during the call; both settings are restored afterwards.  Each call
  closes anything opened with the WFDB library functions, as
  \code{\link{wfdbquit}} does.

  It checks for problems similar to those found by Benjamin Moody's
  wfdbcheck (\url{https://github.com/bemoody/wfdbcheck}).
}
\value{
  An object of class \code{"wfdbx_check_report"}: a list with
  \item{record}{the record name, as given.}
  \item{ok}{\code{TRUE} if no problem has the severity \code{"error"}.}
  \item{issues}{a data frame with one row per problem, in the order of the
    checks, and the columns \code{severity} (\code{"error"},
    \code{"warning"} or \code{"info"}), \code{code} (a stable identifier,
    such as \code{"checksum"} or \code{"gain_missing"}), \code{where}
    (\code{""} for the record, \code{"signal N"}, \code{"segment SEG"},
    \code{"segment SEG, signal N"} or \code{"annotator ANN"}) and
    \code{message}.}
  \code{format} returns the text form as a character vector, one element
  per line; \code{print} prints it.
}
\note{
  An error is raised only for invalid arguments: \code{record} is not a
  single non-empty string, or \code{annotators} is not a character
  vector.
}
\section{Origin}{
  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_record}}, \code{\link{read_annotations}}.
}
\examples{
old <- setwd(tempdir())
## "chk" is a record written by this example.
write_record("chk", cbind(0:999, 999:0), fs = 250, gains = 200, adcres = 16,
             units = "mV", names = c("ECG I", "ECG II"))
write_annotations("chk", "tst", c(100, 350, 1200), symbol = c("N", "V", "N"))
report <- check_record("chk", "tst")
report
report$ok
report$issues$code
setwd(old)
}
\keyword{file}
