# apps_wfdbwhich.R: wfdbwhich -- find a WFDB file and print its pathname.
#
# Copyright (C) 1999 George B. Moody (original C program, app/wfdbwhich.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
