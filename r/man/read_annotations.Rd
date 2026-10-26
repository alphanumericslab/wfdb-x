\name{read_annotations}
\alias{read_annotations}
\alias{write_annotations}
\title{Read and Write Annotation Files}
\description{
  \code{read_annotations} reads a WFDB annotation file (such as the beat
  labels \file{100s.atr} of record \code{100s}) into a data frame, with one
  row per annotation.  \code{write_annotations} writes an annotation file
  from vectors or from such a data frame.  They read and write what the
  \command{rdann} and \command{wrann} tools do.
}
\usage{
read_annotations(record, annotator, sampfrom = 0, sampto = NULL, fs = NULL,
                 input_dir = NULL, network = NULL, legacy = FALSE)

write_annotations(record, annotator, sample, symbol = NULL, code = NULL,
                  subtype = 0, chan = 0, num = 0, aux = NULL, fs = NULL,
                  dir = NULL, legacy = FALSE)
}
\arguments{
  \item{record}{the record name, a character string (for example
    \code{"100s"}): relative to the input directory, or a full path, a
    \code{~} path or a URL (see \code{\link{getwfdb}}).}
  \item{annotator}{the annotator name, which is the extension of the
    annotation file (for example \code{"atr"} for \file{100s.atr}).}
  \item{sampfrom, sampto}{read only the annotations at or after
    \code{sampfrom} and before \code{sampto}: sample numbers, or time
    strings as accepted by \code{\link{strtim}} (such as \code{"0:10"} for
    10 seconds).  By default the whole file is read.  A time string that
    needs the sampling frequency (see \code{\link{wfdbx_time_needs_freq}})
    is an error if the sampling frequency is not known (see \code{fs}).}
  \item{sample}{the times of the annotations (sample numbers), or a data
    frame as returned by \code{read_annotations}, whose columns then give
    all the fields of the annotations (arguments given explicitly take
    precedence).}
  \item{symbol}{the annotation types as mnemonics, such as \code{"N"}
    (normal beat) or \code{"V"} (premature ventricular contraction); see
    \code{\link{annstr}}.}
  \item{code}{alternatively, the annotation types as numeric codes, such
    as \code{NORMAL} or \code{PVC} (see \code{\link{ecgcodes}}).}
  \item{subtype, chan, num}{the subtype, signal number and \code{num}
    fields of the annotations (small integers, each stored in one byte;
    recycled to the number of annotations).}
  \item{aux}{the auxiliary text of the annotations (for example a rhythm
    label such as \code{"(AFIB"}): a character vector, with \code{NA} for
    annotations without auxiliary text, or \code{NULL} for none.  Texts
    longer than 255 bytes are truncated.}
  \item{fs}{\code{read_annotations}: the sampling frequency of the record
    (> 0), used, like the \option{-F} option of \command{rdann}, only if
    the record has no header or its header does not specify one; there is
    no default.  \code{write_annotations}: if given, the time resolution of
    the annotation times (ticks per second), recorded in the file; by
    default the times are in samples of the record.}
  \item{dir}{\code{write_annotations}: if given, the directory (which must
    exist) in which the file is created (\code{record} must not contain a
    directory; wfdb-x).  The library's output directory
    (\code{\link{wfdbx_set_output_dir}}) is set for the duration of the
    call and restored afterwards, also on errors.}
  \item{input_dir}{the input directory for this call (a local directory, a
    \code{~} name or a URL; see \code{\link{wfdbx_set_input_dir}}), or
    \code{NULL} (the default) for the current setting.  The previous value
    is restored afterwards, also on errors (wfdb-x).}
  \item{network}{\code{TRUE} to allow reading URLs for this call,
    \code{FALSE} to forbid it (see \code{\link{wfdbx_set_network}}), or
    \code{NULL} (the default) for the current setting (by default, not
    allowed).  The previous value is restored afterwards (wfdb-x).}
  \item{legacy}{if \code{TRUE}, behave as the original package did, with
    the library's legacy mode (\code{\link{wfdbx_set_legacy}}) on for the
    duration of the call (the previous setting is restored afterwards,
    also on errors): \code{read_annotations} then assumes 250 Hz for a
    record without a header or whose header does not specify the sampling
    frequency, unless \code{fs} is given.  Kept for compatibility only:
    the values it assumes are exactly the silent defaults this project
    removed, so results produced with it carry the same risks.  With
    \code{FALSE} (the default), the current setting of the library
    applies.}
}
\details{
  The annotation file is \file{\var{record}.\var{annotator}}.  When
  reading, it is read under the input directory, unless the record name is
  a full path, a \code{~} path or a URL (see \code{\link{getwfdb}}), and the header of the record, if found, gives the
  sampling frequency used to interpret time strings; when writing, it is
  created in the current directory.

  wfdb-x never assumes a sampling frequency (the C tools assumed 250 Hz
  for a record without a header; see \file{docs/DIVERGENCES.md} in the
  wfdb-x sources): if neither the header nor \code{fs} gives one, the
  \code{fs} attribute of the result is that of the annotation file (0 if it
  does not specify one), and time strings that need the frequency are an
  error.

  Either \code{symbol} or \code{code} must be given, unless \code{sample}
  is a data frame (if both are given, \code{code} is used).  Annotations
  may be given in any order: if they are not in time order, the file is
  sorted when it is closed, exactly as the \command{sortann} tool does
  (unless the environment variable \env{WFDBANNSORT} is \code{0}); wfdb-x:
  in the same R process, whereas the C library, as legacy mode, runs the
  \command{sortann} tool.

  Annotation files may begin with \dQuote{modification labels}, which
  define non-standard mnemonics or the time resolution of the file.  They
  are applied when the file is read and are not returned as annotations
  (see \code{\link{annopen}}).

  Each call closes any record or annotation file opened with the library
  functions (as \code{\link{wfdbquit}} does), and leaves none open.
}
\value{
  \code{read_annotations} returns a data frame with one row per annotation
  and the columns
  \item{sample}{the time of the annotation (a sample number, or a number
    of ticks of the time resolution of the file).}
  \item{symbol}{the mnemonic of the annotation type (character).}
  \item{code}{the numeric annotation type code.}
  \item{subtype, chan, num}{the other numeric fields.}
  \item{aux}{the auxiliary text (character), \code{NA} where there is
    none.}
  The data frame also has the attributes \code{record}, \code{annotator}
  and \code{fs} (the time resolution of the \code{sample} column, in ticks
  per second; usually the sampling frequency of the record, 0 if it is not
  known).

  \code{write_annotations} returns, invisibly, the status of the last
  annotation written: 0 on success, or a negative value (as returned by
  \code{\link{putann}}) on a write error.

  Both functions signal an error (with \code{stop}) if the file cannot be
  opened.
}
\seealso{
  \code{\link{read_record}} for signals; \code{\link{annopen}} and
  \code{\link{getann}} for reading annotations one at a time;
  \code{\link{annstr}} and \code{\link{ecgcodes}} for annotation types.
}
\examples{
old <- setwd(tempdir())
write_record("example", cbind(0:999), fs = 250, gains = 200, adcres = 16, units = "mV")

## write three beat annotations and a rhythm change
write_annotations("example", "tst", c(100, 350, 600, 600),
                  symbol = c("N", "V", "N", "+"),
                  aux = c(NA, NA, NA, "(N"))
a <- read_annotations("example", "tst")
a
table(a$symbol)
attr(a, "fs")

## annotations in the first two seconds only
read_annotations("example", "tst", sampto = "0:2")

## copy the file, keeping only the beats
beats <- a[a$symbol \%in\% c("N", "V"), ]
write_annotations("example", "cpy", beats)
read_annotations("example", "cpy")$symbol

setwd(old)
}
