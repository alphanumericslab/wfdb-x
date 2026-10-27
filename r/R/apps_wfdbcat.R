# apps_wfdbcat.R: wfdbcat -- copy WFDB files to the standard output.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/wfdbcat.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, each file is read from where it is named (the input directory, a
# full path or a URL), not found by a search of the WFDB path; see
# docs/DIVERGENCES.md.
#
# Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_wfdbcat <- function(args = character(0)) {
  app_run(.wfdbcat_main, c("wfdbcat", args))
}

.wfdbcat_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  if (argc < 2L || (argc == 2L && argv[2L] == "-h")) {
    ceprintf("usage: %s FILE [FILE ...]\n", pname)
    cexit(1)
  }
  for (i in 2:argc) {
    f <- wfdb_open(argv[i], NULL, WFDB_READ)
    if (is.null(f)) {
      ceprintf("%s: `%s' not found\n", pname, argv[i])
    } else {
      repeat {
        b <- wf_read(f, 1048576L)           # (1 MiB at a time)
        if (length(b) == 0L) break
        cout(b)
      }
      wf_close(f)
    }
  }
  0
}
