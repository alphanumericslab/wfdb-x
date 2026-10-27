\name{wfdbx_tool}
\alias{wfdbx_tool}
\alias{wfdbx_tools}
\title{Run the WFDB Command-Line Tools}
\description{
  \code{wfdbx_tool} runs one of the WFDB command-line tools (such as
  \command{rdsamp}, \command{rdann} or \command{wfdbdesc}) with the given
  arguments, as you would run it from a shell.
  \code{wfdbx_tools} lists the available tools.
}
\usage{
wfdbx_tool(tool, args = character(0))
wfdbx_tools()
}
\arguments{
  \item{tool}{the name of the tool, a character string (one of
    \code{wfdbx_tools()}).}
  \item{args}{the command-line arguments of the tool, as a character
    vector (one element per argument, without the program name).}
}
\value{
  \code{wfdbx_tool} returns the exit status of the tool (0 on success), as
  a number.  \code{wfdbx_tools} returns a character vector of the names of
  the available tools, in alphabetical order.
}
\details{
  The tools have the options and output of the WFDB Software Package
  10.7.0 tools, which are described in the \emph{WFDB Applications Guide}
  (\url{https://physionet.org/physiotools/wag/}).  Run a tool with the
  option \option{-h} for its usage.  Records and annotation files are read
  and written as described in \code{\link{wfdbx_set_input_dir}}.  Tools
  that write signal parameters require them as options: for example,
  \command{wrsamp} with \option{-o} needs \option{-F} (frequency),
  \option{-G} (gain), \option{-R} (ADC resolution) and \option{-U}
  (units).

  The output of a tool goes directly to the standard output and error of
  the R process.  It appears in a terminal, but \code{sink} and
  \code{capture.output} do not capture it, and a graphical console may
  not show it.  To capture the output, run the tool in a separate process
  with the driver script installed with the package:
  \preformatted{Rscript <library>/wfdbx/bin/wfdbx.R TOOL [ARGUMENTS ...]
Rscript <library>/wfdbx/bin/wfdbx.R --list}
  where \code{system.file("bin", "wfdbx.R", package = "wfdbx")} gives
  the path of \file{wfdbx.R}.

  \code{wfdbx_tool} stops with an error if \code{tool} is not the name of
  a tool.
}
\section{Origin}{
  The tools are R translations of the programs of the WFDB Software
  Package 10.7.0; the source file of each tool names its C original and
  its changes.

  Part of WFDB-x; not in the original WFDB package.
}
\seealso{
  \code{\link{read_record}} and \code{\link{read_annotations}} to read
  records and annotation files into R objects.
}
\examples{
wfdbx_tools()

old <- setwd(tempdir())
## "example" is a record written by this example.
write_record("example", cbind(0:9, 9:0), fs = 100, gains = 200, adcres = 16, units = "mV",
             names = c("a", "b"))
wfdbx_tool("wfdbdesc", "example")
status <- wfdbx_tool("rdsamp", c("-r", "example", "-t", "s3"))
status
setwd(old)

## Run a tool in a separate R process, and capture its output.  100s is
## the sample record included with WFDB-x (the first minute of record 100
## of the MIT-BIH Arrhythmia Database), in the tests/data directory of a
## copy of the repository; replace the path with that directory.
\dontrun{
driver <- system.file("bin", "wfdbx.R", package = "wfdbx")
out <- system2("Rscript", c(driver, "rdsamp", "-r", "100s", "-t", "s5"),
               stdout = TRUE, env = "WFDBX_INPUT_DIR=wfdb-x/tests/data")
}
}
