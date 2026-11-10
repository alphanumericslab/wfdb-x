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
             samps_per_frame = NULL, dir = NULL, legacy = FALSE,
             metadata = NULL)
}
\arguments{
  \item{record}{\code{read_record}, \code{read_header}: the record name, without the \code{.hea} extension (a
    trailing \code{".hea"} is also accepted): a full path, absolute
    (\code{"/data/mitdb/100"}) or in the home directory
    (\code{"~/Documents/100s"}), used as given; a relative path
    (\code{"100s"}, \code{"data/100s"}), read from the input directory if
    one is set (see \code{\link{wfdbx_set_input_dir}}), otherwise from the
    current directory; or a URL
    (\code{"https://physionet.org/files/mitdb/1.0.0/100"}), read only if
    network access is on.  A name with another
    extension, such as \code{"rec.edf"}, is read as an EDF file.

    \code{write_record}: the record name, without the \code{.hea}
    extension (a trailing \code{".hea"} is removed, as by the readers):
    a plain name (\code{"rec"}) or a relative path
    (\code{"data/rec"}), created in the output directory if one is set
    (see \code{\link{wfdbx_set_output_dir}}), otherwise in the current
    directory, missing directories included; or a full path, absolute or
    in the home directory (\code{"~/Documents/rec"}), used as given.  With
    a path, the files are created in that directory, and the header names
    the record and its signal file without the path (\code{"rec"},
    \code{"rec.dat"}), so that the record opens under any path that leads
    to it (in legacy mode, as in the original, the header gives the name
    with its path).  A URL cannot be written.}
  \item{channels}{the signals to read: signal numbers, starting at 0, or
    signal names (by name, as in \code{names}).  The default,
    \code{NULL}, reads all signals.}
  \item{sampfrom, sampto}{the first sample to read, and the sample after
    the last one.  Each is a sample number or a time string, such as
    \code{"0:10"} (10 seconds), \code{"s1000"} (sample 1000) or \code{"e"}
    (the end of the record); see \code{\link{strtim}}.  A sample number
    must be a whole number: a fraction, \code{NA}, \code{NaN} or an
    infinite value is an error (\samp{sampfrom must be a whole number}),
    and so is a negative \code{sampfrom}, and anything other than one
    number or one time string, such as a list (\samp{sampfrom must be a
    sample number or a time string}).
    By default (\code{sampto = NULL}) the whole record is read.}
  \item{physical}{\code{read_record}: if \code{TRUE}, return the samples
    in physical units, \code{(sample - baseline) / gain}, instead of ADC
    units.  \code{write_record}: if \code{TRUE}, \code{signals} are in
    physical units.  They are converted to ADC units with \code{gains} and
    \code{baselines} and rounded, and \code{NA} is written as an invalid
    sample.  An infinite value, or one whose ADC value is beyond the range
    of a 32-bit integer, is an error.}
  \item{highres}{if \code{TRUE}, read a multi-frequency record at the
    highest sampling frequency of its signals.  Samples of the slower
    signals are repeated.  By default such a record is read at its frame
    rate, and the samples of the faster signals are averaged.}
  \item{pad}{if \code{TRUE}, replace each invalid sample by the previous
    valid sample of the same signal.

    \code{highres} and \code{pad} set the getvec mode
    (\code{\link{setgvmode}}) for this call only: the mode in force before
    the call is restored afterwards, also after an error.}
  \item{input_dir}{the input directory for this call only (optional): a
    local directory, a \code{~} path or a URL, under which relative record
    names are read.  It does not apply to full paths or URLs.
    \code{NULL}, the default, keeps the current setting (see
    \code{\link{wfdbx_set_input_dir}}).}
  \item{network}{\code{TRUE} to allow reading URLs for this call only,
    \code{FALSE} to forbid it.  \code{NULL}, the default, keeps the
    current setting, which is off unless you turned it on.}
  \item{legacy}{if \code{TRUE}, behave as the original WFDB package for
    this call (see \code{\link{wfdbx_set_legacy}}).}
  \item{checksum_warning}{if \code{TRUE}, the default, \code{read_record}
    warns when the samples do not match the checksums in the header.
    \code{FALSE} turns the warning off.}
  \item{signals}{the samples to write: a numeric matrix with one row per
    sample and one column per signal.  A vector (or a one-dimensional
    array) is written as a single signal; an array of more than two
    dimensions is an error.  For a multi-frequency record, see \code{samps_per_frame}.
    In ADC units, the samples must be integers within the range of a
    32-bit integer, and \code{NA} is written as an invalid sample.}
  \item{fs}{the sampling frequency in Hz, finite and greater than 0.  For a
    multi-frequency record, this is the frame rate.}
  \item{fmt}{the storage format of the signal file, such as 16, 212 or
    516 (FLAC); see \code{\link{WFDB_FMT_LIST}}.  All signals have the
    same format.}
  \item{gains}{the gain of each signal, in ADC units per physical unit
    (finite; negative gains are allowed).  A gain of 0 marks a signal as uncalibrated.  This is only allowed when
    \code{signals} are in ADC units.}
  \item{baselines}{the baseline of each signal: the ADC value of physical
    zero, a whole number within the range of a 32-bit integer.  By
    default (or \code{NA}) it equals the ADC zero.}
  \item{adczeros}{the ADC value at the middle of the converter's range, a
    whole number within the range of a 32-bit integer (\code{NA}: 0).}
  \item{adcres}{the ADC resolution of each signal, in bits: a whole
    number, at least 1.}
  \item{units}{the physical units of each signal, such as \code{"mV"}, as
    a character vector or a list.  They are required for every signal
    whose gain is not 0.  Text is written as its bytes, one byte per
    character (see Details).}
  \item{names}{the description of each signal, as a character vector or a
    list.}
  \item{base_time}{the start time of the record, as \code{"hh:mm:ss"} or
    \code{"hh:mm:ss dd/mm/yyyy"}.  By default the header gives none.  A
    time that cannot be parsed is an error.}
  \item{comments}{a character vector of info strings to add to the end of
    the header.  The header lines that begin with \samp{#} after the
    record line are its info strings.}
  \item{metadata}{\samp{Key: value} entries to write to the header, after
    the comments, as \samp{# Key: value} (through \code{\link{putinfo}}):
    a named list or a named character vector, such as
    \code{list(Age = "63", Sex = "F")} or the result of
    \code{\link{read_metadata}}.  The keys and values follow the rules of
    \code{\link{set_metadata}}; a \code{NULL} or \code{NA} value is an
    error, no two keys may differ only in letter case, and none may be the
    key of an entry in \code{comments}.  These are checked before any file
    is created.  \code{NULL}, the default, writes none.  Metadata often
    holds information about patients; it is stored as given, without
    de-identification.}
  \item{samps_per_frame}{for a multi-frequency record, the number of
    samples per frame of each signal.  \code{signals} then has one row per
    frame and \code{sum(samps_per_frame)} columns: the samples of the
    first signal, then those of the second, and so on.}
  \item{dir}{the directory (which must exist) in which to create the
    files, for this call only.  \code{record} must then be a plain name,
    without a directory, and the record opens from that directory under
    its plain name.}
}
\details{
  In \code{write_record}, you must give \code{fs}, \code{gains},
  \code{adcres} and the \code{units} of each calibrated signal: there are
  no defaults.  The arguments that describe the signals (\code{fmt},
  \code{gains}, \code{baselines}, \code{adczeros}, \code{adcres},
  \code{units}, \code{names}) take one value for all signals, or one value
  per signal; any other length is an error.  The record name must not be
  empty, and at least one signal is required.  All the arguments are
  checked before any file is created or changed.  The signal file is
  \file{\var{record}.dat}.  Existing files of the same name are replaced:
  both files are written to temporary files
  (\file{.\var{name}.\var{XXXXXXXX}.tmp}, created with owner-only
  permissions) in the directory of their destinations, which replace the
  existing files only when both are complete, with the permissions of the
  files they replace (or, for new files, 0666 less the umask).  An error
  leaves the existing files as they were, and no temporary file is left.
  A destination that is a symbolic link stays one: the file it leads to
  is replaced.  A destination that exists and is not a regular file (a
  device, a FIFO) is written directly.

  Text (the record name, \code{names}, \code{units}, \code{comments}) is
  written as its bytes, one byte per character (Latin-1).  A string of an
  R session in UTF-8 that holds a character beyond U+00FF, which would be
  written as several bytes, is an error.

  The info strings of a header (\code{comments}) are the lines that begin
  with \samp{#} after the record line.  The record line is found as the
  header parser finds it: the first line that holds something other than
  spaces, tabs, CRs and LFs and does not begin (after them) with
  \samp{#}; comments and empty or blank lines before it are not info
  strings.  (In legacy mode, the comments are those of the C function
  \code{getinfo}, which takes the first line that does not begin with
  \samp{#} for the record line; see \code{\link{getinfo}}.)

  A time string such as \code{"0:10"} needs the sampling frequency, and
  \code{physical = TRUE} needs the gain of each selected signal.  A record
  that does not give them cannot be read that way.

  Each call closes anything opened with the WFDB library functions, as
  \code{\link{wfdbquit}} does, also when it stops with an error.
  The getvec mode (\code{\link{getgvmode}}) and the time resolution of
  output annotators (\code{\link{getafreq}}) are left as they were, also
  after an error (opening an EDF record sets both, as in C).
}
\value{
  \code{read_record} returns a list with these elements:
  \item{signals}{a numeric matrix with one row per sample and one column
    per signal read, in ADC units or physical units.  Invalid samples are
    \code{\link{WFDB_INVALID_SAMPLE}} (-32768) in ADC units, and
    \code{NA} in physical units.}
  \item{fs}{the sampling frequency in Hz, 0 if the header gives none.}
  \item{names}{the description of each signal, without the white space
    that a header may put at either end of it.}
  \item{units}{the physical units of each signal, as a list.  An element
    is \code{NULL} when the header gives no units.}
  \item{gains, baselines}{the gain and baseline of each signal.  A gain of
    0 means uncalibrated.}
  \item{siginfo}{the full signal specifications: one
    \code{\link{siginfo}} list per signal (its \code{desc} without the
    white space at either end).}
  \item{name}{the record name.}
  \item{sampfrom}{the number of the first sample returned.}
  \item{base_time}{the start time and date as text, to the second, such
    as \code{"[14:00:03 21/06/2024]"}.}
  \item{base_time_ms}{the start time in milliseconds after midnight, such
    as \code{50403500} for 14:00:03.500.}
  \item{base_date}{the start date as \code{c(year, month, day)}.}
  \item{comments}{the info strings of the header: its lines that begin
    with \samp{#} after the record line (see Details), without the
    \samp{#}.}
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
  \code{base_time}, \code{base_time_ms}, \code{base_date},
  \code{comments} and \code{metadata}: the \samp{Key: value} entries of
  the header file (\file{.hea} only, not a \file{.info} file), as
  \code{\link{read_metadata}} returns them (a named character vector; an
  empty one for an EDF file, which has no header file, and for a header
  read from the standard input, \code{"-"}).  The others have
  the same meaning as in the result of \code{read_record}.

  \code{write_record} returns \code{NULL}, invisibly.
}
\section{Errors and warnings}{
  \itemize{
    \item A record that cannot be read or written stops with an error,
      such as \samp{can't read record REC}.
    \item A signal file that is shorter than its header says, or that
      cannot be read (a decoder or I/O error, a segment that cannot be
      opened), stops with the error \samp{can't read signal data of record
      REC (getvec status -3)}, also when the samples do not match the
      checksums either; no incomplete frame is ever returned (WFDB-x).
      Reading stops at \code{sampto}, so the frames before the end of a
      truncated file can be read with it.  Nothing is allocated from the
      length that the header gives (a header may give far more samples
      than its signal files hold): the matrix grows as the frames are
      read.
    \item Invalid arguments, and a value the operation needs but the
      record does not give, stop with an error.
    \item In \code{write_record}, each \code{samps_per_frame} value must
      be an integer >= 1 (\samp{samps_per_frame must hold integers >= 1}),
      and \code{signals} must have \code{sum(samps_per_frame)} columns
      (\samp{signals has N columns, but samps_per_frame adds up to M});
      a vector of per-signal values must have one value per signal, and
      the samples must be valid (see \code{signals} and
      \code{physical}); an invalid \code{metadata} stops with an error of
      class \code{"wfdbx_argument_error"}.  The checks, in order (WFDB-x
      1.2.2): \samp{record name must not be empty}; \samp{record name 'X'
      has a character that is not Latin-1 (one byte per character)};
      \samp{signals must be a 1-D or 2-D array}; the signals,
      \code{samps_per_frame}, the per-signal lengths and the gains;
      \samp{ADC resolution(s) must be specified} (an ADC resolution
      missing or below 1) and \samp{adcres must be whole numbers within
      the range of a 32-bit integer} (a fraction, \code{NaN} or text); the
      units, the frequency, the gains and \code{base_time}; then, in
      legacy mode too, \samp{adcres (adczeros, baselines) must be whole
      numbers within the range of a 32-bit integer}; \samp{signal name 'X'
      has a character that is not Latin-1 (one byte per character)} and
      \samp{units 'X' ...}; the samples and the format; \samp{comment 'X'
      ...}; and the metadata.  All the arguments are checked first, and
      no file is created or changed if one is invalid.  Whatever happens,
      \code{write_record} closes the output signals
      (\code{\link{wfdbquit}}) and removes its temporary files before it
      returns.
    \item When the signal file or the header cannot be written completely
      (for example, when the disk is full), or the temporary files cannot
      replace the existing files, \code{write_record} stops with the error
      \samp{write error on record REC}, after the messages of the library
      (such as \samp{osigclose: write error in signal group 0}), and the
      existing files are left as they were.
    \item \code{read_header} warns, as \code{\link{read_metadata}} does,
      for each key of which the header has more than one entry.
    \item When the samples do not match the checksums in the header,
      \code{read_record} returns all of them and issues the warning
      \samp{checksum error in record REC: the signal data do not match the
      checksums in its header}.
  }
}
\section{Origin}{
  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_annotations}} for annotation files;
  \code{\link{read_metadata}} for the \samp{Key: value} entries of a
  header;
  \code{\link{wfdbx_set_input_dir}} for the input and output directories;
  \code{\link{isigopen}} and \code{\link{getvec}} for the WFDB library
  functions.
}
\examples{
old <- setwd(tempdir())

## Write a two-signal record, "example", with a start time, a comment
## and two metadata entries.
x <- cbind(round(200 * sin(2 * pi * (0:499) / 50)), 0:499 \%\% 100)
write_record("example", x, fs = 250, gains = 200, adcres = 16,
             names = c("sine", "ramp"), units = "mV",
             base_time = "08:45:00 01/01/2001",
             comments = "a synthetic record",
             metadata = list(Age = "63", Sex = "F"))

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
h$metadata

setwd(old)
}
