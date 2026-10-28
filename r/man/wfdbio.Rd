\name{getwfdb}
\alias{getwfdb}
\alias{setwfdb}
\alias{resetwfdb}
\alias{wfdbquiet}
\alias{wfdbverbose}
\alias{wfdberror}
\alias{wfdb_error}
\alias{wfdbfile}
\alias{wfdbmemerr}
\alias{wfdb_me_fatal}
\alias{wfdbversion}
\alias{wfdbldflags}
\alias{wfdbcflags}
\alias{wfdbdefwfdb}
\alias{wfdbdefwfdbcal}
\alias{wfdbx_write_errors}
\alias{wfdbx_note_write_error}
\alias{WFDB_READ}
\alias{WFDB_WRITE}
\alias{WFDB_AHA_READ}
\alias{WFDB_AHA_WRITE}
\alias{WFDB_APPEND}
\title{Finding Files, Error Messages and Library Information}
\description{
  WFDB-x finds the files of a record (headers, signal files, annotation
  files, calibration files) by explicit names: a relative name is read
  under the input directory and written under the output directory; an
  absolute name, a \code{~} name or a URL is used as given; nothing else
  is searched.  These functions set the input directory, find the file of a record,
  control the error messages of the library, and give version
  information.  \code{\link{wfdbx_set_input_dir}} and the related
  functions set the input and output directories and network access.  (In legacy mode,
  files are searched for in the WFDB path, as by the C library.)
}
\usage{
getwfdb()
setwfdb(p)
resetwfdb()
wfdbquiet()
wfdbverbose()
wfdberror()
wfdb_error(fmt, ...)
wfdbfile(s, record)
wfdbmemerr(behavior)
wfdb_me_fatal()
wfdbversion()
wfdbldflags()
wfdbcflags()
wfdbdefwfdb()
wfdbdefwfdbcal()
wfdbx_write_errors()
wfdbx_note_write_error()
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
  \item{behavior}{the behaviour on memory allocation errors.  It is only
    stored, to be returned by \code{wfdb_me_fatal}, since such errors are
    handled by R.}
  \item{fmt, ...}{\code{wfdb_error}: a C \code{printf} format and its
    arguments.}
}
\details{
  A name is resolved to exactly one location.  \code{"-"} is the standard input or output;
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

  The input directory, the output directory and network access are set
  with \code{\link{wfdbx_set_input_dir}}, \code{\link{wfdbx_set_output_dir}}
  and \code{\link{wfdbx_set_network}}, or with the environment variables
  \env{WFDBX_INPUT_DIR}, \env{WFDBX_OUTPUT_DIR} and \env{WFDBX_NETWORK}.
  With network access off, a URL is not opened, and the first attempt
  prints \samp{WFDB-x: network access is disabled; set WFDBX_NETWORK=1 or
  call wfdbx_set_network(1) to open URL}.

  \code{setwfdb} sets the input directory (see \code{p}); with more than
  one directory it reports \samp{setwfdb: WFDB-x reads from a single input
  directory; use wfdbx_set_input_dir (or legacy mode for the WFDB search
  path)} and changes nothing.  \code{getwfdb} returns the input directory,
  or \code{"."} if none is set; \code{resetwfdb} restores the value set
  by the last \code{setwfdb}.  The environment variable \env{WFDB} is not
  used: if it is set, the first lookup prints \samp{WFDB-x: the WFDB
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
  returns the last one.  \code{wfdb_error} reports a message as the
  library does: it is formatted as by C \code{printf}, saved for
  \code{wfdberror}, and printed on the standard error output unless
  \code{wfdbquiet} is in effect.

  \code{wfdbx_write_errors} counts the write errors since the program
  started: the output files (signal files, headers, annotation files,
  info and calibration files, and the standard output used as the file
  \code{"-"}) that could not be written, flushed or closed, found when the
  library closes them (as \code{\link{wfdbquit}} does), and the errors
  reported with \code{wfdbx_note_write_error}, which an application that
  writes a file itself calls.  Counting prints nothing; the library's own
  messages (such as \samp{osigclose: write error in signal group 0}) are
  printed as before.  \code{\link{write_record}} and
  \code{\link{write_annotations}} stop with an error when the count goes
  up, and the command-line tools then exit with status 1 (in normal
  mode).

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

  \code{wfdbx_write_errors} returns the number of write errors.

  \code{wfdb_me_fatal} returns the value last given to \code{wfdbmemerr}
  (initially 1).

  \code{wfdbversion} returns the version of the WFDB library implemented,
  \code{"10.7.0"}; \code{wfdbdefwfdb} and \code{wfdbdefwfdbcal} the
  default WFDB path and calibration file name.  \code{wfdbldflags} and
  \code{wfdbcflags}, which give compiler flags in C, return empty strings.

  The other functions return \code{NULL}, invisibly.
}
\section{Origin}{
  Translation of the C functions getwfdb(), setwfdb(), resetwfdb(),
  wfdbquiet(), wfdbverbose(), wfdberror(), wfdb_error(), wfdbfile(),
  wfdbmemerr(), wfdb_me_fatal(), wfdbversion(), wfdbldflags(),
  wfdbcflags(), wfdbdefwfdb() and wfdbdefwfdbcal() (lib/wfdbio.c, WFDB
  10.7.0), and of
  the file mode constants of lib/wfdb.h: same arguments and results.
  Differences: files are found by explicit names, under the input and
  output directories, not by a search of the WFDB path, URLs are opened
  only when network access is on, and \code{setwfdb} takes a single
  directory; see \file{docs/DIVERGENCES.md}.
  \code{wfdbx_write_errors} and \code{wfdbx_note_write_error}: part of
  WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{wfdbx_set_input_dir}}, \code{\link{isigopen}},
  \code{\link{annopen}}, \code{\link{calopen}}.
}
\examples{
getwfdb()
wfdbversion()

setwfdb(tempdir())              # read relative names there
getwfdb()
wfdbfile("hea", "nonexistent")  # NULL: not found
setwfdb("")                     # the default: the current directory

\dontrun{
# Record 100 of the MIT-BIH Arrhythmia Database, from PhysioNet (network
# access must be allowed explicitly)
wfdbx_set_network(1)
rec <- read_record("100", input_dir = "https://physionet.org/files/mitdb/1.0.0/",
                   sampto = 10)
}
}
