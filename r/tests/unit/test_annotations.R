# Tests of the annotation and calibration modules (annot.R, calib.R,
# highlevel_annot.R): port of python/tests/test_annotations.py and of the
# annotation, calibration and mnemonic parts of python/tests/test_api.py
# (expected values produced by the C library, tests/reference/api_expect.c),
# plus checks of the vectorized paths (file decoding, bulk getann/putann,
# the tools' parsers and formatters) against direct reference
# implementations.
#
# Part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

data <- if (nzchar(.rdir)) file.path(dirname(dirname(.rdir)), "tests", "data") else ""
if (!nzchar(data) || !dir.exists(data)) {
  cat("(tests/data not found: annotation tests skipped)\n")
} else {
old <- getwd()
oldpath <- Sys.getenv("WFDB", unset = NA)
d <- tempfile("wfdbx-test")
dir.create(d)
file.copy(list.files(data, full.names = TRUE), d)
setwd(d)
on.exit({
  wfdbquit()
  setwd(old)
  if (is.na(oldpath)) Sys.unsetenv("WFDB") else Sys.setenv(WFDB = oldpath)
  unlink(d, recursive = TRUE)
  annot_reset(tables = TRUE)
  flushcal()
  wfdbverbose()
}, add = TRUE)
wfdbquit()
setwfdb(".")
rf <- function(name) readBin(name, "raw", file.size(name))
hexr <- function(h) as.raw(strtoi(substring(h, seq(1, nchar(h), 2), seq(2, nchar(h), 2)), 16L))
ann <- function(n) {
  r <- getann(n)
  if (r$stat != 0) return(r$stat)
  a <- r$annot
  c(r$stat, a$time, a$anntyp, a$subtyp, a$chan, a$num)
}
cal <- function(desc, units) {
  r <- getcal(desc, units)
  if (r$stat != 0) return(list(r$stat))
  c <- r$cal
  list(r$stat, c$low, c$high, c$scale, c$caltype, c$sigtype, c$units)
}

# --- test_annotations.py
a <- read_annotations("100s", "atr")
expect_equal(nrow(a), 75L, "read: 75 annotations")
expect_equal(a$symbol[1:3], c("+", "N", "N"), "read: symbols")
expect_equal(a$aux[1L], "(N", "read: aux")
expect_equal(attr(a, "fs"), 360, "read: fs")
b <- read_annotations("100s", "atr", sampfrom = "0:10", sampto = 7200)
expect_equal(b$sample, a$sample[a$sample >= 3600 & a$sample < 7200], "read: sampfrom/sampto")

samples <- c(0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000)
codes <- c(NOTE, NORMAL, NORMAL, NORMAL, PVC, ARFCT, RHYTHM, NORMAL, NOISE)
chans <- c(0, 0, 1, 1, 0, 3, 0, 0, 2)
nums <- c(0, 0, 0, 2, 0, -1, 0, 0, 1)
sub <- c(0, 0, 0, 0, 3, 0, 0, 0, -1)
aux <- c("start", NA, NA, NA, NA, NA, "(AFIB", NA, strrep("x", 200))
write_annotations("100s", "rt", samples, code = codes, chan = chans, num = nums, subtype = sub,
                  aux = aux)
wfdbquiet()
a <- read_annotations("100s", "rt")
wfdbverbose()
# (the NOTE at time 0 is consumed as a modification label by annopen)
expect_equal(a$sample, samples[-1], "roundtrip: samples")
expect_equal(a$code, codes[-1], "roundtrip: codes")
expect_equal(a$chan, chans[-1], "roundtrip: chans")
expect_equal(a$num, nums[-1], "roundtrip: nums")
expect_equal(a$subtype, sub[-1], "roundtrip: subtypes")
expect_equal(a$aux, aux[-1], "roundtrip: aux")
write_annotations("100s", "rt2", a)
b <- read_annotations("100s", "rt2")
expect_equal(unclass(b)[names(b)], unclass(a)[names(a)], "write_annotations of a data frame")

expect_equal(annstr(NORMAL), "N", "annstr")
expect_equal(strann("V"), PVC, "strann")
expect_equal(anndesc(PVC), "Premature ventricular contraction", "anndesc")
expect_equal(ecgstr(99), "[99]", "ecgstr")
check(isqrs(NORMAL) == 1 && isqrs(NOTE) == 0, "isqrs")
check(map1(APC) == NORMAL && map2(APC) == SVPB, "map1/map2")
expect_equal(annstr(c(1, 5, -1, 60)), c("N", "V", "[-1]", "[60]"), "annstr vectorized")
expect_equal(strann(c("N", "V", "xx")), c(1, 5, 0), "strann vectorized")

# --- t_calib
calopen("wfdbcal")
expect_equal(cal("ECG lead II", "mV"), list(0, 0, 1, 1, 4, "ECG", "mV"), "getcal ECG mV")
expect_equal(cal("ECG", "uV"), list(0, 0, 1, 1000, 4, "ECG", "uV"), "getcal ECG uV")
expect_equal(cal("ABP", "mmHg"), list(0, 0, 0, 100, 3, "ABP", "mmHg"), "getcal ABP")
expect_equal(cal("BP", NULL), list(0, 0, 100, 100, 3, "BP", "mmHg"), "getcal BP")
expect_equal(cal(NULL, NULL), list(0, 0, 1, 1, 4, "ECG", "mV"), "getcal NULL")
expect_equal(cal("nosuch", "x"), list(-1), "getcal nosuch")
test <- calinfo(-1.5, 2.5, 3, "TEST", "xu", WFDB_DC_COUPLED + WFDB_CAL_SINE)
ac <- calinfo(0, 0, 7, "AC", "yu", WFDB_AC_COUPLED + WFDB_CAL_UNDEF)
expect_equal(putcal(test), 0, "putcal")
expect_equal(putcal(ac), 0, "putcal 2")
expect_equal(cal("TEST signal", "xu"), list(0, -1.5, 2.5, 3, 5, "TEST", "xu"), "getcal TEST")
flushcal()
expect_equal(cal("ECG", "mV"), list(-1), "flushcal")
putcal(test)
putcal(ac)
putcal(calinfo(1, 2, 0.25, "SQ", "zu", WFDB_DC_COUPLED + WFDB_CAL_SQUARE))
putcal(calinfo(1, 2, 0.25, "SAW", "zu", WFDB_AC_COUPLED + WFDB_CAL_SAWTOOTH))
wfdbquiet()
expect_equal(newcal("my.cal"), -1, "newcal illegal name")
wfdbverbose()
expect_equal(newcal("mycal"), 0, "newcal")
expect_equal(rawToChar(rf("mycal")),
             paste0("TEST\t-1.5 2.5 sine 3 xu\r\n", "AC\t- - undefined 7 yu\r\n",
                    "SQ\t1 2 square 0.25 zu\r\n", "SAW\t- 2 sawtooth 0.25 zu\r\n"), "newcal file")
expect_equal(calopen("mycal"), 0, "calopen mycal")
expect_equal(cal("AC", "yu"), list(0, 0, 0, 7, 0, "AC", "yu"), "getcal AC")
expect_equal(cal("ECG", "mV"), list(-1), "calopen replaces the list")
expect_equal(calopen("+wfdbcal"), 0, "calopen +")
expect_equal(cal("ECG", "mV"), list(0, 0, 1, 1, 4, "ECG", "mV"), "calopen + appends")
expect_equal(cal("SAW", NULL), list(0, 0, 2, 0.25, 6, "SAW", "zu"), "getcal SAW")
wfdbquiet()
expect_equal(calopen("nosuch.cal"), -2, "calopen nosuch")
wfdbverbose()
flushcal()

# --- t_annot
wfdbquit()
expect_equal(getafreq(), 0, "getafreq initially")
sampfreq("100s")
ai <- list(anninfo("atr", WFDB_READ), anninfo("ooo", WFDB_READ))
expect_equal(annopen("100s", ai, 2), 0, "annopen 2 annotators")
expect_equal(c(getiafreq(0), getiafreq(1), getiafreq(2)), c(360, 360, -2), "getiafreq")
expect_equal(c(getiaorigfreq(0), getiaorigfreq(1), getiaorigfreq(2)), c(0, 360, -2), "getiaorigfreq")
expect_equal(ann(0), c(0, 18, 28, 0, 0, 0), "ann 1")
expect_equal(ann(0), c(0, 77, 1, 0, 0, 0), "ann 2")
setiafreq(0, 1000)
expect_equal(getiafreq(0), 1000, "setiafreq 1000")
expect_equal(getiaorigfreq(0), 0, "getiaorigfreq unchanged")
r <- getann(0)
expect_equal(c(r$stat, r$annot$time, r$annot$anntyp), c(0, 1028, 1), "ann at 1000 Hz")
wfdbquiet()
expect_equal(ungetann(0, r$annot), 0, "ungetann")
expect_equal(ungetann(0, r$annot), -1, "ungetann: buffer full")
expect_equal(ungetann(5, r$annot), -2, "ungetann: bad annotator")
wfdbverbose()
expect_equal(ann(0), c(0, 1028, 1, 0, 0, 0), "pushed back")
expect_equal(ann(0), c(0, 1839, 1, 0, 0, 0), "next")
expect_equal(ungetann(0, annotation(time = 5, anntyp = PVC, subtyp = 0)), 0, "ungetann other")
expect_equal(ann(0), c(0, 5, 5, 0, 0, 0), "pushed back other")
setiafreq(0, 0)
expect_equal(getiafreq(0), 360, "setiafreq 0")
expect_equal(ann(0), c(0, 946, 1, 0, 0, 0), "back at 360 Hz")
iannclose(0)          # annotator 1 (ooo) becomes annotator 0
expect_equal(c(getiafreq(0), getiafreq(1)), c(360, -2), "after iannclose")
expect_equal(ann(0), c(0, 18, 1, 0, 0, 0), "ooo first")
wfdbquiet()
expect_equal(ann(1), -2, "getann bad annotator")
iannclose(0)
expect_equal(ann(0), -2, "all closed")
iannclose(3)
wfdbverbose()
wfdbquit()

setafreq(1000)
expect_equal(getafreq(), 1000, "setafreq")
annopen("100s", list(anninfo("hf", WFDB_WRITE)))
putann(0, annotation(time = 1000, anntyp = NORMAL))
putann(0, annotation(time = 2500, anntyp = NORMAL))
wfdbquit()
expect_equal(getafreq(), 1000, "afreq survives wfdbquit")
setafreq(0)
annopen("100s", list(anninfo("hf", WFDB_READ)))
expect_equal(getiafreq(0), 1000, "getiafreq hf")
expect_equal(getiaorigfreq(0), 1000, "getiaorigfreq hf")
expect_equal(ann(0), c(0, 1000, 1, 0, 0, 0), "hf ann 1")
setiafreq(0, 360)
expect_equal(getiafreq(0), 360, "hf at 360")
expect_equal(ann(0), c(0, 900, 1, 0, 0, 0), "hf ann 2 at 360")
wfdbquit()

# --- t_strings
expect_equal(ecgstr(c(1, 0, 15, 22, 50, -1)), c("N", " ", "[15]", "\"", "[50]", "[-1]"), "ecgstr")
expect_equal(c(strecg("V"), strecg("xx"), strecg(""), strecg("[15]")), c(5, 0, 0, 15), "strecg")
expect_equal(setecgstr(5, "PVC"), 0, "setecgstr")
expect_equal(ecgstr(5), "PVC", "ecgstr after setecgstr")
expect_equal(annstr(5), "V", "annstr unchanged by setecgstr")
expect_equal(c(strecg("PVC"), strecg("V")), c(5, 0), "strecg after setecgstr")
wfdbquiet()
expect_equal(setecgstr(50, "x"), -1, "setecgstr 50")
expect_equal(setecgstr(-1, "x"), -1, "setecgstr -1")
wfdbverbose()
expect_equal(setecgstr(0, "Z"), 0, "setecgstr 0")
expect_equal(ecgstr(0), "Z", "ecgstr 0")
setecgstr(5, "V")
setecgstr(0, " ")

expect_equal(setannstr(5, "pvc"), 0, "setannstr")
expect_equal(annstr(5), "pvc", "annstr after setannstr")
expect_equal(ecgstr(5), "V", "ecgstr unchanged")
expect_equal(c(strann("pvc"), strann("V")), c(5, 0), "strann after setannstr")
expect_equal(setannstr(-6, "fus"), 0, "setannstr negative")
expect_equal(annstr(6), "fus", "annstr 6")
wfdbquiet()
expect_equal(setannstr(60, "x"), -1, "setannstr 60")
expect_equal(setannstr(-60, "x"), -1, "setannstr -60")
wfdbverbose()
expect_equal(setannstr(0, "zero"), 0, "setannstr 0")
expect_equal(annstr(0), "zero", "annstr 0")
expect_equal(annstr(60), "[60]", "annstr 60")
expect_equal(setannstr(42, "new"), 0, "setannstr 42")
expect_equal(strann("new"), 42, "strann new")
expect_equal(anndesc(1), "Normal beat", "anndesc 1")
expect_equal(anndesc(15), NULL, "anndesc 15")
expect_equal(anndesc(60), "illegal annotation code", "anndesc 60")
expect_equal(anndesc(-1), "illegal annotation code", "anndesc -1")
expect_equal(setanndesc(15, "my description"), 0, "setanndesc")
expect_equal(anndesc(15), "my description", "anndesc after setanndesc")
expect_equal(setanndesc(-43, "negative"), 0, "setanndesc negative")
expect_equal(anndesc(43), "negative", "anndesc 43")
wfdbquiet()
expect_equal(setanndesc(50, "x"), -1, "setanndesc 50")
wfdbverbose()
# Modified mnemonics (but not those set with a negative code) are written
# into output annotation files ...
annopen("100s", list(anninfo("mod", WFDB_WRITE)))
putann(0, annotation(time = 10, anntyp = PVC))
wfdbquit()
expect_equal(rf("100s.mod"),
             c(hexr("00581efc"), charToRaw("## annotation type definitions"),
               hexr("005827fc"), charToRaw("5 pvc Premature ventricular contraction"), as.raw(0),
               hexr("005816fc"), charToRaw("15 [15] my description"),
               hexr("005807fc"), charToRaw("42 new "), as.raw(0),
               hexr("005815fc"), charToRaw("## end of definitions"), as.raw(0),
               hexr("00ecffffffff01000a140000")), "modification labels written")
setannstr(5, "V")
setannstr(-6, "F")
setannstr(0, " ")
setannstr(-42, "[42]")
setanndesc(-15, "")
setanndesc(-43, "")
# ... and reading the file defines them again.
annopen("100s", list(anninfo("mod", WFDB_READ)))
expect_equal(ann(0), c(0, 10, 5, 0, 0, 0), "mod ann")
expect_equal(annstr(5), "pvc", "mnemonic redefined by the file")
expect_equal(anndesc(15), "my description", "description redefined by the file")
expect_equal(anndesc(42), "", "description 42")
wfdbquit()
annot_reset(tables = TRUE)

# --- AHA format
expect_equal(annopen("100s", list(anninfo("aha", WFDB_AHA_READ))), 0, "annopen AHA")
A <- .getann_bulk(0, Inf)
expect_equal(A$stat, -1, "AHA read to the end")
expect_equal(length(A$time), 75L, "AHA: 75 annotations")
wfdbquit()
annopen("100s", list(anninfo("atr", WFDB_READ)))
B <- .getann_bulk(0, Inf)
wfdbquit()
expect_equal(A$time, B$time, "AHA times = MIT times")
annopen("100s", list(anninfo("cpy", WFDB_AHA_WRITE)))
.putann_bulk(0, B)
wfdbquit()
annopen("100s", list(anninfo("cpy", WFDB_AHA_READ)))
C <- .getann_bulk(0, Inf)
wfdbquit()
expect_equal(C$time, B$time, "AHA write/read: times")
expect_equal(file.size("100s.cpy") %% 1024, 0, "AHA file padded to 1024 bytes")

# ---------------------------------------------------------------------------
# The vectorized decoder against a direct port of getann's reading loop
# (python/src/wfdbx/_annot.py), on random and truncated files.

ref_parse_mit <- function(D) {
  st <- new.env()
  st$pos <- 0
  st$eof <- FALSE
  L <- length(D)
  rdb <- function(n) {
    k <- max(0, min(n, L - st$pos))
    r <- if (k > 0) as.integer(D[st$pos + seq_len(k)]) else integer(0)
    st$pos <- st$pos + k
    if (k < n) st$eof <- TRUE
    r
  }
  g16 <- function() {
    b <- c(rdb(2), 255L, 255L)[1:2]
    b[1] + 256 * b[2]
  }
  g32 <- function() {
    x <- g16()
    y <- g16()
    if (x >= 32768) x <- x - 65536
    x * 65536 + y
  }
  tt <- 0
  word <- g16()
  while (word %/% 1024 == 59) {
    tt <- tt + g32()
    word <- g16()
  }
  out <- list()
  chan <- 0
  num <- 0
  eofend <- FALSE
  repeat {
    if (word == 0) break
    tt <- tt + word %% 1024
    a <- list(tt = tt, typ = cint8(word %/% 1024), sub = 0, toks = list())
    repeat {
      word <- g16()
      code <- word %/% 1024
      if (code < 59 || st$eof) break
      if (code == 59) {
        tt <- tt + g32()
      } else if (code == 61) {
        a$sub <- cint8(word %% 1024)
      } else if (code == 62) {
        chan <- (word %% 1024) %% 256
      } else if (code == 60) {
        num <- cint8(word %% 1024)
      } else if (code == 63) {
        ln <- word %% 256
        a$toks[[length(a$toks) + 1L]] <- list(ln = ln, d = rdb(2 * ((ln + 1) %/% 2)))
      }
    }
    a$chan <- chan
    a$num <- num
    out[[length(out) + 1L]] <- a
    if (st$eof) {
      eofend <- TRUE
      break
    }
  }
  list(a = out, eofend = eofend)
}

same_parse <- function(D) {
  R <- ref_parse_mit(D)
  P <- .ann_parse(D, FALSE)
  n <- length(R$a)
  if (P$N != n || P$eofend != R$eofend) return(FALSE)
  if (n == 0) return(TRUE)
  f <- function(k) vapply(R$a, function(a) as.numeric(a[[k]]), 0)
  if (!identical(P$tt, f("tt")) || !identical(P$typ, f("typ")) || !identical(P$sub, f("sub")) ||
      !identical(P$chan, f("chan")) || !identical(P$num, f("num"))) return(FALSE)
  if (!identical(as.integer(P$tokcnt), vapply(R$a, function(a) length(a$toks), 0L))) return(FALSE)
  toks <- unlist(lapply(R$a, `[[`, "toks"), recursive = FALSE)
  for (m in seq_along(toks)) {
    if (P$tokln[m] != toks[[m]]$ln) return(FALSE)
    d <- if (P$tokav[m] > 0) P$D[P$tokoff[m] + seq_len(P$tokav[m])] else integer(0)
    if (!identical(d, toks[[m]]$d)) return(FALSE)
  }
  TRUE
}

set.seed(42)
rand_words <- function(n) {
  code <- base::sample(c(0:58, 59, 59, 60, 61, 62, 63, 63, 63), n, TRUE,
                 prob = c(rep(1, 59), 4, 4, 4, 4, 4, 4, 4, 4))
  w <- code * 1024 + base::sample(0:1023, n, TRUE)
  w[code == 63] <- 63 * 1024 + base::sample(0:12, sum(code == 63), TRUE)
  w[base::sample(n, max(1, n %/% 50))] <- 0
  .ann_words(w)
}
ok <- TRUE
for (it in 1:150) {
  D <- rand_words(base::sample(1:120, 1))
  if (it %% 3 == 0) D <- D[seq_len(base::sample(0:length(D), 1))]       # truncated (odd lengths)
  if (it %% 7 == 0) D <- as.raw(base::sample(0:255, base::sample(0:60, 1), TRUE))
  if (!same_parse(D)) {
    ok <- FALSE
    cat("parse mismatch:", paste(as.integer(D), collapse = " "), "\n")
    break
  }
}
check(ok, "MIT decoder = reference reading loop (random files)")
for (f in c("100s.atr", "100a.atr", "fmt16.tst", "fmt16.mod", "fmt16.edf", "100s.ooo"))
  check(same_parse(rf(f)), paste("MIT decoder = reference:", f))

# Bulk getann against one getann at a time (same file opened twice).
cmp_bulk <- function(rec, ann, stat = WFDB_READ, chunks = c(1, 3, 7, 100, Inf), tmul = NULL) {
  wfdbquiet()
  on.exit(wfdbverbose())
  wfdbquit()
  if (annopen(rec, list(anninfo(ann, stat), anninfo(ann, stat))) < 0) return(TRUE)
  if (!is.null(tmul)) {
    setiafreq(0, tmul)
    setiafreq(1, tmul)
  }
  S <- list()
  repeat {
    r <- getann(0)
    S[[length(S) + 1L]] <- r
    if (r$stat != 0) break
  }
  B <- list()
  repeat {
    m <- base::sample(chunks, 1)
    A <- .getann_bulk(1, m)
    for (k in seq_along(A$time))
      B[[length(B) + 1L]] <- list(stat = 0, annot = list(time = A$time[k], anntyp = A$anntyp[k],
                                                         subtyp = A$subtyp[k], chan = A$chan[k],
                                                         num = A$num[k], aux = A$aux[[k]]))
    if (A$stat != 0) {
      B[[length(B) + 1L]] <- list(stat = A$stat, annot = NULL)
      break
    }
  }
  wfdbquit()
  same <- length(S) == length(B)
  if (same) for (k in seq_along(S)) {
    s <- S[[k]]
    b <- B[[k]]
    if (s$stat != b$stat || !identical(s$annot, b$annot)) {
      same <- FALSE
      break
    }
  }
  same
}
for (f in c("atr", "ooo", "mod", "tst", "edf")) {
  rec <- if (f %in% c("atr", "ooo")) "100s" else "fmt16"
  check(cmp_bulk(rec, f), paste("bulk getann = getann:", rec, f))
}
check(cmp_bulk("100a", "atr"), "bulk getann = getann: 100a")
check(cmp_bulk("100s", "aha", WFDB_AHA_READ), "bulk getann = getann: AHA")
check(cmp_bulk("100a", "atr", tmul = 1000), "bulk getann = getann: setiafreq")
ok <- TRUE
for (it in 1:60) {
  D <- rand_words(base::sample(1:150, 1))
  if (it %% 2 == 0) D <- D[seq_len(base::sample(0:length(D), 1))]
  writeBin(D, "100s.rnd")
  if (!cmp_bulk("100s", "rnd")) {
    ok <- FALSE
    cat("bulk mismatch:", paste(as.integer(D), collapse = " "), "\n")
    break
  }
  wfdbquit()
  annot_reset(tables = TRUE)
}
check(ok, "bulk getann = getann (random files, aux ring buffer)")

# Bulk putann against one putann at a time.
Sys.setenv(WFDBANNSORT = "0")
ok <- TRUE
for (it in 1:30) {
  n <- base::sample(1:200, 1)
  inorder <- it %% 3 != 0
  t <- if (inorder) cumsum(base::sample(c(0:2000, 3e9), n, TRUE, prob = c(rep(1, 2001), 3))) else
    base::sample(-5:5000, n, TRUE)
  A <- list(time = t, anntyp = base::sample(0:49, n, TRUE), subtyp = base::sample(c(0, 0, 0, -1, 5, 200), n, TRUE),
            chan = base::sample(c(0, 0, 1, 255, 300), n, TRUE), num = base::sample(c(0, 0, 3, -2, 130), n, TRUE),
            aux = lapply(seq_len(n), function(k)
              if (runif(1) < 0.2) .aux_from(as.raw(base::sample(1:255, base::sample(0:20, 1), TRUE))) else NULL))
  wfdbquiet()
  annopen("100s", list(anninfo("pa", WFDB_WRITE), anninfo("pb", WFDB_WRITE)))
  for (k in seq_len(n)) putann(0, lapply(A, function(x) if (is.list(x)) x[[k]] else x[k]))
  .putann_bulk(1, A)
  wfdbquit()
  wfdbverbose()
  if (!identical(rf("100s.pa"), rf("100s.pb"))) {
    ok <- FALSE
    break
  }
}
Sys.unsetenv("WFDBANNSORT")
check(ok, "bulk putann = putann")

# wrann's vectorized parser against its line-by-line parser.
wfdbquit()
sampfreq("100s")
txt <- c("    0:00.050       18     +    0    0    0\t(N\n",
         "    0:00.214       77     N    0    1    2\n",
         "    0:01.028      370     Z   -1    0    0\tnote\n",
         "    0:01.839      662     N    5    0    0\t", strrep("y", 300), "\n",
         "    0:02.628      946     xyzzy    0    0    0\n",
         "   1:02:03.456  1340082     V    0    0    0\n",
         "[12:34:56.809 31/12/1999]        5     N    0    1    0\n",
         "    0:02.628      946     \"    0    0    0\ta\tb\n")
D <- charToRaw(paste(txt, collapse = ""))
expect_equal(.wrann_fast(D), .wrann_lines(D), "wrann: vectorized parser = line parser")
expect_equal(.wrann_fast(charToRaw("    0:00.100       36\n")), NULL, "wrann: irregular line")

# vectorized formatting helpers
x <- list(NULL, .aux_from("abc"), as.raw(c(3, 65, 0, 66)), as.raw(0), .aux_from(""), as.raw(c(9, 1, 2)))
expect_equal(.aux_strings(x), vapply(x, function(a) if (is.null(a)) "" else aux_string(a), ""),
             ".aux_strings")
tt <- c(1, 359, 360, 1000000, 1296000, 1296001, 0, -5)
expect_equal(.fmstimstr_v(tt, .tfreq()), vapply(tt, mstimstr, ""), ".fmstimstr_v")
wfdbquit()
sampfreq("fmt16")
expect_equal(.fmstimstr_v(-tt, .tfreq()), vapply(-tt, mstimstr, ""), ".fmstimstr_v (base time)")
wfdbquit()

# sortann's list: in-order input, and out-of-order input with duplicates
so <- .ann_sort_order(c(1, 2, 2, 3), c(0, 0, 1, 0), c(0, 0, 0, 0))
expect_equal(so, list(order = 1:4, in_order = TRUE), "sortann order: in order")
so <- .ann_sort_order(c(5, 1, 3, 3, 2), c(0, 0, 0, 0, 0), c(0, 0, 0, 0, 0))
expect_equal(so, list(order = c(2L, 5L, 4L, 1L), in_order = FALSE), "sortann order: duplicates")

# ---------------------------------------------------------------------------
# Out-of-order output annotations: sorted when the file is closed (wfdb-x: in
# this process; in legacy mode, by running sortann, as the C library)
# (python test_annotations.py::test_sort_in_process and following)

# ties in time, num and chan, duplicates (the last one is kept), NOTQRS
# (dropped), aux strings, and a time 0 annotation that follows later ones
# (lost by the original sortann, as in legacy mode; see
# docs/KNOWN_C_BEHAVIORS.md)
tricky <- data.frame(
  time = c(100, 50, 100, 100, 100, 75, 75, 10, 200, 150, 150, 20, 0, 5, 5000),
  code = c(NORMAL, PVC, APC, NORMAL, PVC, NOTQRS, NORMAL, NOTQRS, RHYTHM, NOISE, NOISE,
           NORMAL, NORMAL, NORMAL, NORMAL),
  sub = c(0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0),
  chan = c(0, 0, 1, 0, 0, 2, 2, 0, 0, 3, 3, 0, 0, 1, 0),
  num = c(0, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0),
  aux = c(NA, "(VT", NA, "num 1", "replaces N", NA, "odd", NA, "(AFIB", NA, NA,
          strrep("x", 101), NA, NA, NA), stringsAsFactors = FALSE)
write_tricky <- function(name, ...) {
  write_annotations("100s", name, tricky$time, code = tricky$code, subtype = tricky$sub,
                    chan = tricky$chan, num = tricky$num, aux = tricky$aux, ...)
  rf(paste0("100s.", name))
}
read_all <- function(name) {
  annopen("100s", list(anninfo(name, WFDB_READ)), 1)
  A <- .getann_bulk(0, Inf)
  wfdbquit()
  A
}
read_ticks <- function(name) {        # (time in ticks of 1000 Hz, anntyp, chan, num)
  annopen("100s", list(anninfo(name, WFDB_READ)), 1)
  setiafreq(0, 1000)
  A <- .getann_bulk(0, Inf)
  wfdbquit()
  cbind(A$time, A$anntyp, A$chan, A$num)
}
if (.mode == "source") .wfdb_io$driver <- file.path(dirname(.rdir), "inst", "bin", "wfdbx.R")
setannstr(42, "Z")                        # (a definition table in the file)
setafreq(1000)                            # (a time resolution)
write_tricky("leg", legacy = TRUE)
expect_equal(wfdberror(), "done!\n", "sort (legacy, sortann): done")
setafreq(1000)
# modern mode: no subprocess
aenv <- environment(oannclose)
run_sortann <- get(".ann_run_sortann", aenv)
assign(".ann_run_sortann", function(...) stop("sortann run in modern mode"), envir = aenv)
modern <- tryCatch(write_tricky("mod"), finally = assign(".ann_run_sortann", run_sortann, envir = aenv))
expect_equal(wfdberror(), "done!\n", "sort (in process): done")
expect_equal(.ann$annclose_error, -6, "sort (in process): annclose_error -6, as C")
# (the library's settings and tables are unchanged)
check(getafreq() == 1000 && annstr(42) == "Z" && identical(which(.ann$modified), 43L),
      "sort (in process): library state unchanged")
# the in-process sort and the sortann tool (wfdb-x) give the same bytes
Sys.setenv(WFDBANNSORT = "0")
wfdbquiet()
write_tricky("uns")
wfdbverbose()
setafreq(0)
expect_equal(app_sortann(c("-r", "100s", "-a", "uns")), 0, "sortann tool: status")
Sys.unsetenv("WFDBANNSORT")
expect_equal(rf("100s.uns"), modern, "sort: in process == sortann tool (byte for byte)")
setafreq(0)
annopen("100s", list(anninfo("leg", WFDB_READ)), 1)
expect_equal(annstr(42), "Z", "sort: definition table kept")
wfdbquit()
# legacy mode (the original sortann): the annotation at time 0 is lost, and
# so is the one at time 5 inserted after it
rest <- cbind(c(20, 50, 75, 100, 100, 100, 150, 150, 200, 5000),
              c(NORMAL, PVC, NORMAL, PVC, APC, NORMAL, NOISE, NOISE, RHYTHM, NORMAL),
              c(0, 0, 2, 0, 1, 0, 3, 3, 0, 0), c(0, 0, 0, 0, 0, 1, -1, 0, 0, 0))
expect_equal(read_ticks("leg"), rest, "sort (legacy): order, duplicates, NOTQRS, loss as sortann")
# wfdb-x: nothing is lost
expect_equal(read_ticks("mod"), rbind(c(0, NORMAL, 0, 0), c(5, NORMAL, 1, 0), rest),
             "sort: nothing lost")
setannstr(-42, "[42]")
.ann$modified[43] <- FALSE

# the list (insert_ann): 5, 0, 3 (wfdb-x: 0, 3, 5; legacy, as sortann: 5)
for (lg in c(FALSE, TRUE)) {
  so <- .ann_sort_order(c(5, 0, 3), c(0, 0, 0), c(0, 0, 0), legacy = lg)
  expect_equal(so, list(order = if (lg) 1L else c(2L, 3L, 1L), in_order = FALSE),
               paste("sort order: time 0 after later ones, legacy", lg))
  # a later annotation at time 0 replaces a real one, and one at time 0 on
  # another channel is kept (both modes)
  so <- .ann_sort_order(c(0, 7, 0, 0), c(0, 0, 0, 0), c(0, 0, 1, 0), legacy = lg)
  expect_equal(so$order, c(4L, 3L, 2L), paste("sort order: time 0 duplicates, legacy", lg))
}

# legacy mode with an output directory: the sortann program runs in that
# directory (where the file is), with --legacy; the result is that of the
# modern sort
dir.create("lout")
tt <- c(300, 100, 200, 100, 50)
ss <- c("N", "V", "N", "A", "N")
wfdbquiet()                               # (the child: no header for rec)
write_annotations("rec", "leg", tt, symbol = ss, dir = "lout", legacy = TRUE)
expect_equal(wfdberror(), "done!\n", "legacy sort in output dir: done")
write_annotations("rec", "mod", tt, symbol = ss, dir = "lout")
expect_equal(sort(list.files("lout")), c("rec.leg", "rec.mod"), "legacy sort in output dir: files")
expect_equal(rf("lout/rec.leg"), rf("lout/rec.mod"), "legacy sort in output dir == modern")
a <- read_annotations("lout/rec", "leg", fs = 360)
wfdbverbose()
check(identical(a$sample, c(50, 100, 200, 300)) && a$symbol[2L] == "A",
      "legacy sort in output dir: sorted")

# a file that cannot be read completely: not rewritten
wf_bytes <- as.raw(c(10, 4, 5, 4, 1))     # (N at 10, N at 15, then a truncated word)
writeBin(wf_bytes, "trunc.atr")
wfdbquiet()
expect_equal(.ann_sort_file("trunc.atr", "atr"), -1, "sort: truncated file fails")
wfdbverbose()
expect_equal(rf("trunc.atr"), wf_bytes, "sort: truncated file untouched")

# WFDBANNSORT=0: not sorted
Sys.setenv(WFDBANNSORT = "0")
wfdbquiet()
write_tricky("ns")
expect_equal(wfdberror(), "to rearrange annotations in the correct order.\n",
             "WFDBANNSORT=0: message")
Sys.unsetenv("WFDBANNSORT")
expect_equal(read_all("ns")$time, tricky$time, "WFDBANNSORT=0: file not sorted")
wfdbverbose()

# an input annotator and the signals stay open while an output annotator is
# closed and sorted
expect_equal(isigopen("100s", 2)$nsig, 2, "sort: isigopen")
expect_equal(annopen("100s", list(anninfo("atr", WFDB_READ), anninfo("o1", WFDB_WRITE),
                                  anninfo("o2", WFDB_WRITE))), 0, "sort: annopen")
first <- getann(0)$annot
for (t in c(30, 10, 20)) {
  putann(0, annotation(t, NORMAL))
  putann(1, annotation(t, PVC))
}
wfdbquiet()
oannclose(0)                              # (sorted now; o2 becomes output annotator 0)
wfdbverbose()
r <- getann(0)
check(r$stat == 0 && r$annot$time == 77 && first$time == 18, "sort: input annotator intact")
r <- getvec()
check(r$stat == 2 && identical(r$v[1:2], c(995, 1011)), "sort: signals intact")
putann(0, annotation(40, PVC))
wfdbquiet()
wfdbquit()
wfdbverbose()
o1 <- read_annotations("100s", "o1")
o2 <- read_annotations("100s", "o2")
check(identical(o1$sample, c(10, 20, 30)) && all(o1$symbol == "N"), "sort: o1 sorted")
expect_equal(o2$sample, c(10, 20, 30, 40), "sort: o2 sorted")

# write_annotations(..., dir = ) (wfdb-x)
dir.create("out")
wfdbquiet()
write_annotations("rec", "atr", c(30, 10, 20), symbol = c("N", "V", "N"), dir = "out")
expect_equal(list.files("out"), "rec.atr", "write_annotations dir: file")
expect_equal(wfdbx_get_output_dir(), NULL, "write_annotations dir: output dir restored")
a <- read_annotations("out/rec", "atr")   # (sorted in place)
wfdbverbose()
check(identical(a$sample, c(10, 20, 30)) && a$symbol[1L] == "V", "write_annotations dir: sorted")
expect_error(write_annotations("rec", "atr", 1, symbol = "N", dir = "nosuch"),
             "write_annotations dir: missing dir")
expect_error(write_annotations("x/rec", "atr", 1, symbol = "N", dir = "out"),
             "write_annotations dir: record with a directory")
expect_equal(wfdbx_get_output_dir(), NULL, "write_annotations dir: restored after errors")
# the dir checks come first (wfdb-x)
errmsg <- function(expr) tryCatch({
  expr
  ""
}, error = function(e) conditionMessage(e))
expect_equal(errmsg(write_annotations("x/rec", "atr", 1, dir = "out")),
             "record name must not contain a directory when dir is given",
             "write_annotations dir checks first: record")
expect_equal(errmsg(write_annotations("rec", "atr", 1, dir = "nosuch")),
             "directory nosuch does not exist", "write_annotations dir checks first: dir")
expect_equal(errmsg(write_annotations("rec", "atr", 1, dir = "out")),
             "symbol or code must be given", "write_annotations dir checks first: then the rest")
}
