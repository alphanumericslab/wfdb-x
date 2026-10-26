\name{getwfdb}
\alias{getwfdb}
\alias{setwfdb}
\alias{resetwfdb}
\alias{wfdbquiet}
\alias{wfdbverbose}
\alias{wfdberror}
\alias{wfdbfile}
\alias{wfdbmemerr}
\alias{wfdb_me_fatal}
\alias{wfdbversion}
\alias{wfdbldflags}
\alias{wfdbcflags}
\alias{wfdbdefwfdb}
\alias{wfdbdefwfdbcal}
\alias{wfdbx_set_output_dir}
\alias{wfdbx_get_output_dir}
\alias{wfdbx_set_input_dir}
\alias{wfdbx_get_input_dir}
\alias{wfdbx_set_network}
\alias{wfdbx_get_network}
\alias{WFDB_READ}
\alias{WFDB_WRITE}
\alias{WFDB_AHA_READ}
\alias{WFDB_AHA_WRITE}
\alias{WFDB_APPEND}
\title{Finding Files, Error Messages and Library Information}
\description{
  wfdb-x finds the files of a record (headers, signal files, annotation
  files, calibration files) by explicit names: a relative name is read
  under the input directory and written under the output directory; an
  absolute name, a \code{~} name or a URL is used as given; nothing else
  is searched.  These functions set the input and output directories and
  the network permission, find the file of a record, control the error
  messages of the library, and give version information.  (In legacy mode,
  files are searched for in the WFDB path, as by the C library.)
}
\usage{
getwfdb()
setwfdb(p)
resetwfdb()
wfdbquiet()
wfdbverbose()
wfdberror()
wfdbfile(s, record)
wfdbmemerr(behavior)
wfdb_me_fatal()
wfdbversion()
wfdbldflags()
wfdbcflags()
wfdbdefwfdb()
wfdbdefwfdbcal()
wfdbx_set_input_dir(dir)
wfdbx_get_input_dir()
wfdbx_set_output_dir(dir)
wfdbx_get_output_dir()
wfdbx_set_network(on)
wfdbx_get_network()
}
\arguments{
  \item{p}{\code{setwfdb}: the input directory (a character string naming
    a single directory: components separated by spaces, tabs, newlines or
    semicolons, or colons outside URLs, are counted, and only one
    non-empty component is allowed; \code{""}, \code{";"} or \code{NULL}:
    the default).  In legacy mode, the new WFDB path: directory names
    separated as above; in a directory name, \code{"\%r"} stands for the
    record name; \code{"@file"} reads the path from \code{file};
    \code{NULL} uses the environment variable \env{WFDB}, or the default
    path if it is not set.}
  \item{s}{a file type (the extension of the file, such as \code{"hea"}
    or \code{"atr"}), or a file name if \code{record} is \code{NULL}.}
  \item{record}{a record name, or \code{NULL}.}
  \item{dir}{\code{wfdbx_set_input_dir}: the input directory (a local
    directory, a \code{~} name or the URL of a directory);
    \code{wfdbx_set_output_dir}: the directory in which output files are
    created (local).  \code{NULL} or \code{""}: the default (the
    environment variable \env{WFDBX_INPUT_DIR} or \env{WFDBX_OUTPUT_DIR}
    if it is set, otherwise none: the current directory).}
  \item{on}{\code{TRUE} or a positive number to allow network access,
    \code{FALSE} or 0 to forbid it, \code{NULL} or a negative number for
    the default (allowed if the environment variable \env{WFDBX_NETWORK}
    is a non-zero number).}
  \item{behavior}{the behaviour on memory allocation errors.  It is only
    stored, to be returned by \code{wfdb_me_fatal}, since such errors are
    handled by R.}
}
\details{
  wfdb-x (design decision of Reza Sameni, Oct 2026): a name is resolved
  to exactly one location.  \code{"-"} is the standard input or output;
  an absolute name (and on Windows \samp{X:\\}, \samp{X:/} or
  \samp{\\\\}) and an \samp{http://} or \samp{https://} URL are used
  as given; \samp{~} and \samp{~/...} are expanded to the home directory
  (\samp{~user/...} to that user's); any other (relative) name, which may
  contain directories and \samp{..}, is read as \file{INPUT_DIR/name} and
  written as \file{OUTPUT_DIR/name}, or used as given if the directory
  is not set (relative to the current directory).  Nothing is searched.
  The signal files and segments named in a header are read in the
  directory of that header (on disk or at its URL); such a name must not
  be absolute, begin with \samp{~}, be a URL or contain a \samp{..}
  component (\samp{init: file NAME named in the header of record REC is
  not in the header's directory}); \samp{~} as a segment (a null segment)
  and \samp{-} as a signal file keep their meaning.

  The settings are read from the environment variables
  \env{WFDBX_INPUT_DIR}, \env{WFDBX_OUTPUT_DIR} and \env{WFDBX_NETWORK}
  when first needed; the functions override them.  They are not reset by
  \code{\link{wfdbquit}}.  \code{wfdbx_set_output_dir} refuses a URL (an
  error message; the setting is unchanged and its current value is
  returned).  The \code{input_dir} and \code{network} arguments of
  \code{\link{read_record}}, \code{\link{read_header}} and
  \code{\link{read_annotations}}, and the \code{dir} argument of
  \code{\link{write_record}} and \code{\link{write_annotations}}, set
  them for the duration of a call.

  Network access is off by default: a URL is then not opened, and the
  first attempt prints \samp{wfdb-x: network access is disabled; set
  WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open URL}.  With it on,
  a remote file is read in full by the system program \code{curl} (or
  base R's \code{url()} if there is none): redirects are followed, an
  HTTP status of 400 or more is a failure, and reading gives up if
  connecting takes 30 s or no data arrives for 30 s, with no limit on the
  total time.  It is kept for the rest of the R session (each URL
  is requested at most once, failures included).  The files of a
  PhysioNet database are under
  \samp{https://physionet.org/files/<database>/<version>/}.

  \code{setwfdb} sets the input directory (see \code{p}); with more than
  one directory it reports \samp{setwfdb: wfdb-x reads from a single input
  directory; use wfdbx_set_input_dir (or legacy mode for the WFDB search
  path)} and changes nothing.  \code{getwfdb} returns the input directory,
  or \code{"."} if none is set; \code{resetwfdb} restores the value set
  by the last \code{setwfdb}.  The environment variable \env{WFDB} is not
  used: if it is set, the first lookup prints \samp{wfdb-x: the WFDB
  environment variable is ignored; set WFDBX_INPUT_DIR instead (or use
  legacy mode)}.

  Legacy mode (\code{\link{wfdbx_set_legacy}}) keeps the original
  behavior: the WFDB path is the value of the environment variable
  \env{WFDB} or, if it is not set, \code{wfdbdefwfdb()};
  \code{setwfdb} changes it (and also sets \env{WFDB}, and \env{WFDBCAL},
  \env{WFDBANNSORT} and \env{WFDBGVMODE} if they are not set);
  \code{wfdbquit} calls \code{resetwfdb}, which restores only the string
  returned by \code{getwfdb}; file names containing \samp{..} are
  refused, and no URL is opened (as by the reference C build, without
  network support).  The input directory and the network setting are not
  used in legacy mode; the output directory is (for any name).

  The library reports errors with a negative return value and a message
  on the standard error output.  \code{wfdbquiet} suppresses these
  messages and \code{wfdbverbose} enables them again; \code{wfdberror}
  returns the last one.

  \code{WFDB_READ} (0), \code{WFDB_WRITE} (1), \code{WFDB_AHA_READ} (2),
  \code{WFDB_AHA_WRITE} (3) and \code{WFDB_APPEND} (4) are the file modes
  used by \code{\link{anninfo}} (\code{WFDB_AHA_READ} and
  \code{WFDB_AHA_WRITE} are for annotation files in the AHA format).
}
\value{
  \code{getwfdb} returns the input directory, or \code{"."} (legacy
  mode: the WFDB path).

  \code{wfdbfile} returns the path name (or URL) of the file found (for
  example \code{"100s.hea"} for \code{wfdbfile("hea", "100s")} without an
  input directory), or \code{NULL}
  if there is none; \code{wfdbfile(NULL, NULL)} returns the last file name
  tried.

  \code{wfdberror} returns the last error message (with its newline), or a
  message giving the library version if there has been no error.

  \code{wfdbx_set_input_dir} and \code{wfdbx_set_output_dir} return the
  previous directory (\code{NULL} if none), \code{wfdbx_get_input_dir}
  and \code{wfdbx_get_output_dir} the current one;
  \code{wfdbx_set_network} returns the previous setting (1 or 0),
  \code{wfdbx_get_network} the current one.

  \code{wfdb_me_fatal} returns the value last given to \code{wfdbmemerr}
  (initially 1).

  \code{wfdbversion} returns the version of the WFDB library implemented,
  \code{"10.7.0"}; \code{wfdbdefwfdb} and \code{wfdbdefwfdbcal} the
  default WFDB path and calibration file name.  \code{wfdbldflags} and
  \code{wfdbcflags}, which give compiler flags in C, return empty strings.

  The other functions return \code{NULL}, invisibly.
}
\seealso{
  \code{\link{isigopen}}, \code{\link{annopen}}, \code{\link{calopen}}.
}
\examples{
getwfdb()
wfdbversion()

old <- wfdbx_set_input_dir(tempdir())  # read relative names there
getwfdb()
wfdbfile("hea", "nonexistent")  # NULL: not found
wfdbx_set_input_dir(old)

\dontrun{
# PhysioNet (network access must be allowed explicitly)
wfdbx_set_network(1)
rec <- read_record("100", input_dir = "https://physionet.org/files/mitdb/1.0.0/",
                   sampto = 10)
}
}
