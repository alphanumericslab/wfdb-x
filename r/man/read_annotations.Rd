\name{read_annotations}
\alias{read_annotations}
\alias{write_annotations}
\title{Read and Write Annotation Files}
\description{
  \code{read_annotations} reads an annotation file, such as the beat
  labels \file{100s.atr} of record \code{100s} (the sample record included
  with WFDB-x: the first minute of record 100 of the MIT-BIH Arrhythmia
  Database), into a data frame with one
  row per annotation.  \code{write_annotations} writes an annotation file
  from vectors or from such a data frame.
}
\usage{
read_annotations(record, annotator, sampfrom = 0, sampto = NULL, fs = NULL,
                 input_dir = NULL, network = NULL, legacy = FALSE)

write_annotations(record, annotator, sample, symbol = NULL, code = NULL,
                  subtype = 0, chan = 0, num = 0, aux = NULL, fs = NULL,
                  dir = NULL, legacy = FALSE, sort = NULL)
}
\arguments{
  \item{record}{\code{read_annotations}: the record name, without the \code{.hea} extension (a
    trailing \code{".hea"} is also accepted): a full path, absolute
    (\code{"/data/mitdb/100"}) or in the home directory
    (\code{"~/Documents/100s"}), used as given; a relative path
    (\code{"100s"}, \code{"data/100s"}), read from the input directory if
    one is set (see \code{\link{wfdbx_set_input_dir}}), otherwise from the
    current directory; or a URL
    (\code{"https://physionet.org/files/mitdb/1.0.0/100"}), read only if
    network access is on.  Its header, if there is
    one, gives the sampling frequency.

    \code{write_annotations}: the record name, without the \code{.hea}
    extension (a trailing \code{".hea"} is also accepted): a plain name or
    a relative path (\code{"data/100s"}) is created in the output
    directory if one is set (see \code{\link{wfdbx_set_output_dir}}),
    otherwise in the current directory; a full path, absolute or in the
    home directory (\code{"~/Documents/100s"}), is used as given.  The
    file is \file{RECORD.ANNOTATOR} at that place
    (\file{data/100s.qrs}).  A URL cannot be written.}
  \item{annotator}{the annotator name, which is the suffix of the file:
    \code{"atr"} is \file{100s.atr}.}
  \item{sampfrom, sampto}{read only the annotations at or after
    \code{sampfrom} and before \code{sampto}.  Each is a sample number or
    a time string, such as \code{"0:10"} (10 seconds); see
    \code{\link{strtim}}.  By default the whole file is read.  They are
    checked as \code{\link{read_record}} checks them, before any file is
    opened: a sample number must be a whole number (\samp{sampfrom must
    be a whole number} for a fraction, \code{NA}, \code{NaN} or an
    infinite value), within the range of a 64-bit integer (\samp{sampfrom
    is beyond the range of a 64-bit integer}), and \code{sampfrom} must
    not be negative (\samp{sampfrom must not be negative}); anything other
    than one number or one time string is \samp{sampfrom must be a sample
    number or a time string} (the same for \code{sampto}, which may be
    negative).}
  \item{fs}{\code{read_annotations}: the sampling frequency to use when
    the record has no header, or its header gives none.
    \code{write_annotations}: the frequency in which \code{sample} is
    counted (finite, greater than 0), recorded in the file.  By default the times are samples of
    the record.}
  \item{input_dir}{the input directory for this call only (optional): a
    local directory, a \code{~} path or a URL, under which relative record
    names are read.  It does not apply to full paths or URLs.
    \code{NULL}, the default, keeps the current setting (see
    \code{\link{wfdbx_set_input_dir}}).}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting.}
  \item{legacy}{if \code{TRUE}, behave as the original WFDB package for
    this call (see \code{\link{wfdbx_set_legacy}}).}
  \item{sample}{the times of the annotations, in samples (a vector):
    integers from \eqn{-2^{63}+1}{-2^63 + 1} to \eqn{2^{63}-2}{2^63 - 2}
    (\code{NA}, \code{NaN}, infinite values and fractions are errors;
    the smallest and largest 64-bit integers are reserved by the file
    format: \samp{annotation time T cannot be written (annotation times
    must be integers from -9223372036854775807 to 9223372036854775806)}).  It can also be
    a data frame returned by \code{read_annotations}: its columns then
    give all the fields, and the arguments given explicitly take
    precedence.}
  \item{symbol}{the annotation types as mnemonics, such as \code{"N"}
    (normal beat) or \code{"V"} (premature ventricular contraction); see
    \code{\link{annstr}}.}
  \item{code}{the annotation types as codes, such as \code{NORMAL} or
    \code{PVC} (see \code{\link{ecgcodes}}): 0 to 58.  Codes 59 to 63
    are the control codes of the file format (\samp{annotation code C is
    reserved (59 to 63 are the control codes of the annotation file
    format)}), and other values do not fit (\samp{annotation code C is
    out of range (0 to 58)}).  \code{symbol} or \code{code} must be
    given for one annotation or more (\samp{symbol or code must be
    given}; with no annotations, an empty file is written).  Both may be given, as \code{read_annotations} returns
    them, only if they agree: each symbol must be the mnemonic of its
    code (an empty symbol agrees with any code); otherwise
    \code{write_annotations} stops with \samp{symbols and codes disagree
    at annotation K} (K counting from 0).}
  \item{subtype, chan, num}{the subtype, channel and annotator number of
    each annotation: small integers.  As in C, subtypes and annotator
    numbers are stored as signed bytes and channels as unsigned bytes
    (other values wrap around).  \code{NA}, \code{NaN} and infinite
    values are errors, in \code{code} too.}
  \item{aux}{the auxiliary text of each annotation, such as a rhythm label
    \code{"(AFIB"}: a character vector with \code{NA} where there is none,
    or \code{NULL}.  Texts longer than 255 bytes are truncated.  Text is
    written as its bytes, one byte per character (Latin-1): a string of
    an R session in UTF-8 that holds a character beyond U+00FF is an
    error (\samp{aux text 'X' has a character that is not Latin-1 (one
    byte per character)}).

    \code{symbol}, \code{code}, \code{subtype}, \code{chan}, \code{num}
    and \code{aux} each give one value for all annotations, or one value
    per annotation; any other length is an error, raised before the file
    is created.  \code{sample} and these arguments (except \code{aux})
    must be vectors: a matrix is an error (\samp{samples must be a 1-D
    array}, \samp{code must be a 1-D array}, ...).}
  \item{dir}{the directory (which must exist) in which to create the
    file, for this call only.  \code{record} must then be a plain name,
    without a directory: the file is \file{DIR/RECORD.ANNOTATOR}.}
  \item{sort}{\code{TRUE} to sort the annotations by time, \code{FALSE}
    to keep the given order, for this call only.  \code{NULL}, the
    default, lets the \env{WFDBANNSORT} environment variable decide.}
}
\details{
  If the annotations are not in time order, \code{write_annotations}
  sorts the file when it is written, unless \env{WFDBANNSORT} is
  \code{0}.  The \code{sort} argument overrides \env{WFDBANNSORT} for one
  call.

  An existing file is replaced: \code{write_annotations} writes the new
  file to a temporary file (\file{.\var{name}.\var{XXXXXXXX}.tmp},
  created with owner-only permissions) in the same directory, sorts it
  there if needed, and renames it over the existing file (with its
  permissions; 0666 less the umask for a new file) only when it is
  complete, so that an error leaves the existing file as it was and no
  temporary file is left.  (In legacy mode, a file to be sorted is renamed
  first, and then sorted by the \command{sortann} program, as the C library
  does.)

  A time string such as \code{"0:10"} needs the sampling frequency.  It
  comes from the header of the record, or from \code{fs}.

  Each call closes anything opened with the WFDB library functions, as
  \code{\link{wfdbquit}} does.  The getvec mode
  (\code{\link{getgvmode}}) and the time resolution of output annotators
  (\code{\link{getafreq}}) are left as they were, also after an error
  (opening an EDF record sets both, as in C); the \code{fs} of
  \code{write_annotations} applies to its file only.
}
\value{
  \code{read_annotations} returns a data frame with one row per
  annotation, in file order, and these columns:
  \item{sample}{the time of the annotation, in samples.}
  \item{symbol}{the mnemonic of the annotation type.}
  \item{code}{the annotation type code.}
  \item{subtype, chan, num}{the subtype, channel and annotator number.}
  \item{aux}{the auxiliary text, or \code{NA}.}
  The data frame also has the attributes \code{record}, \code{annotator}
  and \code{fs}: the frequency in which \code{sample} is counted, 0 if it
  is not known.

  \code{write_annotations} returns, invisibly, 0 on success, or a
  negative value if an annotation could not be written.
}
\section{Errors}{
  Both functions stop with an error if the file cannot be opened, such as
  \samp{can't read annotator ANN for record REC}.  \code{read_annotations}
  also stops with an error if the file ends unexpectedly or cannot be
  read, such as \samp{can't read annotation file ANN of record REC (getann
  status -3)}, unless an annotation at or after \code{sampto} was read
  first (reading stops there).  \code{write_annotations} stops with the
  error \samp{can't create annotator ANN for record REC} if the file cannot
  be created, and \samp{write error on annotator ANN for record REC},
  after the message of the library (\samp{oannclose: write error on
  annotation file ANN}), if it cannot be written completely (for example,
  when the disk is full) or the library reports an error while writing
  it.  Invalid arguments, and
  a time string when the sampling frequency is not known, also stop with
  an error.  \code{write_annotations} checks its arguments before it
  creates or changes the file, in this order (WFDB-x 1.2.2): the
  dimensions of \code{sample}, then of each per-annotation argument, and
  their lengths; the times and the other numbers; the reserved times;
  the codes (0 to 58); the agreement of \code{symbol} and \code{code};
  the aux texts; \code{fs}.  Whatever happens, both functions close the
  annotation file (\code{\link{wfdbquit}}) before they return.
}
\section{Origin}{
  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_record}} for signals; \code{\link{annstr}} and
  \code{\link{ecgcodes}} for annotation types; \code{\link{annopen}} and
  \code{\link{getann}} for the WFDB library functions.
}
\examples{
old <- setwd(tempdir())
## "example" is a record written by this example.
write_record("example", cbind(0:999), fs = 250, gains = 200, adcres = 16, units = "mV")

## Write three beat annotations and a rhythm change.
write_annotations("example", "tst", c(100, 350, 600, 600),
                  symbol = c("N", "V", "N", "+"),
                  aux = c(NA, NA, NA, "(N"))
a <- read_annotations("example", "tst")
a
table(a$symbol)
attr(a, "fs")

## Read the annotations of the first two seconds only.
read_annotations("example", "tst", sampto = "0:2")

## Copy the file, keeping only the beats.
beats <- a[a$symbol \%in\% c("N", "V"), ]
write_annotations("example", "cpy", beats)
read_annotations("example", "cpy")$symbol

setwd(old)
}
