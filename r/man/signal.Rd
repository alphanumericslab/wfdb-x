\name{isigopen}
\alias{isigopen}
\alias{osigopen}
\alias{osigfopen}
\alias{findsig}
\alias{getspf}
\alias{setgvmode}
\alias{getgvmode}
\alias{setifreq}
\alias{getifreq}
\alias{getvec}
\alias{getframe}
\alias{getframes}
\alias{putvec}
\alias{putframes}
\alias{isigsettime}
\alias{isgsettime}
\alias{tnextvec}
\alias{setibsize}
\alias{setobsize}
\alias{newheader}
\alias{setheader}
\alias{setmsheader}
\alias{getseginfo}
\alias{wfdbgetskew}
\alias{wfdbsetiskew}
\alias{wfdbsetskew}
\alias{wfdbgetstart}
\alias{wfdbsetstart}
\alias{wfdbputprolog}
\alias{setinfo}
\alias{putinfo}
\alias{getinfo}
\alias{wfdb_freeinfo}
\alias{sampfreq}
\alias{setsampfreq}
\alias{getcfreq}
\alias{setcfreq}
\alias{getbasecount}
\alias{setbasecount}
\alias{adumuv}
\alias{muvadu}
\alias{aduphys}
\alias{physadu}
\alias{wfdb_sample}
\alias{sample_valid}
\alias{wfdbinit}
\alias{wfdbquit}
\alias{wfdbflush}
\alias{WFDB_INVALID_SAMPLE}
\alias{WFDB_DEFFREQ}
\alias{WFDB_DEFGAIN}
\alias{WFDB_DEFRES}
\alias{WFDB_LOWRES}
\alias{WFDB_HIGHRES}
\alias{WFDB_GVPAD}
\alias{WFDB_MAXUSL}
\alias{WFDB_MAXDSL}
\alias{WFDB_FMT_LIST}
\title{Signal Input and Output (WFDB Library)}
\description{
  The signal functions of the WFDB library: opening records, reading and
  writing samples, writing header files, info strings (comments in
  headers), sampling and counter frequencies, and conversion between ADC
  and physical units.  They have the names and the behaviour of the
  functions of the C library, described in the \emph{WFDB Programmer's
  Guide}; this page gives their R calling conventions.  For simple
  reading and writing of whole records, see \code{\link{read_record}}.
}
\usage{
isigopen(record, nsig = 0)
osigopen(record, nsig)
osigfopen(siarray, nsig = length(siarray))
findsig(p)
getspf()
setgvmode(mode)
getgvmode()
setifreq(f)
getifreq()
getvec()
getframe()
getframes(n, minstat = 0)
putvec(vector)
putframes(m)
isigsettime(t)
isgsettime(g, t)
tnextvec(s, t)
setibsize(n)
setobsize(n)
newheader(record)
setheader(record, siarray, nsig = length(siarray))
setmsheader(record, segment_name, nsegments = length(segment_name))
getseginfo()
wfdbgetskew(s)
wfdbsetiskew(s, skew)
wfdbsetskew(s, skew)
wfdbgetstart(s)
wfdbsetstart(s, nbytes)
wfdbputprolog(buf, size, s)
setinfo(record)
putinfo(s)
getinfo(record = NULL)
wfdb_freeinfo()
sampfreq(record = NULL)
setsampfreq(freq)
getcfreq()
setcfreq(freq)
getbasecount()
setbasecount(counter)
adumuv(s, a)
muvadu(s, v)
aduphys(s, a)
physadu(s, v)
wfdb_sample(s, t)
sample_valid()
wfdbinit(record, aiarray, nsig)
wfdbquit()
wfdbflush()
}
\arguments{
  \item{record}{a record name (character string).  For \code{isigopen}
    and \code{osigopen}, a leading \code{"+"} adds the signals to those
    already open instead of closing them first.  For \code{getinfo},
    \code{NULL} returns the next info string of the record already
    being read.  For \code{sampfreq}, \code{NULL} means the record that is
    open.  For \code{setinfo}, \code{NULL} closes the info file.}
  \item{nsig}{the number of signals to open.  For \code{isigopen}, a
    value \eqn{\le 0}{<= 0} opens no signals but reads the header: then
    \code{-nsig} is the number of \code{siginfo} lists to return.}
  \item{siarray}{a list of \code{\link{siginfo}} lists, one per signal.}
  \item{p}{a signal name (description), or a signal number given as a
    character string.}
  \item{mode}{the mode of \code{getvec}: \code{WFDB_LOWRES} (0) or
    \code{WFDB_HIGHRES} (1), optionally combined with \code{WFDB_GVPAD}
    (2) by addition or \code{bitwOr}.  A negative value takes the mode
    from the environment variable \env{WFDBGVMODE}.}
  \item{f, freq}{a frequency in Hz.}
  \item{n}{\code{getframes}: the number of sample vectors to read (may be
    \code{Inf}).  \code{setibsize}, \code{setobsize}: a buffer size in
    bytes (0 for the default).}
  \item{minstat}{\code{getframes}: stop at the first sample vector for
    which \code{getvec} would return a status less than \code{minstat}
    (see Value).}
  \item{vector}{a sample vector: one sample per output signal, or, for
    signals with several samples per frame, a whole frame.}
  \item{m}{a numeric matrix of samples, one row per sample vector (as
    given to \code{putvec}).}
  \item{t}{a time, in samples.  A negative value is an absolute time
    (time of day), as returned by \code{\link{strtim}} for a string such
    as \code{"[08:00:00]"}.}
  \item{g}{an input signal group number (0-based; signals stored in the
    same file form a group).}
  \item{s}{a signal number (0-based).  For \code{putinfo}, the info string
    to write (character string or raw vector).}
  \item{segment_name}{the record names of the segments of a multi-segment
    record (character vector).}
  \item{nsegments}{the number of segments.}
  \item{skew}{a skew, in frames.}
  \item{nbytes}{the length in bytes of the prolog of a signal file (the
    bytes that precede the first sample).}
  \item{buf}{the contents of a prolog (raw vector or character
    string).}
  \item{size}{the number of bytes of \code{buf} to write.}
  \item{counter}{the value of the counter at sample 0.}
  \item{a}{a sample value in ADC units.}
  \item{v}{a value in microvolts (\code{muvadu}) or in physical units
    (\code{physadu}).}
  \item{aiarray}{a list of \code{\link{anninfo}} lists (the annotators to
    open).}
}
\details{
  \subsection{Reading samples}{
    \code{isigopen} reads the header of a record and opens its signal
    files.  Each call of \code{getvec} then returns the next sample of
    every open signal; \code{getframe} returns a whole frame (all the
    samples of a multi-frequency record within one frame interval).
    \code{getframes(n)} reads up to \code{n} sample vectors at once, as a
    matrix: it gives exactly the result of up to \code{n} calls of
    \code{getvec}, much faster.  \code{isigsettime} moves all input signals
    to a given sample number, \code{isgsettime} one signal group only.
    \code{wfdb_sample(s, t)} returns the sample of signal \code{s} at time
    \code{t}, reading the record as needed: it is the C function
    \code{sample}, renamed so as not to mask \code{base::sample}.
    \code{sample_valid} tells whether the last value returned by
    \code{wfdb_sample} was valid.  \code{tnextvec(s, t)} moves to the next
    valid sample of signal \code{s} at or after time \code{t}.

    For multi-frequency records, \code{setgvmode} selects whether
    \code{getvec} returns one sample per signal per frame (averaging the
    faster signals, \code{WFDB_LOWRES}, the default) or one sample per
    signal at the highest sampling frequency (\code{WFDB_HIGHRES}).  With
    \code{WFDB_GVPAD}, invalid samples are replaced by the previous valid
    sample.  \code{setifreq} resamples all input signals to a given
    frequency; it fails (returning -1) if the sampling frequency of the
    open record is not specified.
  }
  \subsection{Writing samples and headers}{
    \code{osigfopen} creates the signal files described by a list of
    \code{siginfo} lists (field \code{fname} is the file name, \code{fmt}
    the format); \code{osigopen} does the same as described by the header
    of an existing record.  wfdb-x: neither creates an output signal file
    that is one of the signal files of the open input record (one open
    for input, or one of any segment of an open multi-segment record;
    the files are compared, not their names): it reports
    \samp{osigfopen: output file NAME is also an input file} (or
    \samp{osigopen: ...}) and returns -3, without creating or truncating
    the file (not in legacy mode; identical in all seven implementations).
    \code{putvec} writes one sample vector,
    \code{putframes} one per row of a matrix (exactly as many calls of
    \code{putvec}).  \code{newheader} then writes the header file of the
    record (call it after writing the samples, so that it contains the
    number of samples and checksums).  \code{setheader} writes a header
    from a list of \code{siginfo} lists, \code{setmsheader} the header of
    a multi-segment record.  \code{setsampfreq}, \code{setbasetime} (see
    \code{\link{timstr}}), \code{setcfreq} and \code{setbasecount} set the
    values recorded in headers written later.  \code{putinfo} adds an info
    string to the header (call it after \code{newheader}), or to the
    \file{.info} file opened by \code{setinfo}.
  }
  \subsection{Closing}{
    \code{wfdbquit} closes all open signal and annotation files (writing
    any buffered output) and resets the library state;
    \code{wfdbflush} writes buffered output without closing.
    \code{wfdbinit} opens annotators (\code{\link{annopen}}) and input
    signals (\code{isigopen}) in one call.
  }
  \subsection{Constants}{
    \code{WFDB_INVALID_SAMPLE} (-32768) is the value of invalid (missing)
    samples.  \code{WFDB_DEFFREQ} (250) and \code{WFDB_DEFGAIN} (200) are
    the default sampling frequency and gain of the C library; wfdb-x
    defines them for compatibility but never uses them (see
    \file{docs/DIVERGENCES.md} in the wfdb-x sources).
    \code{WFDB_DEFRES} (12) is the default ADC resolution in bits of the C
    library; it is likewise defined but unused (a header that does not
    give a resolution leaves it unspecified: \code{adcres} 0).  \code{WFDB_FMT_LIST} lists the supported signal
    file formats: 0 (null signal), 8, 16, 61, 80, 160, 212, 310, 311, 24,
    32, and 508, 516, 524 (FLAC-compressed).  \code{WFDB_MAXUSL} (50) and
    \code{WFDB_MAXDSL} (100) are the maximum lengths of units strings and
    signal descriptions in headers.
  }
}
\value{
  Most functions return the value of the C function: 0 or a positive
  value on success, a negative error code on failure (a message is then
  printed on the standard error output, unless \code{\link{wfdbquiet}}
  was called).  Functions that return nothing useful in C return
  \code{NULL} invisibly.  In particular:
  \describe{
    \item{\code{isigopen}, \code{osigopen}}{\code{list(nsig, si)}:
      \code{nsig} is the number of signals opened (for \code{isigopen}
      with \code{nsig <= 0}: the number of signals of the record), or a
      negative error code (for example -1 if the header cannot be read,
      -2 if it is invalid); \code{si} is the
      list of the \code{siginfo} lists of these signals.}
    \item{\code{osigfopen}}{the number of signals opened, or a negative
      error code.}
    \item{\code{findsig}}{the signal number, or -1 if there is no such
      signal.}
    \item{\code{getvec}, \code{getframe}}{\code{list(stat, v)}:
      \code{stat} is the number of signals read, 0 or -1 at the end of
      the record, -3 at an unexpected end of a file, or another value
      below -1 on error; \code{v} is the sample vector (or frame).}
    \item{\code{getframes}}{\code{list(v, stat)}: \code{v} is a matrix
      with one row per sample vector read (one column per signal);
      reading stops after \code{n} vectors, or at the first vector for
      which \code{getvec} returns a negative status (or one less than
      \code{minstat}), which is not included.  \code{stat} is the status
      that stopped reading, or the number of signals if \code{n} vectors
      were read.}
    \item{\code{putvec}, \code{putframes}}{the number of output signals;
      0 if a sample had to be clipped (format 8), -1 on a write error.
      For \code{putframes}, the smallest of the values of the
      \code{putvec} calls.}
    \item{\code{isigsettime}, \code{isgsettime}}{0, or a negative value
      if the time is out of range or the file cannot be positioned.}
    \item{\code{tnextvec}}{the time of the next valid sample, or a
      negative value if there is none.}
    \item{\code{setibsize}, \code{setobsize}}{the new buffer size, or -1
      if signals are already open, -2 for an illegal size.}
    \item{\code{getseginfo}}{a list of \code{\link{seginfo}} lists (the
      segments of the open multi-segment record).}
    \item{\code{wfdbgetskew}, \code{wfdbgetstart}}{the skew (in frames),
      the length of the prolog (in bytes) of an input signal.}
    \item{\code{getinfo}}{the next info string (a character string), or
      \code{NULL} if there are no more.  \code{getinfo(record)} returns
      the first one of \code{record}, \code{getinfo(NULL)} the next one.
      \code{wfdb_freeinfo} discards the strings read, so that the next
      \code{getinfo(NULL)} starts again from the first info string of the
      open record.}
    \item{\code{sampfreq}}{the sampling frequency (Hz), 0 if the header
      does not specify it (wfdb-x: the C library assumes 250 Hz) and none
      was set with \code{setsampfreq} before the record was opened, or a
      negative value if the header cannot be read.}
    \item{\code{getspf}, \code{getgvmode}, \code{getifreq},
      \code{getcfreq}, \code{getbasecount}}{the current values (samples
      per signal per \code{getvec} sample, \code{getvec} mode, input
      frequency, counter frequency, base counter value).}
    \item{\code{adumuv}, \code{muvadu}, \code{aduphys}, \code{physadu}}{the
      converted value, using the gain and baseline of signal \code{s}.
      If the signal is uncalibrated (gain 0) or \code{s} is not an open
      signal, they report an error and return \code{WFDB_INVALID_SAMPLE}
      (\code{aduphys}: \code{NaN}); wfdb-x: the C library assumes a gain
      of 200.
      \code{adumuv}, \code{muvadu} and \code{physadu} round to an integer
      and take a single value.}
    \item{\code{wfdb_sample}}{the sample value, or
      \code{WFDB_INVALID_SAMPLE}.  \code{sample_valid} returns 1 if it is
      valid, 0 after the end of the record (or an error), -1 if the sample
      is invalid or \code{s} is not an open signal.}
    \item{\code{wfdbinit}}{\code{list(stat, si)}: the status of
      \code{annopen} if it failed, otherwise the result of
      \code{isigopen}.}
  }
}
\section{Origin}{
  \code{getframes} and \code{putframes} are part of wfdb-x; not in the
  original WFDB package.

  Translation of the C functions isigopen(), osigopen(), osigfopen(),
  findsig(), getspf(), setgvmode(), getgvmode(), setifreq(), getifreq(),
  getvec(), getframe(), putvec(), isigsettime(), isgsettime(),
  tnextvec(), setibsize(), setobsize(), newheader(), setheader(),
  setmsheader(), getseginfo(), wfdbgetskew(), wfdbsetiskew(),
  wfdbsetskew(), wfdbgetstart(), wfdbsetstart(), wfdbputprolog(),
  setinfo(), putinfo(), getinfo(), wfdb_freeinfo(), sampfreq(),
  setsampfreq(), getcfreq(), setcfreq(), getbasecount(), setbasecount(),
  adumuv(), muvadu(), aduphys(), physadu(), sample() (here
  \code{wfdb_sample}) and sample_valid() (lib/signal.c, WFDB 10.7.0),
  and wfdbinit(), wfdbquit() and wfdbflush() (lib/wfdbinit.c, WFDB
  10.7.0): same arguments and results. Differences: no sampling
  frequency, gain or ADC resolution is assumed, the files named in a
  header are read only from its directory, and an output signal file is
  never one of the input files; see \file{docs/DIVERGENCES.md}.
}
\seealso{
  \code{\link{read_record}} and \code{\link{write_record}} for whole
  records; \code{\link{siginfo}} for the structures; \code{\link{timstr}}
  for time conversions; \code{\link{annopen}} for annotations;
  \code{\link{getwfdb}} for finding files.
}
\examples{
old <- setwd(tempdir())
## "example" and "rec2" are records written by this example.
write_record("example", cbind(0:499, 499:0), fs = 250, gains = 200, adcres = 16,
             units = "mV", names = c("up", "down"))

r <- isigopen("example", 2)
r$nsig                          # 2 signals opened
sapply(r$si, function(s) s$desc)
findsig("down")                 # 1
getvec()$v                      # the first sample vector
getframes(3)$v                  # the next three, as a matrix
isigsettime(10)
getvec()$v                      # sample 10
wfdb_sample(1, 100)             # sample 100 of signal 1
sampfreq(NULL)
aduphys(0, 100)                 # 100 ADC units in physical units
wfdbquit()

## writing a record sample by sample
si <- list(siginfo(fname = "rec2.dat", desc = "ramp", units = "mV",
                   gain = 100, fmt = 16, adcres = 16))
osigfopen(si)
setsampfreq(100)
for (i in 0:9) putvec(i * 10)
newheader("rec2")
putinfo("written by putvec")
wfdbquit()
read_record("rec2")$signals[, 1]

setwd(old)
}
