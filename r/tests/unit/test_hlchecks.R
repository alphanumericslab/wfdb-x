# Tests of the corrections of WFDB-x 1.2.2 to the high-level functions
# (highlevel.R, highlevel_annot.R, check.R, metadata.R, signal.R; port of
# the 1.2.2 tests of python/tests/test_signals.py and test_annotations.py):
# a truncated signal file is a read error even where a checksum is
# verified, and no incomplete frame is returned; read_record allocates no
# more than it reads; write_record and write_annotations check every
# argument before any file is touched, and write through temporary files
# (created owner-only) that replace the destinations only when complete;
# read_annotations checks sampfrom and sampto as read_record does; the
# record line is found as the header parser finds it.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 2.1 of the License, or (at
# your option) any later version. See LICENSE.

if (.mode == "source") {
  datasrc <- file.path(dirname(dirname(.rdir)), "tests", "data")
  old <- getwd()
  d <- tempfile("wfdbx-hc")
  dir.create(d)
  for (f in c("100s.hea", "100s.dat", "100s.atr", "fmt16.dat"))
    file.copy(file.path(datasrc, f), d)
  setwd(d)
  old_umask <- Sys.umask("022")
  on.exit({
    wfdbquit()
    wfdbverbose()
    setwd(old)
    Sys.umask(old_umask)
    unlink(d, recursive = TRUE)
    wfdbio_reset()
    sig_reset()
  }, add = TRUE)
  wfdbquit()

  errmsg <- function(expr) tryCatch({
    expr
    ""
  }, error = function(e) conditionMessage(e))
  quiet <- function(expr) {
    wfdbquiet()
    on.exit(wfdbverbose())
    expr
  }
  clean <- function() {
    .sig$nisig == 0 && .sig$nosig == 0 && length(.ann$iad) == 0 &&
      length(.ann$oad) == 0 && !isTRUE(.sig$read_failed) && is.null(.wfdb_io$staging)
  }
  rf <- function(name) readBin(name, "raw", file.size(name))
  # the contents of every file of the current directory (hidden files
  # included)
  snapshot <- function() {
    n <- sort(list.files(all.files = TRUE, no.. = TRUE), method = "radix")
    n <- n[!dir.exists(n)]
    structure(lapply(n, rf), names = n)
  }
  no_tmp <- function() !length(list.files(all.files = TRUE, pattern = "\\.tmp$"))
  mode_of <- function(f) as.character(file.info(f)$mode)

  # ---- a truncated record with a checksum: the read error is not hidden
  # by the checksum error, and the incomplete frame is not returned
  writeBin(as.integer(c(1, 2)), "tr.dat", size = 2L, endian = "little")
  writeLines("tr 1 250 3\ntr.dat 16 200 16 0 1 0 0 s", "tr.hea", sep = "\n")
  expect_equal(errmsg(quiet(read_record("tr"))),
               "can't read signal data of record tr (getvec status -3)",
               "truncated: read_record error")
  check(clean(), "truncated: state clean")
  # the C-style getvec keeps the C behavior: -4 for the incomplete frame
  quiet({
    expect_equal(isigopen("tr", 1)$nsig, 1, "truncated: isigopen")
    r <- getvec()
    expect_equal(c(r$stat, r$v[1L]), c(1, 1), "truncated: getvec 1")
    r <- getvec()
    expect_equal(c(r$stat, r$v[1L]), c(1, 2), "truncated: getvec 2")
    expect_equal(getvec()$stat, -4, "truncated: getvec 3")
    wfdbquit()
  })
  .sig$read_failed <- FALSE
  expect_equal(as.vector(read_record("tr", sampto = 2)$signals), c(1, 2),
               "truncated: sampto = 2")
  rep <- quiet(check_record("tr"))
  expect_equal(rep$issues$code[rep$issues$severity == "error"], "length_short",
               "truncated: check_record errors")
  check(grepl("the signal files end after 2 frames, before the 3 given in the header",
              paste(format.wfdbx_check_report(rep), collapse = "\n"), fixed = TRUE),
        "truncated: check_record message")
  check(clean(), "truncated: state clean after check_record")
  # a checksum error alone (all samples read) is still a warning
  writeLines("tr 1 250 2\ntr.dat 16 200 16 0 1 0 0 s", "tr.hea", sep = "\n")
  w <- NULL
  r <- withCallingHandlers(read_record("tr"), warning = function(e) {
    w <<- conditionMessage(e)
    invokeRestart("muffleWarning")
  })
  check(grepl("checksum error in record tr", w %||% "", fixed = TRUE), "checksum alone: warning")
  check(identical(as.vector(r$signals), c(1, 2)) && !r$checksum_ok,
        "checksum alone: signals, checksum_ok")

  # ---- read_record allocates no more than it reads
  writeBin(as.raw(c(1, 0, 2, 0)), "big.dat")
  writeLines("big 1 250 1000000000000\nbig.dat 16 200 16 0 0 0 0 s", "big.hea", sep = "\n")
  expect_equal(errmsg(quiet(read_record("big"))),
               "can't read signal data of record big (getvec status -3)",
               "big header: read error")
  expect_equal(as.vector(read_record("big", sampto = 2)$signals), c(1, 2), "big header: sampto 2")
  expect_equal(errmsg(quiet(read_record("big", sampto = 1e12))),
               "can't read signal data of record big (getvec status -3)",
               "big header: sampto 1e12")
  x <- matrix(seq_len(300000) - 1, ncol = 3, byrow = TRUE) %% 30000
  write_record("long", x, 100, gains = 200, adcres = 16, units = "mV")
  h <- readLines("long.hea")
  h[1L] <- sub("^long 3 100 100000", "long 3 100", h[1L])
  writeLines(h, "long.hea")
  expect_equal(read_record("long")$signals, x + 0, "long record without a length")
  check(clean(), "allocation: state clean")

  # ---- write_record checks every argument before any file is touched
  write_record("r", read_record("100s", sampto = 100)$signals, 360, gains = 200,
               adcres = 11, units = "mV", names = c("a", "b"))
  before <- snapshot()
  x <- matrix(0, 5, 2)
  # (a character beyond U+00FF, in a string marked as UTF-8, whatever the
  # locale of the session; R gives the messages in the native encoding)
  mu <- rawToChar(as.raw(c(0xce, 0xbc)))
  Encoding(mu) <- "UTF-8"
  bad <- list(
    list(list(units = paste0(mu, "V")), paste0("units '", mu, "V' has a character that is not Latin-1 (one byte per character)")),
    list(list(signals = array(0, c(2, 2, 2))), "signals must be a 1-D or 2-D array"),
    list(list(names = c("a", mu)), paste0("signal name '", mu, "' has a character that is not Latin-1 (one byte per character)")),
    list(list(comments = c("ok", mu)), paste0("comment '", mu, "' has a character that is not Latin-1 (one byte per character)")),
    list(list(baselines = 1.5), "baselines must be whole numbers within the range of a 32-bit integer"),
    list(list(baselines = NaN), "baselines must be whole numbers within the range of a 32-bit integer"),
    list(list(baselines = 2^31), "baselines must be whole numbers within the range of a 32-bit integer"),
    list(list(baselines = "x"), "baselines must be whole numbers within the range of a 32-bit integer"),
    list(list(adczeros = -2^31 - 1), "adczeros must be whole numbers within the range of a 32-bit integer"),
    list(list(adczeros = c(0, 0.5)), "adczeros must be whole numbers within the range of a 32-bit integer"),
    list(list(adcres = 12.5), "adcres must be whole numbers within the range of a 32-bit integer"),
    list(list(adcres = "x"), "adcres must be whole numbers within the range of a 32-bit integer"),
    list(list(adcres = NaN), "adcres must be whole numbers within the range of a 32-bit integer"),
    list(list(adcres = c(12, 0)), "ADC resolution(s) must be specified"),
    list(list(adcres = c(12, NA)), "ADC resolution(s) must be specified"),
    list(list(gains = c(200, Inf)), "gains must be finite"))
  for (b in bad) {
    a <- modifyList(list(signals = x, gains = 200, adcres = 12, units = "mV"), b[[1L]])
    m <- errmsg(do.call(write_record, c(list("r", fs = 360), a)))
    expect_equal(m, enc2native(b[[2L]]), paste("write_record checks:", names(b[[1L]])))
    check(identical(snapshot(), before), paste("write_record checks: files unchanged,", names(b[[1L]])))
  }
  # (legacy mode: the ADC values are checked too)
  expect_equal(errmsg(write_record("r", x, 360, adczeros = 0.5, legacy = TRUE)),
               "adczeros must be whole numbers within the range of a 32-bit integer",
               "write_record checks: legacy adczeros")
  expect_equal(errmsg(write_record(paste0("r", mu), x, 360, gains = 200, adcres = 12, units = "mV")),
               enc2native(paste0("record name 'r", mu,
                                 "' has a character that is not Latin-1 (one byte per character)")),
               "write_record checks: record name")
  check(identical(snapshot(), before), "write_record checks: files unchanged")
  check(clean(), "write_record checks: state clean")

  # ---- a failure while writing leaves the existing files intact
  x <- matrix(0:19, 10, 2, byrow = TRUE)
  kw <- list(gains = 200, adcres = 12, units = "mV")
  wr <- function(...) do.call(write_record, c(list("r", x, 250), kw, list(...)))
  local({
    real <- newheader
    assign("newheader", function(record) -1, envir = environment(write_record))
    on.exit(assign("newheader", real, envir = environment(write_record)))
    expect_equal(errmsg(quiet(wr())), "can't create header for record r",
                 "write_record failure: header")
  })
  check(identical(snapshot(), before), "write_record failure: header: files unchanged")
  local({
    real <- putframes
    assign("putframes", function(...) stop("disk on fire"), envir = environment(write_record))
    on.exit(assign("putframes", real, envir = environment(write_record)))
    expect_equal(errmsg(wr()), "disk on fire", "write_record failure: samples")
  })
  check(identical(snapshot(), before), "write_record failure: samples: files unchanged")
  check(clean(), "write_record failure: state clean")
  # a directory in the way of the header: the signal file is not created
  dir.create("q.hea")
  expect_equal(errmsg(quiet(write_record("q", x, 250, gains = 200, adcres = 12, units = "mV"))),
               "can't create header for record q", "write_record: directory in the way")
  check(!file.exists("q.dat") && no_tmp(), "write_record: directory in the way: no file")
  # success: the files have the permissions of the files they replace
  Sys.chmod("r.dat", "640", use_umask = FALSE)
  Sys.chmod("r.hea", "600", use_umask = FALSE)
  wr()
  expect_equal(mode_of("r.dat"), "640", "write_record: r.dat keeps 0640")
  expect_equal(mode_of("r.hea"), "600", "write_record: r.hea keeps 0600")
  expect_equal(read_record("r")$signals, x + 0, "write_record: replaced")
  write_record("new", x, 250, gains = 200, adcres = 12, units = "mV")
  expect_equal(mode_of("new.hea"), "644", "write_record: a new file: 0666 less the umask")
  check(no_tmp(), "write_record: no temporary file")
  # through a symbolic link: the file it leads to is replaced
  if (.Platform$OS.type != "windows") {
    dir.create("real")
    file.copy(c("r.hea", "r.dat"), "real")
    file.symlink(file.path(getwd(), "real", "r.hea"), "l.hea")
    file.symlink(file.path(getwd(), "real", "r.dat"), "l.dat")
    write_record("l", x * 2, 250, gains = 200, adcres = 12, units = "mV")
    check(nzchar(Sys.readlink("l.hea")) && nzchar(Sys.readlink("l.dat")),
          "write_record: the symbolic links stay")
    expect_equal(read_record("l")$signals, x * 2, "write_record: the target replaced")
    check(identical(rf("real/r.dat"), rf("l.dat")), "write_record: the target replaced (real/r.dat)")
    check(no_tmp() && !length(list.files("real", all.files = TRUE, pattern = "\\.tmp$")),
          "write_record: symbolic link: no temporary file")
  }

  # ---- the temporary files are created owner-only, before anything is
  # written to them
  tmode <- NULL
  local({
    real <- putframes
    assign("putframes", function(...) {
      t <- list.files(all.files = TRUE, pattern = "^\\.r\\.dat\\..{8}\\.tmp$")
      tmode <<- if (length(t) == 1L) mode_of(t)
      real(...)
    }, envir = environment(write_record))
    on.exit(assign("putframes", real, envir = environment(write_record)))
    wr()
  })
  expect_equal(tmode, "600", "staging: the temporary file is created 0600")
  t <- .wfdbx_temp_file(file.path(getwd(), "z.hea"))
  check(!is.null(t) && grepl("^\\.z\\.hea\\.[^.]{8}\\.tmp$", basename(t)) && mode_of(t) == "600",
        "temporary file: name and mode")
  unlink(t)

  # ---- the metadata functions: a 0600 header stays 0600
  Sys.chmod("r.hea", "600", use_umask = FALSE)
  tmode <- NULL
  local({
    real <- .wfdbx_replace_with
    assign(".wfdbx_replace_with", function(tmp, dest) {
      tmode <<- mode_of(tmp)
      real(tmp, dest)
    }, envir = environment(set_metadata))
    on.exit(assign(".wfdbx_replace_with", real, envir = environment(set_metadata)))
    set_metadata("r", "Age", "63")
  })
  expect_equal(tmode, "600", "metadata: the temporary file is 0600 when written")
  expect_equal(mode_of("r.hea"), "600", "metadata: a 0600 header stays 0600")
  Sys.chmod("r.hea", "644", use_umask = FALSE)
  set_metadata("r", "Age", "64")
  expect_equal(mode_of("r.hea"), "644", "metadata: a 0644 header stays 0644")
  expect_equal(get_metadata("r", "age"), "64", "metadata: value")
  check(no_tmp(), "metadata: no temporary file")

  # ---- write_annotations checks every argument before the file is touched
  write_annotations("100s", "qrs", c(10, 20, 30), symbol = "N")
  before <- snapshot()
  bad <- c(list(
    list(list(sample = matrix(1:4, 2)), "samples must be a 1-D array"),
    list(list(code = matrix(1, 3, 1)), "code must be a 1-D array"),
    list(list(subtype = matrix(0, 3, 1)), "subtype must be a 1-D array"),
    list(list(sample = c(-2^63, 5, 6)), paste0("annotation time -9223372036854775808 cannot be ",
      "written (annotation times must be integers from -9223372036854775807 to 9223372036854775806)")),
    list(list(sample = c(1, 5, 2^63)), "annotation times must be integers within the range of a 64-bit integer"),
    list(list(code = -1), "annotation code -1 is out of range (0 to 58)"),
    list(list(code = c(1, 64, 1)), "annotation code 64 is out of range (0 to 58)"),
    list(list(aux = c(NA, mu, NA)), paste0("aux text '", mu, "' has a character that is not Latin-1 (one byte per character)"))),
    lapply(59:63, function(c) list(list(code = c(1, c, 1)),
      sprintf("annotation code %d is reserved (59 to 63 are the control codes of the annotation file format)", c))))
  for (b in bad) {
    a <- modifyList(list(sample = c(1, 2, 3)), b[[1L]])
    if (is.null(a$code)) a$symbol <- "N"
    m <- errmsg(do.call(write_annotations, c(list("100s", "qrs"), a)))
    expect_equal(m, enc2native(b[[2L]]), paste("write_annotations checks:", names(b[[1L]])))
    check(identical(snapshot(), before), paste("write_annotations checks: file unchanged,", names(b[[1L]])))
  }
  check(clean(), "write_annotations checks: state clean")
  # code 58, and a time far from the previous one (SKIPs), can be written
  write_annotations("100s", "ext", c(0, 2^33), code = c(58, 1))
  a <- read_annotations("100s", "ext")
  check(identical(a$sample, c(0, 2^33)) && identical(a$code, c(58, 1)), "write_annotations: code 58, 2^33")

  # ---- a failure while writing leaves the existing file intact
  write_annotations("100s", "qrs", c(10, 20, 30), symbol = "N")
  before <- snapshot()
  local({
    real <- .putann_bulk
    assign(".putann_bulk", function(...) -1, envir = environment(write_annotations))
    on.exit(assign(".putann_bulk", real, envir = environment(write_annotations)))
    expect_equal(errmsg(write_annotations("100s", "qrs", c(1, 2), symbol = "V")),
                 "write error on annotator qrs for record 100s", "write_annotations: putann error")
  })
  check(identical(snapshot(), before), "write_annotations: putann error: file unchanged")
  local({
    real <- .putann_bulk
    assign(".putann_bulk", function(...) stop("disk on fire"), envir = environment(write_annotations))
    on.exit(assign(".putann_bulk", real, envir = environment(write_annotations)))
    expect_equal(errmsg(write_annotations("100s", "qrs", c(1, 2), symbol = "V")),
                 "disk on fire", "write_annotations: failure")
  })
  check(identical(snapshot(), before), "write_annotations: failure: file unchanged")
  check(clean(), "write_annotations failure: state clean")
  # out of order: sorted (in this process, and in legacy mode by the
  # sortann program), then renamed over the existing file
  for (legacy in c(FALSE, TRUE)) {
    if (legacy) .wfdb_io$driver <- file.path(dirname(.rdir), "inst", "bin", "wfdbx.R")
    quiet(write_annotations("100s", "qrs", c(30, 10, 20), symbol = "N", legacy = legacy))
    expect_equal(read_annotations("100s", "qrs")$sample, c(10, 20, 30),
                 paste("write_annotations: out of order, legacy", legacy))
    check(no_tmp(), paste("write_annotations: out of order: no temporary file, legacy", legacy))
  }

  # ---- read_annotations: sampfrom and sampto checked as read_record does
  ref <- read_annotations("100s", "atr", sampfrom = 100, sampto = 2000)
  expect_equal(read_annotations("100s", "atr", sampfrom = 100.0, sampto = 2000.0)$sample,
               ref$sample, "read_annotations: whole doubles")
  for (b in list(list(1.5, NULL, "sampfrom must be a whole number"),
                 list(NaN, NULL, "sampfrom must be a whole number"),
                 list(0, Inf, "sampto must be a whole number"),
                 list(0, 10.25, "sampto must be a whole number"),
                 list(list(1), NULL, "sampfrom must be a sample number or a time string"),
                 list(c(1, 2), NULL, "sampfrom must be a sample number or a time string"),
                 list(2^64, NULL, "sampfrom is beyond the range of a 64-bit integer"),
                 list(-1, NULL, "sampfrom must not be negative"))) {
    expect_equal(errmsg(read_annotations("100s", "nosuch", sampfrom = b[[1L]], sampto = b[[2L]])),
                 b[[3L]], paste("read_annotations:", b[[3L]]))
  }
  check(clean(), "read_annotations arguments: state clean")
  file.copy("100s.atr", "x100.atr")
  expect_equal(errmsg(quiet(read_annotations("x100", "atr", sampto = "0:1"))),
               "sampling frequency of record x100 is not specified",
               "read_annotations: no frequency")
  check(clean(), "read_annotations: no frequency: closed")
  writeBin(rf("100s.atr")[1:101], "cut.atr")
  m <- errmsg(quiet(read_annotations("cut", "atr", fs = 360)))
  check(grepl("getann status -3", m, fixed = TRUE), "read_annotations: truncated file")
  check(clean(), "read_annotations: truncated file: closed")

  # ---- the record line, as readheader finds it
  sig <- "fmt16.dat 16 200 12 0 0 0 0 a\n"
  cases <- list(
    list("le", paste0("\n# Age: 40\nle 1 250 10\n", sig, "# Age: 63\n"),
         " Age: 63", c(" Age: 40", " Age: 63")),
    list("lw", paste0(" \t\r\n# Age: 40\r\nlw 1 250 10\r\n", sub("\n", "\r\n", sig, fixed = TRUE),
                      "# Age: 63\r\n"),
         " Age: 63", c(" Age: 40", " Age: 63")),
    list("lc", paste0("# first\n\n# Age: 40\n \t\n  # indented\nlc 1 250 10\n", sig, "# Age: 63\n#last\n"),
         c(" Age: 63", "last"), c(" Age: 40", " Age: 63", "last")),
    list("ln", "# only\n\n# comments\n", character(0), " comments"))
  for (cs in cases) {
    name <- cs[[1L]]
    writeBin(charToRaw(cs[[2L]]), paste0(name, ".hea"))
    for (legacy in c(FALSE, TRUE)) {
      prev <- wfdbx_set_legacy(legacy)
      got <- character(0)
      quiet({
        x <- getinfo(name)
        while (!is.null(x)) {
          got <- c(got, x)
          x <- getinfo(NULL)
        }
      })
      wfdbx_set_legacy(prev)
      wfdbquit()
      expect_equal(got, if (legacy) cs[[4L]] else cs[[3L]], paste("getinfo", name, "legacy", legacy))
    }
    if (name != "ln") {
      expect_equal(read_header(name)$comments, cs[[3L]], paste("read_header comments", name))
      expect_equal(read_header(name, legacy = TRUE)$comments, cs[[4L]],
                   paste("read_header comments legacy", name))
      expect_equal(read_header(name)$metadata, c(Age = "63"), paste("read_header metadata", name))
      expect_equal(read_header(name, legacy = TRUE)$metadata, c(Age = "63"),
                   paste("read_header metadata legacy", name))
      expect_equal(read_record(name, legacy = TRUE, checksum_warning = FALSE)$comments, cs[[4L]],
                   paste("read_record comments legacy", name))
    }
  }
  check(clean(), "record line: state clean")
}
