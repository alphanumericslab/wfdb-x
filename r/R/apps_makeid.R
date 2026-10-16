# apps_makeid.R: makeid -- make an AHA-format ID block for a record.
#
# Copyright (C) 2003 George B. Moody (original C program, convert/makeid.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

app_makeid <- function(args = character(0)) {
  app_run(.makeid_main, c("makeid", args))
}

# A 16-bit integer in PDP-11 byte order (low byte first).
.pdp16 <- function(x) {
  x <- x %% 65536
  as.raw(c(x %% 256, x %/% 256))
}

# A 32-bit integer in PDP-11 order (high 16-bit word first).
.pdp32 <- function(x) c(.pdp16(floor(x / 65536)), .pdp16(x))

.makeid_main <- function(argv) {
  MAX_RECNAME <- 8                          # bytes of the record ID field
  SAMPLES_PER_BLOCK_SHIFT <- 7              # 128 two-signal samples per 512-byte block
  ANNOTS_PER_BLOCK_SHIFT <- 5               # 32 annotations per 512-byte block
  ID_TAIL_BYTES <- 464                      # unused bytes at the end of the block
  UNUSED_BYTES <- 6
  if (length(argv) < 3L) {
    ceprintf("usage: %s annotator record\n", argv[1L])
    cexit(1)
  }
  rec <- argv[3L]
  len <- nchar(rec, type = "bytes")
  if (len > MAX_RECNAME) {
    ceprintf("record name must be 8 characters or less\n")
    cexit(1)
  }
  r <- wfdbinit(rec, list(anninfo(argv[2L], WFDB_READ)), 2)
  if (r$stat < 1) cexit(2)
  nsamp <- r$si[[1L]]$nsamp
  # getann(0, &annot) once, then until it fails (an annotation time that C
  # leaves uninitialized is 0 here: see docs/KNOWN_C_BEHAVIORS.md)
  A <- .getann_bulk(0, Inf, noaux = TRUE)
  k <- length(A$time)
  if (k == 0) getann(0)                     # (the loop's call, which fails too)
  first <- if (k >= 1) A$time[1L] else 0
  last <- if (k >= 2) A$time[k] else 0
  nann <- max(k, 1)
  wfdbquit()
  nulls <- raw(ID_TAIL_BYTES)
  cout(charToRaw(rec))
  if (len < MAX_RECNAME) cout(nulls[seq_len(MAX_RECNAME - len)])
  ceprintf("%s\n", rec)
  cout(.pdp16(nann))
  ceprintf("%d annotations\n", nann)
  cout(nulls[seq_len(UNUSED_BYTES)])
  cout(.pdp32(0))
  ceprintf("Annotated segment begins at sample 0\n")
  cout(.pdp32(nsamp))
  ceprintf("Annotated segment ends at sample %ld\n", nsamp)
  blocks <- floor((nsamp + 127) / 2^SAMPLES_PER_BLOCK_SHIFT)
  cout(.pdp16(blocks))
  ceprintf("%d blocks of sample data\n", blocks)
  cout(nulls[seq_len(UNUSED_BYTES)])
  cout(.pdp32(first))
  ceprintf("First annotation is at sample %ld\n", first)
  cout(.pdp32(last))
  ceprintf("Last annotation is at sample %ld\n", last)
  blocks <- floor((nann + 31) / 2^ANNOTS_PER_BLOCK_SHIFT)
  cout(.pdp16(blocks))
  ceprintf("%d blocks of annotations\n", blocks)
  cout(nulls[seq_len(UNUSED_BYTES)])
  cout(nulls)
  0
}
