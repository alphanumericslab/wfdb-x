\name{wfdbx_set_input_dir}
\alias{wfdbx_set_input_dir}
\alias{wfdbx_get_input_dir}
\alias{wfdbx_set_output_dir}
\alias{wfdbx_get_output_dir}
\alias{wfdbx_set_network}
\alias{wfdbx_get_network}
\title{Input Directory, Output Directory and Network Access}
\description{
  These functions set and return where records are read and written, and
  whether URLs may be opened.  They apply to the high-level functions, the
  command-line tools run with \code{\link{wfdbx_tool}}, and the WFDB
  library functions.
}
\usage{
wfdbx_set_input_dir(dir)
wfdbx_get_input_dir()
wfdbx_set_output_dir(dir)
wfdbx_get_output_dir()
wfdbx_set_network(on)
wfdbx_get_network()
}
\arguments{
  \item{dir}{\code{wfdbx_set_input_dir}: the input directory, a local
    directory, a \code{~} path or the URL of a directory.
    \code{wfdbx_set_output_dir}: the output directory, a local directory.
    \code{NULL} or \code{""} restores the default.}
  \item{on}{\code{TRUE} or 1 to allow network access, \code{FALSE} or 0
    to forbid it.  \code{NULL} or a negative number restores the
    default.}
}
\details{
  WFDB-x reads and writes files exactly where you name them.  A full path,
  a \code{~} path or a URL is used as given.  Any other name, such as
  \code{"100"}, \code{"mitdb/100"} or \code{"../data/100"}, is read from
  the input directory and written to the output directory.  A URL cannot
  be written.  The signal files that a header names are read from the
  header's directory.

  Each setting has an environment variable, used until you call the
  function: \env{WFDBX_INPUT_DIR}, \env{WFDBX_OUTPUT_DIR} and
  \env{WFDBX_NETWORK} (set it to 1 to allow network access).  The default
  is the environment variable's value, or, if it is not set, the current
  directory and no network access.  The \code{input_dir} and
  \code{network} arguments of \code{\link{read_record}},
  \code{\link{read_header}} and \code{\link{read_annotations}}, and the
  \code{dir} argument of \code{\link{write_record}} and
  \code{\link{write_annotations}}, apply to one call.
  \code{\link{wfdbquit}} keeps the settings.

  The files of a PhysioNet database are at
  \samp{https://physionet.org/files/<database>/<version>/}.  Remote files
  are read once and kept for the rest of the R session.  A download gives
  up when it cannot connect, or receives nothing, for 30 seconds.  When
  network access is off, opening a URL fails with a message that says how
  to turn it on.
}
\value{
  The \code{set} functions return the previous setting, invisibly, and the
  \code{get} functions the current one.  A directory is a character
  string, or \code{NULL} for the current directory.  The network setting
  is 1 (allowed) or 0 (forbidden).

  \code{wfdbx_set_output_dir} does not accept a URL: it prints an error
  message, leaves the setting unchanged, and returns it.
}
\section{Origin}{
  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_record}}; \code{\link{setwfdb}} and
  \code{\link{getwfdb}}, the WFDB library functions for the input
  directory.
}
\examples{
old <- wfdbx_set_input_dir(tempdir())  # read relative names there
wfdbx_get_input_dir()
wfdbx_set_input_dir(old)

wfdbx_get_network()                    # 0: off by default

\dontrun{
## Read 10 seconds of record 100 of the MIT-BIH Arrhythmia Database.
wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
wfdbx_set_network(1)
rec <- read_record("100", sampto = "0:10")
}
}
