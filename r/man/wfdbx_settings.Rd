\name{wfdbx_set_input_dir}
\alias{wfdbx_set_input_dir}
\alias{wfdbx_get_input_dir}
\alias{wfdbx_set_output_dir}
\alias{wfdbx_get_output_dir}
\alias{wfdbx_set_network}
\alias{wfdbx_get_network}
\alias{wfdbx_input_path}
\alias{wfdbx_output_path}
\title{Input Directory, Output Directory and Network Access}
\description{
  These functions set and return where records are read and written, and
  whether URLs may be opened.  They apply to the high-level functions, the
  command-line tools run with \code{\link{wfdbx_tool}}, and the WFDB
  library functions.  \code{wfdbx_input_path} and \code{wfdbx_output_path}
  give the path where a program opens a file that it reads or creates
  itself, rather than through the library.
}
\usage{
wfdbx_set_input_dir(dir)
wfdbx_get_input_dir()
wfdbx_set_output_dir(dir)
wfdbx_get_output_dir()
wfdbx_set_network(on)
wfdbx_get_network()
wfdbx_input_path(name)
wfdbx_output_path(name)
}
\arguments{
  \item{dir}{\code{wfdbx_set_input_dir}: the input directory, a local
    directory, a \code{~} path or the URL of a directory.
    \code{wfdbx_set_output_dir}: the output directory, a local directory.
    \code{NULL} or \code{""} restores the default.}
  \item{on}{\code{TRUE} or 1 to allow network access, \code{FALSE} or 0
    to forbid it.  \code{NULL} or a negative number restores the
    default.}
  \item{name}{\code{wfdbx_input_path}, \code{wfdbx_output_path}: a file
    name.  \code{""} and \code{"-"} (the standard input or output, if the
    program treats it so) are returned as given.}
}
\details{
  WFDB-x reads and writes files exactly where they are named.  A full path,
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
  \samp{https://physionet.org/files/<database>/<version>/}.  A remote file
  that has been read is kept for the rest of the R session; one that could
  not be read is requested again the next time it is opened.  A download
  gives up when it cannot connect, or receives nothing, for 30 seconds.
  Only \samp{http://} and \samp{https://} URLs can be read: a name that
  begins with another URL scheme, such as \samp{ftp://} or
  \samp{sftp://}, is refused, with or without network access, and never
  read as a local file name (mount the server as a local folder, e.g. with
  sshfs or rclone, or download the files).  When
  network access is off, opening a URL fails with a message that says how
  to turn it on.

  \code{wfdbx_input_path(name)} gives the path where a file that a
  program reads itself is found: where \code{wfdb_open} finds a file of
  that name (with an empty file type).  In normal mode, a relative name is
  read under the input directory, if one is set, a \code{~} name is
  expanded, and an absolute name is used as given; in legacy mode, the
  name is used as given.  \code{wfdbx_output_path(name)} gives the path
  where a file that a program writes itself is created: in normal mode, a
  relative name under the output directory, if one is set, a \code{~} name
  expanded, and an absolute name as given; in legacy mode, any name under
  the output directory, if one is set, used as a plain prefix.  When the
  output directory has been prefixed to the name, the directories missing
  in the resulting path are created, as for the output files of the
  library.  The command-line tools use them for the files they read or
  create themselves: the \option{-i} file of \code{wrsamp},
  \code{edf2mit}, \code{wav2mit}, \code{a2m} and \code{ad2m}, the input
  files of \code{ahaecg2mit} and the \option{-S} script of \code{xform}
  are read from the input directory; the WAV file of \code{mit2wav}, the
  EDF file of \code{mit2edf}, the master header of \code{snip -m} and the
  \file{.des}, \file{.ecg}, \file{.key} and \file{.txt} files of
  \code{parsescp} are created in the output directory.  Such a file
  cannot be read from a URL.
}
\value{
  The \code{set} functions return the previous setting, invisibly, and the
  \code{get} functions the current one.  A directory is a character
  string, or \code{NULL} for the current directory.  The network setting
  is 1 (allowed) or 0 (forbidden).

  \code{wfdbx_input_path} and \code{wfdbx_output_path} return the path
  to open (a character string), or \code{NULL} if \code{name} is
  \code{NULL} or a URL, or (\code{wfdbx_input_path}) becomes one when the
  input directory is prefixed to it (in normal mode, any name that begins
  with a URL scheme, such as \samp{ftp://}): such a file cannot be opened
  in this way.

  \code{wfdbx_set_output_dir} does not accept a URL (any name that begins
  with a URL scheme, such as \samp{https://} or \samp{ftp://}): it prints an error
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

old <- wfdbx_set_output_dir(file.path(tempdir(), "out"))
p <- wfdbx_output_path("notes.txt")    # .../out/notes.txt (out is created)
writeLines("checked", p)
wfdbx_set_output_dir(old)

\dontrun{
## Read 10 seconds of record 100 of the MIT-BIH Arrhythmia Database.
wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
wfdbx_set_network(1)
rec <- read_record("100", sampto = "0:10")
}
}
