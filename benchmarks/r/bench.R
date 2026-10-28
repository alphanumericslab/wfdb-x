#!/usr/bin/env Rscript
# bench.R: benchmark driver for the R implementation of WFDB-x.
#
#     Rscript benchmarks/r/bench.R OP DATADIR REPS
#
# See benchmarks/README.md for the operations and the output (one JSON line).
# WFDB-x is loaded from the source tree (r/R/*.R) as r/inst/bin/wfdbx.R loads
# it, with the same cache of the byte-compiled sources.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# The sources r/R/*.R, loaded into an environment: from the cache of
# r/inst/bin/wfdbx.R when it is up to date, else sourced and byte-compiled
# (and the cache written), as wfdbx.R does.
load_wfdbx <- function(rdir) {
  files <- sort(list.files(rdir, pattern = "\\.[Rr]$", full.names = TRUE), method = "radix")
  info <- file.info(files, extra_cols = FALSE)
  key <- paste(basename(files), info$size, format(as.numeric(info$mtime), digits = 15),
               collapse = ";")
  key <- paste(R.version$major, R.version$minor, key)
  cache <- NULL
  if (!nzchar(Sys.getenv("WFDBX_NO_CACHE"))) {
    base <- Sys.getenv("XDG_CACHE_HOME")
    if (!nzchar(base)) {
      home <- Sys.getenv("HOME")
      user <- Sys.info()[["user"]]
      pw <- tryCatch(suppressWarnings(readLines("/etc/passwd")), error = function(e) character(0))
      pw <- strsplit(pw[startsWith(pw, paste0(user, ":"))], ":", fixed = TRUE)
      if (length(pw) && length(pw[[1L]]) >= 6L && nzchar(pw[[1L]][6L])) home <- pw[[1L]][6L]
      base <- file.path(home, ".cache")
    }
    cache <- file.path(base, "R", "wfdbx",
                       paste0("src", gsub("[^A-Za-z0-9]+", "_", normalizePath(rdir)), ".rds"))
    if (file.exists(cache)) {
      obj <- tryCatch(readRDS(cache), error = function(e) NULL)
      if (is.list(obj) && identical(obj$key, key)) return(obj$env)
    }
  }
  env <- new.env(parent = globalenv())
  for (f in files) sys.source(f, envir = env, keep.source = FALSE)
  for (nm in ls(env, all.names = TRUE)) {
    fn <- get(nm, envir = env)
    if (is.function(fn) && !is.primitive(fn))
      assign(nm, compiler::cmpfun(fn), envir = env)
  }
  if (!is.null(cache)) {
    tryCatch({
      dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
      tmp <- paste0(cache, ".", Sys.getpid(), ".tmp")
      saveRDS(list(key = key, env = env), tmp, compress = FALSE)
      file.rename(tmp, cache)
    }, error = function(e) FALSE)
  }
  env
}

# Time in seconds, to the microsecond.  (Base R has no monotonic clock, and
# proc.time() counts in milliseconds.)
now <- function() as.numeric(Sys.time())

# A number as JSON: integers without exponent, others to 15 significant digits.
json_num <- function(x) {
  if (x == round(x) && abs(x) < 2^53) format(x, scientific = FALSE)
  else format(x, digits = 15, scientific = FALSE)
}

main <- function(args) {
  if (length(args) != 3L) {
    cat("usage: Rscript bench.R OP DATADIR REPS\n", file = stderr())
    return(2L)
  }
  op <- args[1L]
  reps <- as.integer(args[3L])
  ops <- c("read_long", "read_long_phys", "read_mimic", "read_wide", "write_long",
           "read_ann", "write_ann")
  if (!(op %in% ops)) {
    cat("unknown operation ", op, "\n", sep = "", file = stderr())
    return(2L)
  }
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  script <- normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1L]), fixed = TRUE))
  w <- load_wfdbx(file.path(dirname(dirname(dirname(script))), "r", "R"))

  w$wfdbx_set_input_dir(args[2L])
  out <- tempfile("wfdbx-bench-")
  dir.create(out)
  on.exit(unlink(out, recursive = TRUE))
  if (op == "write_long") src <- w$read_record("long")
  if (op == "write_ann") ann <- w$read_annotations("long", "atr")
  run <- switch(op,
    read_long = function() sum(w$read_record("long")$signals),
    read_long_phys = function()
      round(sum(w$read_record("long", physical = TRUE)$signals, na.rm = TRUE), 3),
    read_mimic = function() sum(w$read_record("mimic")$signals),
    read_wide = function() sum(w$read_record("wide")$signals),
    write_long = function() {
      w$write_record("out", src$signals, src$fs, fmt = 16, gains = src$gains,
                     adcres = 16, units = src$units, dir = out)
      file.size(file.path(out, "out.dat"))
    },
    read_ann = function() nrow(w$read_annotations("long", "atr")),
    write_ann = function() {
      w$write_annotations("out", "atr", ann$sample, code = ann$code, aux = ann$aux,
                          dir = out)
      file.size(file.path(out, "out.atr"))
    })
  t <- now()
  check <- run()
  first <- now() - t
  times <- numeric(reps)
  for (i in seq_len(reps)) {
    t <- now()
    run()
    times[i] <- now() - t
  }
  cat(sprintf('{"op": "%s", "first": %s, "best": %s, "times": [%s], "check": %s}\n',
              op, json_num(first), json_num(min(times)),
              paste(vapply(times, json_num, ""), collapse = ", "), json_num(check)))
  0L
}

quit(save = "no", status = main(commandArgs(trailingOnly = TRUE)))
