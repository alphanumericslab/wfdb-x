\name{wfdbx_tool}
\alias{wfdbx_tool}
\alias{wfdbx_tools}
\title{Run the WFDB Command-Line Tools}
\description{
  \code{wfdbx_tool} runs one of the WFDB command-line tools (such as
  \command{rdsamp}, \command{rdann} or \command{wfdbdesc}) with the given
  arguments, exactly as the C program would run from a shell.
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
  The tools accept the options of the WFDB Software Package 10.7.0 and
  produce the same output, byte for byte; see the \emph{WFDB Applications
  Guide} (\url{https://physionet.org/physiotools/wag/}) or run a tool with
  the option \option{-h} for its usage.  Records and annotation files are
  searched for in the WFDB path (see \code{\link{getwfdb}}).

  On Unix-alikes, the output of a tool is written directly to the standard
  output and standard error of the R process, not through R connections:
  it appears in a terminal, but it is not captured by \code{sink} or
  \code{capture.output}, and may not appear in the console of a graphical
  front end.  To capture the output, run the tool in a separate process
  with the driver script installed with the package:
  \preformatted{Rscript <library>/wfdbx/bin/wfdbx.R TOOL [ARGUMENTS ...]
Rscript <library>/wfdbx/bin/wfdbx.R --list}
  where \file{<library>/wfdbx/bin/wfdbx.R} is given by
  \code{system.file("bin", "wfdbx.R", package = "wfdbx")}.

  \code{wfdbx_tool} signals an error if \code{tool} is not the name of a
  tool.
}
\seealso{
  \code{\link{read_record}} and \code{\link{read_annotations}} to read
  records and annotation files into R objects.
}
\examples{
wfdbx_tools()

old <- setwd(tempdir())
write_record("example", cbind(0:9, 9:0), fs = 100, gains = 200, adcres = 16, units = "mV",
             names = c("a", "b"))
wfdbx_tool("wfdbdesc", "example")
status <- wfdbx_tool("rdsamp", c("-r", "example", "-t", "s3"))
status
setwd(old)

## the same from a separate R process, capturing the output
\dontrun{
driver <- system.file("bin", "wfdbx.R", package = "wfdbx")
out <- system2("Rscript", c(driver, "rdsamp", "-r", "100s", "-t", "s5"),
               stdout = TRUE)
}
}
