\name{timstr}
\alias{timstr}
\alias{mstimstr}
\alias{strtim}
\alias{wfdbx_time_needs_freq}
\alias{datstr}
\alias{strdat}
\alias{setbasetime}
\title{Time and Date Conversion}
\description{
  Convert between times in samples and time strings, and between Julian
  dates and date strings, as the WFDB library does.  Conversions use the
  sampling frequency of the open record (or the one set by
  \code{\link{setsampfreq}}) and its base time and date (the time of its
  first sample, if known).  \code{wfdbx_time_needs_freq} (a wfdb-x
  addition) tells whether \code{strtim} needs the sampling frequency to
  convert a time string.
}
\usage{
timstr(t)
mstimstr(t)
strtim(string)
wfdbx_time_needs_freq(string)
datstr(date)
strdat(string)
setbasetime(string)
}
\arguments{
  \item{t}{a time in samples (sample intervals).  A positive value is
    an elapsed time from the start of the record; a negative value (and
    0, when a base time is defined) is an absolute time, a time of day.}
  \item{string}{\code{strtim}, \code{wfdbx_time_needs_freq}: a time
    string (see Details).
    \code{strdat}: a date string, \code{"dd/mm/yyyy"}.
    \code{setbasetime}: the base time and date of the record,
    \code{"hh:mm:ss"} or \code{"hh:mm:ss dd/mm/yyyy"}; \code{NULL} or
    \code{""} sets the current time and date.}
  \item{date}{a Julian date (the number of days since 1 January 4713 BC;
    for example 2451545 is 1 January 2000).}
}
\details{
  \code{strtim} accepts the time strings of the WFDB tools:
  \describe{
    \item{\code{"hh:mm:ss.sss"}, \code{"mm:ss"}, \code{"ss"}}{an elapsed
      time from the start of the record (hours and fractions of seconds
      are optional).}
    \item{\code{"[hh:mm:ss.sss dd/mm/yyyy]"}}{an absolute time (time of
      day, with an optional date), returned as a negative number of
      samples.}
    \item{\code{"s12345"}}{a sample number.}
    \item{\code{"e"}}{the end of the record.}
    \item{\code{"c12345"}}{a counter value (see \code{\link{setcfreq}}).}
    \item{\code{"i"}}{the current position of the input signals.}
  }
  An absolute time \code{t} returned by \code{strtim} can be turned into
  a sample number with \code{-t}.

  wfdb-x never assumes a sampling frequency (the C library uses 1 sample
  per second when none is known; see \file{docs/DIVERGENCES.md} in the
  wfdb-x sources).  When no frequency is known (no open record, a header
  that does not give one, and none set with \code{\link{setsampfreq}}),
  \code{timstr} and \code{mstimstr} report the error \dQuote{sampling
  frequency is not specified} and return the time as a sample number
  (\code{"s"} followed by its absolute value), and \code{strtim} reports
  the same error and returns 0 for a string that needs the frequency.
  Only sample numbers (\code{"s..."}), \code{"e"}, \code{"i"},
  \code{"o"}, and counter values (\code{"c..."}) when no counter
  frequency is defined do not need it.
}
\value{
  \code{timstr} returns a time string, \code{"hh:mm:ss"} for an elapsed time
  (right-aligned, without the hours when they are zero), or
  \code{"[hh:mm:ss dd/mm/yyyy]"} for an absolute time.  \code{mstimstr}
  is the same with milliseconds (\code{"hh:mm:ss.sss"}).

  \code{strtim} returns a time in samples (negative for absolute times).

  \code{wfdbx_time_needs_freq} returns 1 (an integer) if \code{strtim}
  needs the sampling frequency to convert \code{string} (after any leading
  spaces, tabs, newlines and carriage returns), 0 otherwise.

  \code{datstr} returns a date string, \code{" dd/mm/yyyy"} (with a
  leading space).  \code{strdat} returns a Julian date, or 0 if the string
  is not a valid date.

  \code{setbasetime} returns 0, or -1 if the string is not valid.
}
\seealso{
  \code{\link{sampfreq}}, \code{\link{setsampfreq}},
  \code{\link{isigsettime}}.
}
\examples{
setsampfreq(360)
strtim("1:00")                  # one minute: 21600 samples
strtim("s100")                  # sample 100
timstr(21600)
mstimstr(361)
wfdbx_time_needs_freq("1:00")   # 1
wfdbx_time_needs_freq("s100")   # 0
datstr(strdat("01/01/2000"))

setbasetime("08:00:00 01/02/2003")
timstr(0)                       # the base time and date
t <- strtim("[08:00:10]")       # 10 s after the start, as an absolute time
-t
timstr(t)
setbasetime("")                 # now
}
