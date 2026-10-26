\name{read_record}
\alias{read_record}
\alias{read_header}
\alias{write_record}
\title{Read and Write WFDB Records}
\description{
  \code{read_record} reads the signals of a WFDB record into a matrix,
  together with the main information of its header.  \code{read_header}
  reads only the header (the record line, the description of each signal
  and the info strings).
  \code{write_record} writes a matrix of samples as a new record (a header
  file and one signal file).
}
\usage{
read_record(record, channels = NULL, sampfrom = 0, sampto = NULL,
            physical = FALSE, highres = FALSE, pad = FALSE,
            input_dir = NULL, network = NULL, legacy = FALSE,
            checksum_warning = TRUE)

read_header(record, input_dir = NULL, network = NULL, legacy = FALSE)

write_record(record, signals, fs, fmt = 16, gains, baselines = NULL,
             adczeros = 0, adcres = NULL, units = NULL, names = NULL,
             base_time = NULL, comments = NULL, physical = FALSE,
             samps_per_frame = NULL, dir = NULL, legacy = FALSE)
}
\arguments{
  \item{record}{the record name, a character string (for example
    \code{"100s"}).  When reading, the header file
    \file{\var{record}.hea} is read under the input directory, unless the
    name is a full path, a \code{~} path or a URL (wfdb-x: nothing is
    searched; see \code{\link{getwfdb}}), and its signal files next to
    it; a name with another extension,
    such as \code{"rec.edf"}, is read as an EDF file.  When writing, the
    files are created in the current directory.}
  \item{channels}{the signals to read: signal numbers (starting at 0, as
    in WFDB) or signal names (descriptions, as given in the header).  The
    default, \code{NULL}, reads all signals.}
  \item{sampfrom, sampto}{the first sample to read and the end of the
    interval (\code{sampto} itself is not read): sample numbers, or time
    strings as accepted by \code{\link{strtim}} (such as \code{"0:10"} for
    10 seconds, or \code{"s1000"} for sample 1000).  By default the whole
    record is read.  A time string that needs the sampling frequency (see
    \code{\link{wfdbx_time_needs_freq}}) is an error for a record whose
    header does not specify it.}
  \item{physical}{\code{read_record}: if \code{TRUE}, return the samples
    in physical units (\code{(sample - baseline) / gain}) instead of ADC
    units; this is an error if a selected signal is uncalibrated (gain
    0).  \code{write_record}: if \code{TRUE}, \code{signals} are given
    in physical units and are converted to ADC units with \code{gains} and
    \code{baselines} (rounded to the nearest integer; \code{NA} is written
    as an invalid sample).}
  \item{highres}{if \code{TRUE}, read a multi-frequency record (one with
    signals sampled at different rates) at the highest sampling frequency
    of its signals (\code{WFDB_HIGHRES} mode; samples of the slower
    signals are repeated).  By default such a record is read at its frame
    rate, the faster signals being averaged (\code{WFDB_LOWRES} mode).
    This has no effect on ordinary records.}
  \item{pad}{if \code{TRUE}, replace each invalid sample by the previous
    valid sample of the same signal (\code{WFDB_GVPAD} mode).}
  \item{signals}{the samples to write: a numeric matrix with one row per
    sample and one column per signal (a vector is taken as a single
    signal).  For a multi-frequency record (see \code{samps_per_frame}),
    one row per frame and one column per sample of a frame.}
  \item{fs}{the sampling frequency in Hz (for a multi-frequency record,
    the frame rate).  Required, and greater than 0.}
  \item{fmt}{the storage format of the signal file (see
    \code{\link{WFDB_FMT_LIST}}), for example 16 (16-bit samples), 212
    (12-bit packed) or 516 (FLAC-compressed).  All signals must have the
    same format.}
  \item{gains}{the gains (ADC units per physical unit) of the signals
    (required: there is no default).  A gain of 0 declares a signal
    \dQuote{uncalibrated}, which is allowed only when \code{signals} are
    given in ADC units (\code{physical = FALSE}).}
  \item{baselines}{the baselines (the ADC values of physical zero); by
    default equal to \code{adczeros}.}
  \item{adczeros}{the ADC values at the centre of the range of the
    converter.}
  \item{adcres}{the ADC resolutions in bits (at least 1; required: there
    is no default, not even one implied by \code{fmt}).}
  \item{units}{the physical units of the signals (for example
    \code{"mV"}), as a character vector or a list.  Required for every
    signal whose gain is not 0 (there is no default); for an
    uncalibrated signal, a \code{NULL} entry leaves the units
    unspecified.}
  \item{names}{the descriptions (names) of the signals, as a character
    vector or a list.  Signals without a name are described as
    \samp{record \var{record}, signal \var{n}} when the record is read
    back.}
  \item{base_time}{the time and date of the start of the record, as
    \code{"hh:mm:ss"} or \code{"hh:mm:ss dd/mm/yyyy"}; by default the
    header has none.}
  \item{comments}{a character vector of comment lines (\dQuote{info
    strings}) to add to the end of the header.}
  \item{samps_per_frame}{for a multi-frequency record: the number of
    samples per frame of each signal.  \code{signals} then has
    \code{sum(samps_per_frame)} columns: the \code{samps_per_frame[1]}
    samples of the first signal, then those of the second signal, and so
    on.}
  \item{dir}{if given, the directory (which must exist) in which the files
    are created (wfdb-x).  The header then names the record and its signal
    file without the directory, so that the record opens from that
    directory under its plain name (for example with
    \code{setwfdb(dir)}); \code{record} must not contain a directory.  The
    library's output directory (\code{\link{wfdbx_set_output_dir}}) is set
    for the duration of the call and restored afterwards, also on errors.}
  \item{input_dir}{the input directory for this call (a local directory, a
    \code{~} name or a URL; see \code{\link{wfdbx_set_input_dir}}), or
    \code{NULL} (the default) for the current setting.  The previous value
    is restored afterwards, also on errors (wfdb-x).}
  \item{network}{\code{TRUE} to allow reading URLs for this call,
    \code{FALSE} to forbid it (see \code{\link{wfdbx_set_network}}), or
    \code{NULL} (the default) for the current setting (by default, not
    allowed).  The previous value is restored afterwards (wfdb-x).}
  \item{checksum_warning}{\code{read_record}: if \code{TRUE} (the
    default), warn when the samples read to the end of the record do not
    match the checksums in its header (see Value); \code{FALSE}: no
    warning.  The data are returned either way.}
  \item{legacy}{if \code{TRUE}, behave as the original package did (see
    Details), with the library's legacy mode (\code{\link{wfdbx_set_legacy}})
    on for the duration of the call; the previous setting is restored
    afterwards, also on errors.  With \code{FALSE} (the default), the
    current setting of the library applies.}
}
\details{
  For \code{write_record}, arguments that describe the signals
  (\code{fmt}, \code{gains}, \code{baselines}, \code{adczeros},
  \code{adcres}, \code{units}, \code{names}) are either a single value,
  used for all signals, or one value per signal.  The signal file is
  \file{\var{record}.dat}; existing files are overwritten.

  wfdb-x never assumes a sampling frequency, a gain, an ADC resolution or
  units (the C library assumes 250 Hz, 200 adu/mV, 12 bits or the width
  of the format, and millivolts; see \file{docs/DIVERGENCES.md} in the
  wfdb-x sources): \code{write_record} requires \code{fs}, \code{gains},
  \code{adcres} and the \code{units} of the calibrated signals (it stops
  with \dQuote{ADC resolution(s) must be specified} or \dQuote{units must
  be specified} otherwise), and \code{read_record} reports a sampling
  frequency of 0 for a record whose header does not give one, an ADC
  resolution of 0 (in \code{siginfo}) for a signal whose header line does
  not give one, and \code{NULL} units for a signal without units.

  With \code{legacy = TRUE}, these functions reproduce the original
  package exactly: \code{write_record} uses a gain of 200 adu/mV and an
  ADC resolution based on the format by default and requires no units;
  \code{read_record} and \code{read_header} read a header without a
  sampling frequency as 250 Hz and a missing ADC resolution as that of the
  format (or 12 bits), and \code{read_record} converts uncalibrated
  signals to physical units with a gain of 200.  This is kept for
  compatibility only: the values it assumes are exactly the silent
  defaults this project removed, so results produced with it carry the
  same risks.

  These functions are built on the library functions
  (\code{\link{isigopen}}, \code{\link{getframes}}, \code{\link{osigfopen}},
  \code{\link{putframes}}, \code{\link{newheader}}, ...), so they read and
  write exactly what the WFDB library and tools do.  Each call closes any
  record or annotation file opened with the library functions (as
  \code{\link{wfdbquit}} does), and leaves none open.
}
\value{
  \code{read_record} returns a list with the components
  \item{name}{the record name.}
  \item{fs}{the sampling frequency of the returned samples, in Hz (0 if
    the header does not specify it).}
  \item{signals}{a numeric matrix with one row per sample and one column
    per signal read.  In ADC units, invalid (missing) samples have the
    value \code{\link{WFDB_INVALID_SAMPLE}} (-32768); in physical units,
    they are \code{NA}.}
  \item{siginfo}{a list with one \code{\link{siginfo}} list per signal
    read (all the information of the header about the signal).}
  \item{names}{the signal descriptions (a character vector).}
  \item{units}{the physical units of the signals (a list; \code{NULL}
    means unspecified, never millivolts).}
  \item{gains, baselines}{the gains and baselines of the signals.}
  \item{base_time}{the time (and date) of the first sample of the record,
    such as \code{"[08:45:00 01/01/2001]"}, or \code{NULL} if the header
    does not give one (always the case if it does not give the sampling
    frequency).}
  \item{base_time_ms}{the base time of the record in milliseconds after
    midnight (a number: \code{50403500} for \code{14:00:03.500}; the
    milliseconds are kept), or \code{NULL}; it is \code{NULL} exactly
    when \code{base_time} is.}
  \item{base_date}{the base date of the record as an integer vector
    \code{c(year, month, day)} (converted as \code{\link{datstr}} does),
    or \code{NULL} if the header does not give a date.}
  \item{sampfrom}{the number of the first sample read.}
  \item{comments}{the info strings of the header (a character vector).}
  \item{checksum_ok}{\code{FALSE} if the samples were found not to match
    the checksums in the header (getvec status -4; whether or not
    \code{checksum_warning} is on), \code{TRUE} otherwise.  The checksums
    are verified only when the read reaches the end of the record.}

  \code{read_header} opens no signal file, and returns a list of class
  \code{"wfdbx_header"} with the components
  \item{name}{the record name, as given.}
  \item{fs}{the sampling frequency, as \code{\link{sampfreq}} gives it
    (0 if the header does not give it; with \code{legacy = TRUE}, 250).}
  \item{counter_freq, base_counter}{the counter frequency and the base
    counter value, as \code{\link{getcfreq}} and
    \code{\link{getbasecount}} give them.}
  \item{nsamples}{the number of samples per signal given on the record
    line of the header (0 if it does not give it).}
  \item{nsig}{the number of signals.}
  \item{siginfo}{a list with one \code{\link{siginfo}} list per signal.}
  \item{base_time, base_time_ms, base_date, comments}{as in
    \code{read_record}.}

  \code{write_record} returns \code{NULL}, invisibly.

  All three functions signal an error (with \code{stop}) if the record
  cannot be read or written; the WFDB library may also print a message on
  the standard error output.  \code{read_record} also signals an error,
  \code{"can't read signal data of record REC (getvec status S)"}, when
  reading stops with a \code{getvec} status below -1 (e.g. -3 for a signal
  file shorter than its header says), also in legacy mode; reaching the
  end of the record before \code{sampto} is not an error.  A checksum
  error (status -4: the samples are complete, their sum does not match the
  checksums in the header) is not an error either: every frame, the last
  one included, is returned, with the warning (\code{warning}, unless
  \code{checksum_warning = FALSE}) \code{"checksum error in record REC:
  the signal data do not match the checksums in its header"}; getvec's own
  message is not printed during the read (wfdb-x; identical in all six
  implementations).
}
\seealso{
  \code{\link{read_annotations}} for annotation files;
  \code{\link{isigopen}} and \code{\link{getvec}} for sample-by-sample
  access; \code{\link{wfdbx_tool}} to run \command{rdsamp} and
  \command{wrsamp}.
}
\examples{
old <- setwd(tempdir())

## write a two-signal record with a base time and a comment
x <- cbind(round(200 * sin(2 * pi * (0:499) / 50)), 0:499 \%\% 100)
write_record("example", x, fs = 250, gains = 200, adcres = 16,
             names = c("sine", "ramp"), units = "mV",
             base_time = "08:45:00 01/01/2001",
             comments = "a synthetic record")

## read it back
rec <- read_record("example", sampto = 5, physical = TRUE)
rec$signals
rec$base_time
rec$comments

## read 0.1 s of one signal, by name, in ADC units
read_record("example", channels = "ramp", sampfrom = "0:1",
            sampto = "0:1.1")$signals[, 1]

## the header only
h <- read_header("example")
h$nsamples
h$base_date
sapply(h$siginfo, function(s) s$desc)

setwd(old)
}
