# cli.R: the command-line dispatcher of the wfdb-x tools (used by
# inst/bin/wfdbx.R) and wfdbx_tool(), which runs a tool from R.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The tools have no built-in sampling frequency, gain, ADC resolution or units
# (see docs/DIVERGENCES.md); the helpers they share for this are below.

#' Names of the available tools (the functions app_<tool>).
wfdbx_tools <- function() {
  e <- environment(wfdbx_tools)
  t <- sub("^app_", "", ls(e, pattern = "^app_[a-z][a-z0-9]*$"))
  sort(setdiff(t, "run"), method = "radix")      # (app_run is the runner)
}

#' Run the wfdb-x tool `tool` with the arguments `args` (character vector,
#' without the program name) as the command line would; its output is
#' written to the standard output and error.  Returns the exit status.
wfdbx_tool <- function(tool, args = character(0)) {
  e <- environment(wfdbx_tool)
  if (!(tool %in% wfdbx_tools()))
    stop("unknown tool '", tool, "'")
  get(paste0("app_", tool), envir = e)(as.character(args))
}

#' Command-line entry point: args = c(TOOL, ARGUMENTS...).  Returns the exit
#' status.  R errors are reported as "wfdbx: error: ..." (status 1); set the
#' environment variable WFDBX_DEBUG to get the call stack.
cli_main <- function(args) {
  status <- 1
  calls <- NULL
  res <- tryCatch(withCallingHandlers({
    if (length(args) == 0L || args[1L] %in% c("-h", "--help")) {
      cerr("usage: wfdbx TOOL [ARGUMENTS ...]\n       wfdbx --list\n")
      return(if (length(args) == 0L) 1 else 0)
    }
    tool <- args[1L]
    if (tool == "--list") {
      cout(paste0(wfdbx_tools(), "\n", collapse = ""))
      cout()
      return(0)
    }
    if (tool == "--version") {
      cout(paste0("wfdb-x (WFDB ", wfdbversion(), ")\n"))
      cout()
      return(0)
    }
    e <- environment(cli_main)
    if (!grepl("^[a-z][a-z0-9]*$", tool) || tool == "run" ||
        !exists(paste0("app_", tool), envir = e, inherits = FALSE)) {
      cerr(paste0("wfdbx: unknown tool '", tool, "' (try 'wfdbx --list')\n"))
      return(1)
    }
    get(paste0("app_", tool), envir = e)(args[-1L])
  }, error = function(err) {
    if (nzchar(Sys.getenv("WFDBX_DEBUG"))) calls <<- sys.calls()
  }), wfdbx_exit = function(e) e$status, error = function(err) {
    cout()
    msg <- conditionMessage(err)
    if (!endsWith(msg, "\n")) msg <- paste0(msg, "\n")
    cerr(paste0("wfdbx: error: ", msg))
    if (!is.null(calls)) {
      cerr(paste0(vapply(calls, function(cl) paste(deparse(cl, nlines = 1L), collapse = ""), ""),
                  "\n", collapse = ""))
    }
    1
  })
  cout()
  if (is.null(res) || length(res) == 0L) 0 else res
}

# ---------------------------------------------------------------------------
# Helpers shared by the tools for the wfdb-x divergence "no built-in sampling
# frequency, gain, ADC resolution or units" (see docs/DIVERGENCES.md).

# The argument of the -F option (sampling frequency) of rdann, ann2rr,
# sortann and m2a: s (NULL if missing) must give a frequency > 0, as
# sscanf(s, "%lf") reads it; otherwise the tool stops (status 1).
.app_Fopt <- function(pname, s) {
  f <- 0
  if (!is.null(s)) {
    r <- csscanf(s, "%lf")
    if (r$n == 1L) f <- r$v[[1L]]
  }
  if (is.null(s) || r$n != 1L || isTRUE(f <= 0)) {
    ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
    cexit(1)
  }
  f
}

# Report that the sampling frequency of `record` is not specified (with a
# pointer to -F for the tools that have it) and stop with `status`.
.app_nofreq <- function(pname, record, status, useF = FALSE) {
  ceprintf("%s: sampling frequency of record %s is not specified%s\n", pname, record,
           if (useF) " (use -F)" else "")
  cexit(status)
}

# Report that signal s of `record` is uncalibrated and stop with `status`.
.app_uncalibrated <- function(pname, s, record, status) {
  ceprintf("%s: signal %d of record %s is uncalibrated\n", pname, s, record)
  cexit(status)
}

# Report that the ADC resolution of signal s of `record` is not specified
# and stop with `status`.
.app_noadcres <- function(pname, s, record, status) {
  ceprintf("%s: ADC resolution of signal %d of record %s is not specified\n",
           pname, s, record)
  cexit(status)
}

# The arguments of the -G (gain >= 0), -R (ADC resolution, 1-32 bits) and -U
# (units) options of ad2m, ahaecg2mit and wav2mit: s is the argument (NULL if
# missing); an invalid value stops the tool (status 1).
.app_Gopt <- function(pname, s) {
  r <- if (!is.null(s)) csscanf(s, "%lf") else list(n = 0L)
  if (r$n != 1L || isTRUE(r$v[[1L]] < 0)) {
    ceprintf("%s: gain (>= 0) must follow -G\n", pname)
    cexit(1)
  }
  r$v[[1L]]
}
.app_Ropt <- function(pname, s) {
  r <- if (!is.null(s)) csscanf(s, "%d") else list(n = 0L)
  if (r$n != 1L || r$v[[1L]] < 1 || r$v[[1L]] > 32) {
    ceprintf("%s: ADC resolution (1-32 bits) must follow -R\n", pname)
    cexit(1)
  }
  r$v[[1L]]
}
.app_Uopt <- function(pname, s) {
  if (is.null(s)) {
    ceprintf("%s: units must follow -U\n", pname)
    cexit(1)
  }
  s
}

# The checks of the required signal parameters of ad2m and ahaecg2mit (and,
# without the frequency and resolution, wav2mit), in the order of the C
# programs: freq (> 0), gain (NULL if not given), res (>= 1), units (needed
# unless the gain is 0).  NA skips a check.
.app_require_params <- function(pname, freq = NA, gain, res = NA, units) {
  if (!is.na(freq) && freq <= 0) {
    ceprintf("%s: the sampling frequency must be specified (-F)\n", pname)
    cexit(1)
  }
  if (is.null(gain)) {
    ceprintf("%s: the gain must be specified (-G)\n", pname)
    cexit(1)
  }
  if (!is.na(res) && res < 1) {
    ceprintf("%s: the ADC resolution must be specified (-R)\n", pname)
    cexit(1)
  }
  if (gain != 0 && is.null(units)) {
    ceprintf("%s: the units must be specified (-U)\n", pname)
    cexit(1)
  }
  invisible(NULL)
}

# wfdb-x: legacy mode (original behavior): the help text h of a tool without
# its lines `added` (those added by wfdb-x), as the original tool prints it.
.app_help_text <- function(h, added) if (wfdbx_get_legacy()) h[!(h %in% added)] else h
