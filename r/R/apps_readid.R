# apps_readid.R: readid -- read an AHA-format ID block (from the standard
# input) and print the record name and the lengths of its files.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/readid.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/readid.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2005 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_readid <- function(args = character(0)) {
  app_run(.readid_main, c("readid", args))
}

.readid_main <- function(argv) {
  ID_BYTES <- 24                            # record ID field read with "%s"
  SKIP_BYTES <- 14                          # bytes between the two block counts
  BLOCK_BYTES <- 512                        # AHA logical block size
  if (length(argv) < 3L) {
    ceprintf("usage: %s data-block-size annot-block-size\n", argv[1L])
    cexit(1)
  }
  dasize <- max(atoi(argv[2L]), 1)
  ansize <- max(atoi(argv[3L]), 1)
  data <- stdin_bytes()
  pos <- 0
  rd <- function(n) {                       # fread of n bytes
    m <- max(min(n, length(data) - pos), 0)
    b <- data[pos + seq_len(m)]
    pos <<- pos + m
    b
  }
  # g16: a 16-bit integer, low byte first (a byte past the end of the
  # input is EOF, whose low 8 bits are all ones)
  g16 <- function() {
    b <- c(as.integer(rd(2)), 255L, 255L)
    b[1L] + 256 * b[2L]
  }
  # (sscanf(buf, "%s", name): the whole first word, see
  # docs/KNOWN_C_BEHAVIORS.md; name stays empty if there is none)
  r <- csscanf(rd(ID_BYTES), "%s")
  name <- if (r$n == 1) r$v[[1L]] else ""
  dcount <- (g16() * BLOCK_BYTES + dasize - 1) %/% dasize
  rd(SKIP_BYTES)
  acount <- (g16() * BLOCK_BYTES + ansize - 1) %/% ansize
  cprintf("%s %ld %ld\n", name, dcount, acount)
  0
}
