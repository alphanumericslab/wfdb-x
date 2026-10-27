# Tests of check_record (check.R): port of python/tests/test_check.py.
# The corpus of python/tests/check_corpus.py (one broken record for each
# issue code, a clean record, records of tests/data, annotation files) is
# generated in a temporary directory by running that script (with the
# Python implementation; skipped if python3 or the Python sources are not
# available), and the report of each case of its cases.txt is compared
# with its expected.txt (the Python reports, which every implementation
# must print).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests wfdb-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# Helpers that need no corpus
expect_equal(.chk_q(rawToChar(as.raw(c(97, 9, 98, 127, 233, 34, 99)))),
             "\"a\\x09b\\x7f\\xe9\"c\"", "quoting")
check(.chk_is_number("12") && .chk_is_number("-1.5") && .chk_is_number("+.5"), "numbers")
check(!.chk_is_number("1.2.3") && !.chk_is_number("V5") && !.chk_is_number("-"), "not numbers")
expect_error(check_record(NULL), "record NULL")
expect_error(check_record(1), "record not a string")
expect_error(check_record(""), "record empty")
expect_error(check_record("100s", 1), "annotator not a string")

root <- if (nzchar(.rdir)) dirname(dirname(.rdir)) else ""
gen <- file.path(root, "python", "tests", "check_corpus.py")
py <- Sys.which("python3")
if (!nzchar(root) || !file.exists(gen) || !nzchar(py)) {
  cat("(python3 or check_corpus.py not found: check_record corpus tests skipped)\n")
} else {
d <- tempfile("wfdbx-check")
on.exit({
  wfdbquit()
  unlink(d, recursive = TRUE)
  annot_reset(tables = TRUE)
}, add = TRUE)
data <- file.path(root, "tests", "data")
old_pp <- Sys.getenv("PYTHONPATH", unset = NA)
Sys.setenv(PYTHONPATH = file.path(root, "python", "src"))
st <- system2(py, shQuote(c(gen, d, data)), stdout = FALSE, stderr = FALSE)
if (is.na(old_pp)) Sys.unsetenv("PYTHONPATH") else Sys.setenv(PYTHONPATH = old_pp)
check(st == 0, "corpus generated")
cases <- readLines(file.path(d, "cases.txt"))
expected <- readLines(file.path(d, "expected.txt"))
heads <- which(startsWith(expected, "== "))
expect_equal(substring(expected[heads], 4L), cases, "expected.txt: one block per case")
ends <- c(heads[-1L] - 1L, length(expected))
codes <- character(0)
for (k in seq_along(cases)) {
  w <- strsplit(cases[k], " ", fixed = TRUE)[[1L]]
  r <- check_record(w[1L], w[-1L], input_dir = d)
  want <- expected[seq.int(heads[k] + 1L, length.out = ends[k] - heads[k])]
  expect_equal(format(r), want, paste("corpus:", cases[k]))
  check(identical(r$record, w[1L]) && identical(r$ok, !any(r$issues$severity == "error")),
        paste("corpus: record and ok,", cases[k]))
  codes <- c(codes, r$issues$code)
}
all_codes <- c(
  "header_unreadable", "no_signals", "fs_missing", "length_missing", "header_line_long",
  "header_not_ascii", "header_name", "length_large", "desc_missing", "desc_number",
  "desc_control", "format_difference", "gain_missing", "gain_negative", "units_missing",
  "units_control", "adcres_missing", "adcres_too_large", "adc_range", "filename",
  "desc_duplicate", "file_unreadable", "file_large", "sample_range", "invalid_samples",
  "checksum", "length_short", "length_long", "length_unspecified_frames", "read_error",
  "nested", "segment_unreadable", "segment_fs", "layout_missing_signal", "layout_signals",
  "layout_mismatch", "segment_lengths", "annotator_name", "annotations_unreadable",
  "annotations_truncated", "annotations_order", "annotation_code", "annotation_null",
  "annotation_undefined", "annotations_after_end")
expect_equal(setdiff(all_codes, codes), "file_large", "corpus: every code but file_large")

# The fields of a report
r <- check_record("d_cksum", input_dir = d)
check(!r$ok && nrow(r$issues) == 1L, "d_cksum: one error")
expect_equal(unlist(r$issues[1L, ], use.names = FALSE),
             c("error", "checksum", "signal 1",
               "the checksum does not match: the header gives 1, the samples sum to 0"),
             "d_cksum: issue fields")
expect_equal(class(r), "wfdbx_check_report", "class")
out <- capture.output(print(r))
expect_equal(out, format(r), "print")
r <- check_record("clean", "atr", input_dir = d)
check(r$ok && nrow(r$issues) == 0L, "clean: no issue")
expect_equal(capture.output(print(r)), "no problems found", "clean: printed")
r <- check_record("nolen", input_dir = d)
check(r$ok && identical(r$issues$severity, c("warning", "info")), "warnings and infos: ok")
expect_equal(format(r)[1L], "warning: the record length is not specified", "nolen: text")

# The bundled sample record
r <- check_record("100s", "atr", input_dir = data)
check(r$ok, "100s: ok")
expect_equal(format(r), c("warning: signal 0: the units are not specified",
                          "warning: signal 1: the units are not specified"), "100s")

# Settings restored: legacy mode off during the call, nothing printed, the
# input directory restored, messages printed again afterwards
stderr_of <- function(expr) {
  tf <- tempfile()
  con <- file(tf, open = "wb")
  saved <- .cstd$err_con
  .cstd$err_con <- con
  on.exit({
    .cstd$err_con <- saved
    close(con)
    unlink(tf)
  })
  expr
  flush(con)
  rawToChar(readBin(tf, "raw", max(1, file.size(tf))))
}
prev_dir <- wfdbx_get_input_dir()
wfdbx_set_legacy(TRUE)
err <- stderr_of(r <- check_record("nofs", "nofile", input_dir = d))
check(isTRUE(wfdbx_get_legacy()), "legacy mode restored")
wfdbx_set_legacy(FALSE)
expect_equal(r$issues$code[1L], "fs_missing", "normal mode during the call")
expect_equal(err, "", "nothing printed")
expect_equal(wfdbx_get_input_dir(), prev_dir, "input directory restored")
err <- stderr_of(isigopen("no_such_record", 0))
check(grepl("no_such_record", err, fixed = TRUE), "messages printed after the call")
wfdbquit()

# Codes defined by the file's modification labels have a mnemonic; the
# definitions do not outlive the check
setannstr(42, "QQ")
setanndesc(42, "my beat")
write_annotations("clean", "lab", c(10, 20, 30), code = c(42, 1, 43), dir = d)
setannstr(-42, "[42]")
setanndesc(-42, NULL)
m <- .ann$modified
m[43L] <- FALSE
.ann$modified <- m
r <- check_record("clean", "lab", input_dir = d)
expect_equal(format(r), paste0("warning: annotator lab: 1 annotation uses a code ",
                               "without a mnemonic: at sample 30 (code 43)"),
             "modification labels")
expect_equal(annstr(42), "[42]", "modification labels: tables restored")

# A signal file larger than 2^31 - 1 bytes (its size is simulated)
ns <- environment(check_record)
saved_size <- get(".chk_file_size", envir = ns)
unlockBinding(".chk_file_size", ns)
assign(".chk_file_size", function(ig) 2^31, envir = ns)
r <- tryCatch(check_record("clean", input_dir = d),
              finally = assign(".chk_file_size", saved_size, envir = ns))
expect_equal(format(r), paste0("warning: the signal file \"clean.dat\" has more than ",
                               "2147483647 bytes, which 32-bit applications cannot handle"),
             "file_large")
}
