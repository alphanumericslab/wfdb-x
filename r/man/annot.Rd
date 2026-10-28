\name{annopen}
\alias{annopen}
\alias{getann}
\alias{ungetann}
\alias{putann}
\alias{iannsettime}
\alias{iannclose}
\alias{oannclose}
\alias{setafreq}
\alias{getafreq}
\alias{setiafreq}
\alias{getiafreq}
\alias{getiaorigfreq}
\alias{aux_string}
\title{Reading and Writing Annotations (WFDB Library)}
\description{
  The annotation functions of the WFDB library: open annotation files
  (\dQuote{annotators}) for reading or writing, read and write
  annotations one at a time, and set the time resolution of annotation
  files.  They have the names and the behaviour of the functions of the C
  library.  To read or write a whole annotation file at once, see
  \code{\link{read_annotations}}.
}
\usage{
annopen(record, aiarray, nann = NULL)
getann(an)
ungetann(an, annot)
putann(an, annot)
iannsettime(t)
iannclose(n)
oannclose(n)
setafreq(f)
getafreq()
setiafreq(n, f)
getiafreq(n)
getiaorigfreq(n)
aux_string(aux)
}
\arguments{
  \item{record}{a record name.  A leading \code{"+"} keeps the
    annotators already open; otherwise they are closed first.}
  \item{aiarray}{an \code{\link{anninfo}} list (annotator name and mode:
    \code{WFDB_READ}, \code{WFDB_WRITE}, or \code{WFDB_AHA_READ},
    \code{WFDB_AHA_WRITE} for the AHA format), or a list of them.}
  \item{nann}{the number of annotators of \code{aiarray} to open (default:
    all).}
  \item{an, n}{an annotator number: input and output annotators are
    numbered separately, from 0, in the order in which they were
    opened.}
  \item{annot}{an \code{\link{annotation}} list.}
  \item{t}{a time, in samples (a negative value is an absolute time, as
    returned by \code{\link{strtim}}).}
  \item{f}{a time resolution, in ticks per second.}
  \item{aux}{an auxiliary string as stored in annotations (a raw vector
    whose first byte is the length of the data that follows), or
    \code{NULL}.}
}
\details{
  \code{annopen} opens the annotation files
  \file{\var{record}.\var{name}} of a record: input files are read under
  the input directory, output files are created under the output directory
  (by default, the current directory; see \code{\link{getwfdb}}; in
  legacy mode, input files are searched for in the WFDB path).  \code{getann(an)} then returns the next
  annotation of input annotator \code{an}, and \code{putann(an, annot)}
  writes an annotation to output annotator \code{an}.
  \code{ungetann} pushes one annotation back, to be returned by the next
  \code{getann}.  \code{iannsettime(t)} moves all input annotators to the
  first annotation at or after time \code{t}.  \code{iannclose} and
  \code{oannclose} close one annotator; \code{\link{wfdbquit}} closes all
  of them.  Output annotators must be closed (or the library quit with
  \code{wfdbquit}) for the files to be complete.

  The \code{aux} field of the annotations returned by \code{getann} is a
  raw vector, as in C: a length byte, the data, and possibly further
  bytes left over from earlier annotations (the C library reuses a
  buffer).  \code{aux_string} extracts the text.  \code{putann} accepts
  \code{aux} as a raw vector of this form or as a character string.

  Annotation files may begin with \dQuote{modification labels}:
  \code{NOTE} annotations at time 0 that define mnemonics or descriptions
  of annotation codes (see \code{\link{setannstr}}) or the time resolution
  of the file.  \code{annopen} applies and skips them when reading;
  output annotators write them for the codes whose mnemonics or
  descriptions were modified, and for the time resolution set by
  \code{setafreq}.

  Annotation times are normally in samples of the record.  An annotation
  file may record a different time resolution: \code{setafreq} sets the
  resolution of the output annotators opened afterwards (0 for the
  default; it is not reset by \code{wfdbquit}), \code{setiafreq} the
  resolution in which \code{getann} returns the times of an input
  annotator.

  Annotations must be written in time order.  If they are not, the file
  is sorted when it is closed, unless the environment variable
  \env{WFDBANNSORT} is \code{0}: WFDB-x: in the same R process, with a
  result identical to that of the \command{sortann} tool (the time
  resolution and the annotation type definitions of the file are kept,
  \code{NOTQRS} annotations are dropped, and of several annotations with
  the same time, \code{num} and \code{chan}, the last one written is
  kept; unlike the original \command{sortann}, an out-of-order annotation
  at time 0 is not lost).  The C library, as legacy mode
  (\code{\link{wfdbx_set_legacy}}), runs the \command{sortann} tool (with
  \option{--legacy}, in the output directory if one is set) in a separate
  process, with the original loss.
}
\value{
  \code{annopen} returns 0 on success, or -3 (an input annotator cannot
  be read), -4 (an output annotator cannot be created) or -5 (illegal
  mode).

  \code{getann} returns \code{list(stat, annot)}: \code{stat} is 0 and
  \code{annot} the next annotation, or \code{stat} is -1 at the end of the
  file, -2 for an invalid annotator number, -3 after an unexpected end of
  file (\code{annot} is then \code{NULL}).

  \code{ungetann} returns 0, or -1 if an annotation was already pushed
  back, -2 for an invalid annotator number.

  \code{putann} returns 0, or -1 (write error, or time out of range) or -2
  (invalid annotator number).

  \code{iannsettime} returns 0, or -1 if an annotator could not be
  positioned.

  \code{getafreq} returns the time resolution set by \code{setafreq}.
  \code{getiafreq} returns the time resolution of the times returned by
  \code{getann}, \code{getiaorigfreq} the one recorded in the file (0 if
  none); both return -2 for an invalid annotator number.

  \code{aux_string} returns the text of an auxiliary string (up to its
  first null byte) as a character string, or \code{NULL} for
  \code{NULL}.

  The other functions return \code{NULL}, invisibly.  On failure, a
  message is also printed on the standard error output (see
  \code{\link{wfdbquiet}}).
}
\section{Origin}{
  \code{aux_string} is part of WFDB-x; not in the original WFDB package.

  Translation of the C functions annopen(), getann(), ungetann(),
  putann(), iannsettime(), iannclose(), oannclose(), setafreq(),
  getafreq(), setiafreq(), getiafreq() and getiaorigfreq() (lib/annot.c,
  WFDB 10.7.0): same arguments and results. Differences: an out-of-order
  output file is sorted in this process, without losing annotations,
  instead of by running sortann, and input files are read from the input
  directory, not searched for in the WFDB path; see
  \file{docs/DIVERGENCES.md}.
}
\seealso{
  \code{\link{read_annotations}} and \code{\link{write_annotations}} for
  whole files; \code{\link{annotation}} and \code{\link{anninfo}} for the
  structures; \code{\link{ecgcodes}}, \code{\link{annstr}} and
  \code{\link{isqrs}} for annotation codes.
}
\examples{
old <- setwd(tempdir())
## "example" is a record written by this example.
write_record("example", cbind(0:499), fs = 250, gains = 200, adcres = 16, units = "mV")

## write two annotations to annotator "tst"
annopen("example", anninfo("tst", WFDB_WRITE))
putann(0, annotation(time = 100, anntyp = NORMAL))
putann(0, annotation(time = 350, anntyp = PVC, aux = "(VT"))
wfdbquit()                      # close the file

## read them back
annopen("example", anninfo("tst", WFDB_READ))
getann(0)$annot$time            # 100
iannsettime(200)                # skip to time 200
a <- getann(0)$annot
annstr(a$anntyp)                # "V"
aux_string(a$aux)               # "(VT"
getann(0)$stat                  # -1: end of file
wfdbquit()

setwd(old)
}
