# run_tests.R: unit tests of the wfdbx package (base R only).
#
#   Rscript r/tests/run_tests.R [PATTERN]
#
# Runs the files unit/test_*.R (those whose name matches PATTERN, if
# given).  From the source tree, the sources r/R/*.R are loaded directly;
# otherwise (e.g. under R CMD check) the installed package is used.  Each
# test file is evaluated in an environment whose parent is the package
# environment, so that internal functions are visible, with the helpers
# check(), expect_equal(), expect_error() and the variables .mode
# ("source" or "installed") and .rdir (the R/ directory, source mode).
# Prints one line per test file (ok/FAIL) and one per failed check; exits
# with status 1 if any check failed.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

local({
  ca <- commandArgs(FALSE)
  fa <- grep("^--file=", ca, value = TRUE)
  script <- if (length(fa)) sub("^--file=", "", fa[1L]) else {
    k <- match("-f", ca)
    if (!is.na(k) && k < length(ca)) ca[k + 1L] else ""
  }
  here <- if (nzchar(script) && file.exists(script)) dirname(normalizePath(script)) else getwd()
  pattern <- commandArgs(trailingOnly = TRUE)
  pattern <- if (length(pattern)) pattern[1L] else ""
  rdir <- file.path(dirname(here), "R")
  if (file.exists(file.path(rdir, "cstd.R"))) {
    mode <- "source"
    env <- new.env(parent = globalenv())
    for (f in sort(list.files(rdir, pattern = "\\.[Rr]$", full.names = TRUE), method = "radix"))
      sys.source(f, envir = env, keep.source = FALSE)
  } else {
    mode <- "installed"
    rdir <- ""
    env <- asNamespace("wfdbx")
  }
  invisible(Sys.setlocale("LC_COLLATE", "C"))
  counts <- new.env()
  counts$pass <- 0
  counts$fail <- 0
  report_fail <- function(label, detail = "") {
    counts$fail <- counts$fail + 1
    counts$file_fail <- counts$file_fail + 1
    cat("FAIL ", label, if (nzchar(detail)) paste0(": ", detail), "\n", sep = "")
  }
  helpers <- list(
    check = function(cond, label) {
      if (isTRUE(cond)) counts$pass <- counts$pass + 1 else report_fail(label)
      invisible(isTRUE(cond))
    },
    expect_equal = function(got, exp, label) {
      ok <- identical(got, exp)
      if (ok) counts$pass <- counts$pass + 1 else
        report_fail(label, paste0("got ", paste(deparse(got), collapse = " "),
                                  ", expected ", paste(deparse(exp), collapse = " ")))
      invisible(ok)
    },
    expect_error = function(expr, label) {
      ok <- tryCatch({
        expr
        FALSE
      }, error = function(e) TRUE)
      if (ok) counts$pass <- counts$pass + 1 else report_fail(label, "no error")
      invisible(ok)
    })
  files <- sort(list.files(file.path(here, "unit"), pattern = "^test_.*\\.R$", full.names = TRUE),
                method = "radix")
  if (nzchar(pattern)) files <- files[grepl(pattern, basename(files))]
  for (f in files) {
    tenv <- new.env(parent = env)
    for (nm in names(helpers)) assign(nm, helpers[[nm]], envir = tenv)
    assign(".mode", mode, envir = tenv)
    assign(".rdir", rdir, envir = tenv)
    counts$file_fail <- 0
    p0 <- counts$pass
    owd <- getwd()
    err <- tryCatch({
      # one evaluation of the whole file, so that on.exit() runs at its end
      exprs <- parse(f, keep.source = FALSE)
      eval(as.call(c(as.name("{"), as.list(exprs))), tenv)
      NULL
    }, error = function(e) conditionMessage(e))
    setwd(owd)
    if (!is.null(err)) report_fail(basename(f), paste("error:", err))
    cat(if (counts$file_fail == 0) "ok   " else "FAIL ", basename(f), " (",
        counts$pass - p0, " checks passed)\n", sep = "")
  }
  cat(counts$pass, "checks passed,", counts$fail, "failed (", mode, ")\n")
  if (counts$fail > 0) quit(save = "no", status = 1)
})
