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
\alias{WFDB_READ}
\alias{WFDB_WRITE}
\alias{WFDB_AHA_READ}
\alias{WFDB_AHA_WRITE}
\alias{WFDB_APPEND}
\title{WFDB Path, Error Messages and Library Information}
\description{
  The WFDB path is the list of directories in which the WFDB library
  looks for the files of a record (headers, signal files, annotation
  files, calibration files).  These functions get and set it, find the
  file of a record, control the error messages of the library, and give
  version information.
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
wfdbx_set_output_dir(dir)
wfdbx_get_output_dir()
}
\arguments{
  \item{p}{the new WFDB path: a character string of directory names
    separated by spaces, tabs, newlines or semicolons (or colons, as long
    as they are not part of a URL).  In a directory name, \code{"\%r"}
    stands for the record name.  A string \code{"@file"} reads the path
    from \code{file}.  \code{NULL} uses the environment variable
    \env{WFDB}, or the default path if it is not set.}
  \item{s}{a file type (the extension of the file, such as \code{"hea"}
    or \code{"atr"}), or a file name if \code{record} is \code{NULL}.}
  \item{record}{a record name, or \code{NULL}.}
  \item{dir}{the directory in which output files are created, or
    \code{NULL} or \code{""} for none.}
  \item{behavior}{the behaviour on memory allocation errors.  It is only
    stored, to be returned by \code{wfdb_me_fatal}, since such errors are
    handled by R.}
}
\details{
  The initial WFDB path is the value of the environment variable
  \env{WFDB} or, if it is not set, the default path
  \code{wfdbdefwfdb()}, which begins with the current directory
  (\code{"."}).  \code{setwfdb} changes it, and
  also sets the environment variable \env{WFDB} (so that tools run in
  other processes use the same path), and sets \env{WFDBCAL},
  \env{WFDBANNSORT} and \env{WFDBGVMODE} to their defaults if they are
  not set.  \code{resetwfdb} restores the path in effect when the library
  first used it.  As in C, \code{\link{wfdbquit}} calls \code{resetwfdb},
  which restores only the string returned by \code{getwfdb}: files are
  still searched for in the directories given to the last \code{setwfdb}
  call, including by \code{\link{read_record}} and the other high-level
  functions (which call \code{wfdbquit}).

  Remote directories (\samp{http://} URLs) are not supported and are
  skipped.  As in C, file names containing \samp{..} are refused.

  wfdb-x: a record (or file) named by an absolute path, such as
  \code{"/data/mitdb/100"}, is opened directly, and its directory is added
  to the WFDB path, so that the other files of the record are found next
  to its header; if it cannot be opened, the WFDB path is searched as in
  C.  The C library (and legacy mode, see \code{\link{wfdbx_set_legacy}})
  searched for it in each directory of the WFDB path, so that it was found
  only if the path had an empty component: \code{setwfdb(";")} (names are
  then used as given) works in both modes.

  wfdb-x: \code{wfdbx_set_output_dir} sets a directory in which the
  library creates its output files (headers, signal and annotation files):
  a file that would be created as \file{name} is created as
  \file{dir/name} (a missing directory is created).  The names recorded in
  the files are unchanged.  It is not reset by \code{wfdbquit}; the
  \code{dir} argument of \code{\link{write_record}} and
  \code{\link{write_annotations}} sets it for the duration of the call.

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
  \code{getwfdb} returns the WFDB path (a character string).

  \code{wfdbfile} returns the path name of the file found (for example
  \code{"./100s.hea"} for \code{wfdbfile("hea", "100s")}), or \code{NULL}
  if there is none; \code{wfdbfile(NULL, NULL)} returns the last file name
  tried.

  \code{wfdberror} returns the last error message (with its newline), or a
  message giving the library version if there has been no error.

  \code{wfdbx_set_output_dir} returns the previous output directory
  (\code{NULL} if none), \code{wfdbx_get_output_dir} the current one.

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

old <- getwfdb()
setwfdb(paste(tempdir(), "."))  # look in a temporary directory first
getwfdb()
wfdbfile("hea", "nonexistent")  # NULL: not found
setwfdb(old)
}
