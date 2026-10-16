# apps_wfdbcat.R: wfdbcat -- copy WFDB files (found in the WFDB path) to the
# standard output.
#
# Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
# revised 2018 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
