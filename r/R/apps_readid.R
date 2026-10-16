# apps_readid.R: readid -- read an AHA-format ID block (from the standard
# input) and print the record name and the lengths of its files.
#
# Copyright (C) 1983-2005 George B. Moody (original C program,
# convert/readid.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
