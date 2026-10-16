#!/usr/bin/env Rscript
# wfdbx.R: command-line driver of the wfdb-x tools for R.
#
#   Rscript wfdbx.R TOOL [ARGUMENTS ...]     (e.g. Rscript wfdbx.R rdsamp -r 100s)
#   Rscript wfdbx.R --list
#
# Works with the package installed (library(wfdbx); this file is then
# <library>/wfdbx/bin/wfdbx.R) and from the source tree (r/inst/bin/wfdbx.R:
# the sources r/R/*.R are loaded directly).  From the source tree, the
# loaded and byte-compiled sources are cached in an RDS file under
# $XDG_CACHE_HOME/R/wfdbx/ (default ~/.cache/R/wfdbx/; WFDBX_NO_CACHE=1
# disables the cache), keyed by the R version and the names, sizes and
# modification times of the source files.
#
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

local({
  args <- commandArgs(trailingOnly = TRUE)
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  script <- if (length(fa)) normalizePath(sub("^--file=", "", fa[1L]), mustWork = FALSE) else ""
  # The tools handle bytes: no multibyte locale, C collation.
  invisible(Sys.setlocale("LC_CTYPE", "C"))
  invisible(Sys.setlocale("LC_COLLATE", "C"))
  options(warn = -1)
  rdir <- file.path(dirname(dirname(dirname(script))), "R")
  if (nzchar(script) && file.exists(file.path(rdir, "cstd.R"))) {
    # source tree
    files <- sort(list.files(rdir, pattern = "\\.[Rr]$", full.names = TRUE), method = "radix")
    info <- file.info(files, extra_cols = FALSE)
    key <- paste(basename(files), info$size, format(as.numeric(info$mtime), digits = 15),
                 collapse = ";")
    key <- paste(R.version$major, R.version$minor, key)
    env <- NULL
    cache <- NULL
    if (!nzchar(Sys.getenv("WFDBX_NO_CACHE"))) {
      base <- Sys.getenv("XDG_CACHE_HOME")
      if (!nzchar(base)) base <- file.path(Sys.getenv("HOME"), ".cache")
      cache <- file.path(base, "R", "wfdbx",
                         paste0("src", gsub("[^A-Za-z0-9]+", "_", normalizePath(rdir)), ".rds"))
      if (file.exists(cache)) {
        obj <- tryCatch(readRDS(cache), error = function(e) NULL)
        if (is.list(obj) && identical(obj$key, key)) env <- obj$env
      }
    }
    if (is.null(env)) {
      env <- new.env(parent = globalenv())
      for (f in files) sys.source(f, envir = env, keep.source = FALSE)
      if (!is.null(cache)) {
        # byte-compile the functions, then save
        ok <- tryCatch({
          for (nm in ls(env, all.names = TRUE)) {
            fn <- get(nm, envir = env)
            if (is.function(fn) && !is.primitive(fn))
              assign(nm, compiler::cmpfun(fn), envir = env)
          }
          dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
          tmp <- paste0(cache, ".", Sys.getpid(), ".tmp")
          saveRDS(list(key = key, env = env), tmp, compress = FALSE)
          file.rename(tmp, cache)
        }, error = function(e) FALSE)
      }
    }
  } else {
    # installed package
    env <- asNamespace("wfdbx")
  }
  assign("driver", script, envir = get(".wfdb_io", envir = env))
  status <- env$cli_main(args)
  quit(save = "no", status = as.integer(status) %% 256L)
})
