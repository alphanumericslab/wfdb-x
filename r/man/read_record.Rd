\name{read_record}
\alias{read_record}
\alias{read_header}
\alias{write_record}
\title{Read and Write WFDB Records}
\description{
  \code{read_record} reads the signals of a record into a matrix, with the
  main information of its header.  \code{read_header} reads only the
  header.  \code{write_record} writes a matrix of samples as a new record:
  a header file and one signal file.
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
  \item{record}{the record name, such as \code{"100s"}.  A full path, a
    \code{~} path or a URL is used as given.  Any other name is read from
    the input directory and written to the output directory (see
    \code{\link{wfdbx_set_input_dir}}).  A name with another extension,
    such as \code{"rec.edf"}, is read as an EDF file.}
  \item{channels}{the signals to read: signal numbers, starting at 0, or
    signal names.  The default, \code{NULL}, reads all signals.}
  \item{sampfrom, sampto}{the first sample to read, and the sample after
    the last one.  Each is a sample number or a time string, such as
    \code{"0:10"} (10 seconds), \code{"s1000"} (sample 1000) or \code{"e"}
    (the end of the record); see \code{\link{strtim}}.  By default the
    whole record is read.}
  \item{physical}{\code{read_record}: if \code{TRUE}, return the samples
    in physical units, \code{(sample - baseline) / gain}, instead of ADC
    units.  \code{write_record}: if \code{TRUE}, \code{signals} are in
    physical units.  They are converted to ADC units with \code{gains} and
    \code{baselines} and rounded, and \code{NA} is written as an invalid
    sample.}
  \item{highres}{if \code{TRUE}, read a multi-frequency record at the
    highest sampling frequency of its signals.  Samples of the slower
    signals are repeated.  By default such a record is read at its frame
    rate, and the samples of the faster signals are averaged.}
  \item{pad}{if \code{TRUE}, replace each invalid sample by the previous
    valid sample of the same signal.}
  \item{input_dir}{the input directory for this call only: a local
    directory, a \code{~} path or a URL.  \code{NULL}, the default, keeps
    the current setting.}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting, which is off unless you turned it on.}
  \item{legacy}{if \code{TRUE}, behave as the original WFDB package for
    this call (see \code{\link{wfdbx_set_legacy}}).}
  \item{checksum_warning}{if \code{TRUE}, the default, \code{read_record}
    warns when the samples do not match the checksums in the header.
    \code{FALSE} turns the warning off.}
  \item{signals}{the samples to write: a numeric matrix with one row per
    sample and one column per signal.  A vector is written as a single
    signal.  For a multi-frequency record, see \code{samps_per_frame}.}
  \item{fs}{the sampling frequency in Hz, greater than 0.  For a
    multi-frequency record, this is the frame rate.}
  \item{fmt}{the storage format of the signal file, such as 16, 212 or
    516 (FLAC); see \code{\link{WFDB_FMT_LIST}}.  All signals have the
    same format.}
  \item{gains}{the gain of each signal, in ADC units per physical unit.
    A gain of 0 marks a signal as uncalibrated.  This is only allowed when
    \code{signals} are in ADC units.}
  \item{baselines}{the baseline of each signal: the ADC value of physical
    zero.  By default it equals \code{adczeros}.}
  \item{adczeros}{the ADC value at the middle of the converter's range.}
  \item{adcres}{the ADC resolution of each signal, in bits (at least 1).}
  \item{units}{the physical units of each signal, such as \code{"mV"}, as
    a character vector or a list.  They are required for every signal
    whose gain is not 0.}
  \item{names}{the description of each signal, as a character vector or a
    list.}
  \item{base_time}{the start time of the record, as \code{"hh:mm:ss"} or
    \code{"hh:mm:ss dd/mm/yyyy"}.  By default the header gives none.}
  \item{comments}{a character vector of info strings to add to the end of
    the header.}
  \item{samps_per_frame}{for a multi-frequency record, the number of
    samples per frame of each signal.  \code{signals} then has one row per
    frame and \code{sum(samps_per_frame)} columns: the samples of the
    first signal, then those of the second, and so on.}
  \item{dir}{the directory, which must exist, in which to create the
    files.  The header names the record without the directory, so you can
    read it from that directory under its plain name.  \code{record} must
    not contain a directory when \code{dir} is given.}
}
\details{
  In \code{write_record}, you must give \code{fs}, \code{gains},
  \code{adcres} and the \code{units} of each calibrated signal: there are
  no defaults.  The arguments that describe the signals (\code{fmt},
  \code{gains}, \code{baselines}, \code{adczeros}, \code{adcres},
  \code{units}, \code{names}) take one value for all signals, or one value
  per signal.  The signal file is \file{\var{record}.dat}.  Existing files
  of the same name are overwritten.

  A time string such as \code{"0:10"} needs the sampling frequency, and
  \code{physical = TRUE} needs the gain of each selected signal.  A record
  that does not give them cannot be read that way.

  Each call closes anything opened with the WFDB library functions, as
  \code{\link{wfdbquit}} does.
}
\value{
  \code{read_record} returns a list with these elements:
  \item{signals}{a numeric matrix with one row per sample and one column
    per signal read, in ADC units or physical units.  Invalid samples are
    \code{\link{WFDB_INVALID_SAMPLE}} (-32768) in ADC units, and
    \code{NA} in physical units.}
  \item{fs}{the sampling frequency in Hz, 0 if the header gives none.}
  \item{names}{the description of each signal.}
  \item{units}{the physical units of each signal, as a list.  An element
    is \code{NULL} when the header gives no units.}
  \item{gains, baselines}{the gain and baseline of each signal.  A gain of
    0 means uncalibrated.}
  \item{siginfo}{the full signal specifications: one
    \code{\link{siginfo}} list per signal.}
  \item{name}{the record name.}
  \item{sampfrom}{the number of the first sample returned.}
  \item{base_time}{the start time and date as text, to the second, such
    as \code{"[14:00:03 21/06/2024]"}.}
  \item{base_time_ms}{the start time in milliseconds after midnight, such
    as \code{50403500} for 14:00:03.500.}
  \item{base_date}{the start date as \code{c(year, month, day)}.}
  \item{comments}{the info strings of the header.}
  \item{checksum_ok}{\code{FALSE} if the samples do not match the
    checksums in the header, \code{TRUE} otherwise.  Checksums are only
    checked when a read reaches the end of the record.}
  \code{base_time}, \code{base_time_ms} and \code{base_date} are
  \code{NULL} when the header does not give them.

  \code{read_header} returns a list of class \code{"wfdbx_header"} with
  the elements \code{name}, \code{fs}, \code{counter_freq} (the counter
  frequency), \code{base_counter} (the base counter value),
  \code{nsamples} (the number of samples per signal, 0 if the header does
  not give it), \code{nsig} (the number of signals), \code{siginfo},
  \code{base_time}, \code{base_time_ms}, \code{base_date} and
  \code{comments}.  They have the same meaning as in the result of
  \code{read_record}.

  \code{write_record} returns \code{NULL}, invisibly.
}
\section{Errors and warnings}{
  \itemize{
    \item A record that cannot be read or written stops with an error,
      such as \samp{can't read record REC}.
    \item A signal file that is shorter than its header says stops with
      the error \samp{can't read signal data of record REC (getvec status
      -3)}.
    \item Invalid arguments, and a value the operation needs but the
      record does not give, stop with an error.
    \item When the samples do not match the checksums in the header,
      \code{read_record} returns all of them and issues the warning
      \samp{checksum error in record REC: the signal data do not match the
      checksums in its header}.
  }
}
\section{Origin}{
  Part of wfdb-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_annotations}} for annotation files;
  \code{\link{wfdbx_set_input_dir}} for the input and output directories;
  \code{\link{isigopen}} and \code{\link{getvec}} for the WFDB library
  functions.
}
\examples{
old <- setwd(tempdir())

## Write a two-signal record, "example", with a start time and a comment.
x <- cbind(round(200 * sin(2 * pi * (0:499) / 50)), 0:499 \%\% 100)
write_record("example", x, fs = 250, gains = 200, adcres = 16,
             names = c("sine", "ramp"), units = "mV",
             base_time = "08:45:00 01/01/2001",
             comments = "a synthetic record")

## Read the first 5 samples, in physical units.
rec <- read_record("example", sampto = 5, physical = TRUE)
rec$signals
rec$base_time
rec$comments

## Read 0.1 s of one signal, by name, in ADC units.
read_record("example", channels = "ramp", sampfrom = "0:1",
            sampto = "0:1.1")$signals[, 1]

## Read the header only.
h <- read_header("example")
h$nsamples
h$base_date
sapply(h$siginfo, function(s) s$desc)

setwd(old)
}
