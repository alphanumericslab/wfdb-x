\name{read_metadata}
\alias{read_metadata}
\alias{get_metadata}
\alias{set_metadata}
\alias{remove_metadata}
\alias{update_metadata}
\title{Read and Change Header Metadata}
\description{
  Many datasets store facts about a recording in the header of the
  record, as comment lines of the form \samp{# Key: value}, such as
  \samp{# Age: 63} or \samp{# Dx: 164889003}.  \code{read_metadata}
  returns all these entries, \code{get_metadata} the value of one of
  them, \code{set_metadata} changes or adds an entry,
  \code{remove_metadata} removes one, and \code{update_metadata} makes
  several changes in one write.  The rest of the header is never changed.
}
\usage{
read_metadata(record, input_dir = NULL, network = NULL)

get_metadata(record, key, input_dir = NULL, network = NULL)

set_metadata(record, key, value, input_dir = NULL, network = NULL,
             dir = NULL)

remove_metadata(record, key, input_dir = NULL, network = NULL,
                dir = NULL)

update_metadata(record, changes, input_dir = NULL, network = NULL,
                dir = NULL)
}
\arguments{
  \item{record}{the record name, without the \code{.hea} extension (a
    trailing \code{".hea"} is also accepted): a full path, absolute
    (\code{"/data/mitdb/100"}) or in the home directory
    (\code{"~/Documents/100s"}), used as given; a relative path
    (\code{"100s"}, \code{"data/100s"}), read from the input directory if
    one is set (see \code{\link{wfdbx_set_input_dir}}), otherwise from the
    current directory; or a URL
    (\code{"https://physionet.org/files/mitdb/1.0.0/100"}), read only if
    network access is on.  It must not be empty, nor \code{"-"} (the
    standard input).  The header is changed where it was read, unless
    \code{dir} is given; a header read from a URL can only be written
    elsewhere, with \code{dir}.}
  \item{key}{the key, such as \code{"Age"} or \code{"Date of birth"}: a
    character string or a raw vector.  Letter case is ignored when keys
    are compared, and spaces at either end are removed.  It must not be
    empty, and must not contain \samp{:}, \samp{#}, a line break or a NUL
    byte.}
  \item{value}{the value: a character string, which may be a sentence, or
    a raw vector.  Spaces at either end are removed.  It must not contain
    a line break or a NUL byte; it may be empty.}
  \item{changes}{the changes, as a named list or a named character vector
    (\code{list(Age = "64", Dx = NULL)}, \code{c(Age = "64", Dx = NA)}):
    the names are the keys, and each element a value as for
    \code{set_metadata}, or \code{NULL} or \code{NA} to remove the entry,
    as \code{remove_metadata} does.  They are applied in order.  No two
    keys may differ only in letter case.}
\item{input_dir}{the input directory for reading the header, for
    this call only (optional): a
    local directory, a \code{~} path or a URL, under which relative record
    names are read.  It does not apply to full paths or URLs.
    \code{NULL}, the default, keeps the current setting (see
    \code{\link{wfdbx_set_input_dir}}).}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting.}
  \item{dir}{the directory, which must exist, in which to write the
    changed header, under the same file name, instead of changing the
    header itself (the signal files are not copied).  The header is then
    written even if nothing changes.  \code{NULL} or \code{""}, the
    default: the header itself is changed.}
}
\details{
  \strong{Reading.}  The info strings of a header are its comment lines
  after the record line, as \code{\link{getinfo}} reads them.  The record
  line is found as the header parser of the library finds it: the first
  line that, up to a NUL byte, holds something other than spaces, tabs,
  CRs and LFs and does not begin (after them) with \samp{#}, in every
  mode (the C function \code{getinfo}, as \code{getinfo} in legacy mode,
  takes the first line that does not begin with \samp{#}, which may be an
  empty or blank line).  An info
  string is an entry if the text after its \samp{#} contains a colon.  The
  key is the text before the first colon, and the value the rest of the
  line; spaces, tabs, VT, FF and CR are removed at both ends of each.  So
  \samp{#Age:45}, \samp{# Age: 45} and \samp{#  Age : 45} all give the
  entry \code{Age = "45"}.  An info string without a colon, or whose key
  is then empty or contains \samp{#}, is a free comment: it is never
  returned, and never changed.  Comment lines (and empty or blank lines)
  before the record line are never read or changed.  Only the header file (\file{.hea}) is read, not
  the \file{.info} file that \code{getinfo} also reads.

  \strong{Keys} are compared without regard to letter case (A-Z and a-z
  only; no other byte is changed).  A header should not hold two entries
  whose keys differ only in letter case.  If one does (a file written by
  other software), \code{read_metadata} and \code{get_metadata} return
  the first of them, with a warning; \code{set_metadata} and
  \code{update_metadata} refuse to change that key, and
  \code{remove_metadata} removes all of them.

  \strong{Text} is handled as bytes, as in the rest of the package: a
  character string is taken as its bytes (\code{charToRaw}), never
  re-encoded, and a raw vector is taken as given.  The entries returned
  are character strings of the bytes of the header.

  \strong{Writing.}  An entry is written as \samp{# Key: value} (one
  space after \samp{#} and one after the colon; \samp{# Key:} if the
  value is empty), with the spelling of the key given.  A changed entry
  replaces its line, at the same position, keeping its line ending, even
  if the value is the same.  A new entry is inserted after the last info
  string, or, if the header has none, after its last line that is not
  blank; it ends as the record line does (CR LF in the headers written by
  WFDB).  Every other byte of the header is kept.  All the arguments are
  checked before the header is read, and every change before anything is
  written.  If nothing changes (and \code{dir} is not given), nothing is
  written.  The new header is written to a temporary file in the
  directory of the destination, created with owner-only permissions
  (0600) before anything is written to it (a header may hold patient
  data, never readable meanwhile by other users), which is then given the
  permissions of the destination (or, for a new file, 0666 less the
  umask) and replaces it (rename); the temporary file is removed on any
  failure.  So an error leaves the header unchanged.

  \strong{Which file.}  The header is opened as the library opens the
  header of a record (\code{wfdb_open} with type \code{"hea"}), as
  \code{\link{read_header}} does.  A change is written to the file that
  was read, or, with \code{dir}, to the file of the same name in
  \code{dir}, leaving the original unchanged; the output directory
  (\code{\link{wfdbx_set_output_dir}}) is not used.  Only the named header
  is read or changed: for a multi-segment record, that is the master
  header, unless the name of a segment is given.

  \code{\link{read_header}} also returns the entries (its element
  \code{metadata}), and \code{\link{write_record}} writes them (its
  argument \code{metadata}).

  Metadata often holds information about patients.  WFDB-x stores it as
  plain text, exactly as given, and does not de-identify it.
}
\value{
  \code{read_metadata} returns the entries as a named character vector,
  in file order: the names are the keys and the elements the values, with
  the spelling of the file.  A key that appears more than once (ignoring
  letter case) is returned once, with its first value.  A header without
  entries gives an empty named character vector.  This is the form that
  \code{update_metadata} and the \code{metadata} argument of
  \code{\link{write_record}} take.

  \code{get_metadata} returns the value (a character string; \code{""}
  for an entry with an empty value), or \code{NULL} if the header has no
  entry for \code{key}.

  \code{remove_metadata} returns the number of lines removed (0 if the
  header has no entry for \code{key}).

  \code{set_metadata} and \code{update_metadata} return \code{NULL},
  invisibly.
}
\section{Errors and warnings}{
  \itemize{
    \item An invalid argument stops with an error of class
      \code{"wfdbx_argument_error"}: an empty record name or \code{"-"},
      an invalid key or value (such as \samp{metadata key 'a:b' must not
      contain ':'}), a value that is not a string, \code{changes} that are
      not a named list or named character vector, or two keys of
      \code{changes} that differ only in letter case.  So does a change
      that the header does not allow: setting a key of which the header
      has more than one entry (\samp{header of record REC has more than
      one entry for key KEY (lines L1, L2); remove them first}), changing
      a header without a record line, or a header read from a URL
      without \code{dir}.
    \item A header that cannot be found or read (\samp{can't read header
      for record REC}) or written (\samp{can't write header for record
      REC}), and a \code{dir} that does not exist (\samp{directory DIR
      does not exist}), stop with an error of class
      \code{"wfdbx_file_error"}.
    \item Both classes are also of class \code{"error"}.
    \item A key that appears more than once gives the warning
      \samp{header of record REC has more than one entry for key KEY
      (lines L1, L2); the first is used}, one for each such key.
  }
}
\section{Origin}{
  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_header}} and \code{\link{write_record}};
  \code{\link{getinfo}} and \code{\link{putinfo}} for the info strings.
}
\examples{
old <- setwd(tempdir())

## Write a record, "meta", with two entries (a record written by this
## example).
write_record("meta", matrix(0, 10, 1), fs = 100, gains = 200, adcres = 12,
             units = "mV", metadata = list(Age = "63", Sex = "F"))

read_metadata("meta")                     # c(Age = "63", Sex = "F")
get_metadata("meta", "age")               # "63"
set_metadata("meta", "Age", "64")         # writes "# Age: 64"
remove_metadata("meta", "Sex")            # 1
update_metadata("meta", list(Dx = "164889003", Age = NULL))
read_metadata("meta")                     # c(Dx = "164889003")

setwd(old)
}
