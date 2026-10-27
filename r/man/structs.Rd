\name{siginfo}
\alias{siginfo}
\alias{anninfo}
\alias{annotation}
\alias{calinfo}
\alias{seginfo}
\title{Structures of the WFDB Library}
\description{
  Create the structures used by the WFDB library functions
  (\code{WFDB_Siginfo}, \code{WFDB_Anninfo}, \code{WFDB_Annotation},
  \code{WFDB_Calinfo} and \code{WFDB_Seginfo} in C).  In R they are named
  lists whose elements have the names of the C fields; the library
  functions accept and return them.
}
\usage{
siginfo(fname = NULL, desc = NULL, units = NULL, gain = 0, initval = 0,
        group = 0, fmt = 0, spf = 1, bsize = 0, adcres = 0, adczero = 0,
        baseline = 0, nsamp = 0, cksum = 0)
anninfo(name = NULL, stat = WFDB_READ)
annotation(time = 0, anntyp = 0, subtyp = 0, chan = 0, num = 0, aux = NULL)
calinfo(low = 0, high = 0, scale = 0, sigtype = NULL, units = NULL,
        caltype = 0)
seginfo(recname = "", nsamp = 0, samp0 = 0)
}
\arguments{
  \item{fname}{\code{siginfo}: the name of the signal file.}
  \item{desc}{\code{siginfo}: the description (name) of the signal.}
  \item{units}{the physical units (\code{NULL}: unspecified; wfdb-x never
    takes unspecified units to be millivolts).}
  \item{gain}{\code{siginfo}: ADC units per physical unit (0:
    uncalibrated).}
  \item{initval}{\code{siginfo}: the value of the first sample.}
  \item{group}{\code{siginfo}: the signal group number (signals of the
    same group are stored in the same file).}
  \item{fmt}{\code{siginfo}: the storage format (see
    \code{\link{WFDB_FMT_LIST}}).}
  \item{spf}{\code{siginfo}: the number of samples per frame.}
  \item{bsize}{\code{siginfo}: the block size of the file (0 for ordinary
    files).}
  \item{adcres}{\code{siginfo}: the ADC resolution in bits (0 if
    unspecified).}
  \item{adczero}{\code{siginfo}: the ADC value at the centre of the range
    of the converter.}
  \item{baseline}{\code{siginfo}: the ADC value of physical zero.}
  \item{nsamp}{the number of samples (\code{siginfo}: of the signal;
    \code{seginfo}: of the segment).}
  \item{cksum}{\code{siginfo}: the 16-bit checksum of the samples.}
  \item{name}{\code{anninfo}: the annotator name (extension of the
    annotation file, such as \code{"atr"}).}
  \item{stat}{\code{anninfo}: the mode: \code{WFDB_READ},
    \code{WFDB_WRITE}, \code{WFDB_AHA_READ} or \code{WFDB_AHA_WRITE} (see
    \code{\link{getwfdb}}).}
  \item{time}{\code{annotation}: the time of the annotation, in
    samples.}
  \item{anntyp}{\code{annotation}: the annotation type code (see
    \code{\link{ecgcodes}}).}
  \item{subtyp, chan, num}{\code{annotation}: the subtype, the signal
    number and the \code{num} field.}
  \item{aux}{\code{annotation}: the auxiliary data: \code{NULL}, or a raw
    vector whose first byte is the number of bytes that follow (as in C).
    \code{\link{putann}} also accepts a character string.}
  \item{low, high, scale}{\code{calinfo}: the low and high levels of the
    calibration pulse in physical units, and the customary plotting scale
    (physical units per centimetre).}
  \item{sigtype}{\code{calinfo}: the signal type (a prefix of signal
    descriptions, such as \code{"ECG"}).}
  \item{caltype}{\code{calinfo}: the type of calibration pulse (see
    \code{\link{calopen}}).}
  \item{recname}{\code{seginfo}: the record name of the segment.}
  \item{samp0}{\code{seginfo}: the sample number of the first sample of
    the segment.}
}
\details{
  A C \code{NULL} string is \code{NULL} in R.  Note that \code{x$f <- NULL}
  removes element \code{f} from a list: to set a field to \code{NULL}, use
  \code{x["f"] <- list(NULL)}.  For an array of structures, use a list of
  them, for example \code{replicate(2, siginfo(), simplify = FALSE)}.
}
\value{A named list with the fields of the structure.}
\section{Origin}{
  The structures are those of lib/wfdb.h (WFDB 10.7.0), with the same
  fields; these functions, which create them, are new.

  Part of wfdb-x; not in the original WFDB package.
}
\seealso{
  \code{\link{isigopen}}, \code{\link{osigfopen}} and
  \code{\link{read_header}} (\code{siginfo}); \code{\link{annopen}}
  (\code{anninfo}); \code{\link{getann}} and \code{\link{putann}}
  (\code{annotation}); \code{\link{getcal}} (\code{calinfo});
  \code{\link{getseginfo}} (\code{seginfo}).
}
\examples{
a <- annotation(time = 100, anntyp = NORMAL)
str(a)

s <- siginfo(fname = "rec.dat", desc = "ECG", units = "mV", gain = 200,
             fmt = 16)
s["units"] <- list(NULL)        # set a field to NULL
names(s)
}
