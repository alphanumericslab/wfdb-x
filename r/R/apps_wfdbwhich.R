# apps_wfdbwhich.R: wfdbwhich -- find a WFDB file and print its pathname.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/wfdbwhich.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, the file is looked for only where it is named (the input
# directory, a full path or a URL), not by a search of the WFDB path; see
# docs/DIVERGENCES.md.
#
# Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1999 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_wfdbwhich <- function(args = character(0)) {
  app_run(.wfdbwhich_main, c("wfdbwhich", args))
}

.wfdbwhich_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  status <- 0
  if (argc == 2L && argv[2L] == "-h") argc <- 0L
  if (argc == 2L) {
    filename <- wfdbfile(argv[2L], NULL)
    if (!is.null(filename)) {
      cprintf("%s\n", filename)
    } else {
      ceprintf("`%s' not found\n", argv[2L])
      ceprintf("(WFDB path = %s)\n", getwfdb())
      status <- 2
    }
  } else if (argc == 3L) {
    wfdbquiet()
    isigopen(argv[3L], 0)
    filename <- wfdbfile(argv[2L], argv[3L])
    if (!is.null(filename)) {
      cprintf("%s\n", filename)
    } else {
      ceprintf("No file of type `%s' found for record `%s'\n", argv[2L], argv[3L])
      ceprintf("(WFDB path = %s)\n", getwfdb())
      status <- 2
    }
  } else if (argc != 4L || argv[2L] != "-r") {
    ceprintf("usage: %s [-r RECORD ] FILENAME\n", pname)
    ceprintf(" -or-  %s FILE-TYPE RECORD\n", pname)
    status <- 1
  } else {
    isigopen(argv[3L], 0)
    filename <- wfdbfile(argv[4L], NULL)
    if (!is.null(filename)) {
      cprintf("%s\n", filename)
    } else {
      ceprintf("`%s' not found\n", argv[4L])
      ceprintf("(WFDB path = %s)\n", getwfdb())
      status <- 2
    }
  }
  status
}
