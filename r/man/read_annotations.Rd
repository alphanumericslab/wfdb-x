\name{read_annotations}
\alias{read_annotations}
\alias{write_annotations}
\title{Read and Write Annotation Files}
\description{
  \code{read_annotations} reads an annotation file, such as the beat
  labels \file{100s.atr} of record \code{100s} (the sample record included
  with wfdb-x: the first minute of record 100 of the MIT-BIH Arrhythmia
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
  \item{record}{the record name, such as \code{"100s"}.  A full path, a
    \code{~} path or a URL is used as given.  Any other name is read from
    the input directory and written to the output directory (see
    \code{\link{wfdbx_set_input_dir}}).}
  \item{annotator}{the annotator name, which is the suffix of the file:
    \code{"atr"} is \file{100s.atr}.}
  \item{sampfrom, sampto}{read only the annotations at or after
    \code{sampfrom} and before \code{sampto}.  Each is a sample number or
    a time string, such as \code{"0:10"} (10 seconds); see
    \code{\link{strtim}}.  By default the whole file is read.}
  \item{fs}{\code{read_annotations}: the sampling frequency to use when
    the record has no header, or its header gives none.
    \code{write_annotations}: the frequency in which \code{sample} is
    counted, recorded in the file.  By default the times are samples of
    the record.}
  \item{input_dir}{the input directory for this call only: a local
    directory, a \code{~} path or a URL.  \code{NULL}, the default, keeps
    the current setting.}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting.}
  \item{legacy}{if \code{TRUE}, behave as the original WFDB package for
    this call (see \code{\link{wfdbx_set_legacy}}).}
  \item{sample}{the times of the annotations, in samples.  It can also be
    a data frame returned by \code{read_annotations}: its columns then
    give all the fields, and the arguments you give explicitly take
    precedence.}
  \item{symbol}{the annotation types as mnemonics, such as \code{"N"}
    (normal beat) or \code{"V"} (premature ventricular contraction); see
    \code{\link{annstr}}.}
  \item{code}{the annotation types as codes, such as \code{NORMAL} or
    \code{PVC} (see \code{\link{ecgcodes}}).  Give \code{symbol} or
    \code{code}.}
  \item{subtype, chan, num}{the subtype, channel and annotator number of
    each annotation: small integers, recycled to the number of
    annotations.}
  \item{aux}{the auxiliary text of each annotation, such as a rhythm label
    \code{"(AFIB"}: a character vector with \code{NA} where there is none,
    or \code{NULL}.  Texts longer than 255 bytes are truncated.}
  \item{dir}{the directory, which must exist, in which to create the file.
    \code{record} must not contain a directory when \code{dir} is
    given.}
  \item{sort}{\code{TRUE} to sort the annotations by time, \code{FALSE}
    to keep the order you gave, for this call only.  \code{NULL}, the
    default, lets the \env{WFDBANNSORT} environment variable decide.}
}
\details{
  If the annotations are not in time order, \code{write_annotations}
  sorts the file when it is written, unless \env{WFDBANNSORT} is
  \code{0}.  The \code{sort} argument overrides \env{WFDBANNSORT} for one
  call.

  A time string such as \code{"0:10"} needs the sampling frequency.  It
  comes from the header of the record, or from \code{fs}.

  Each call closes anything opened with the WFDB library functions, as
  \code{\link{wfdbquit}} does.
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
  when the disk is full).  Invalid arguments, and
  a time string when the sampling frequency is not known, also stop with
  an error.
}
\section{Origin}{
  Part of wfdb-x; not in the original WFDB package.
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
