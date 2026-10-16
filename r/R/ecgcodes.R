# ecgcodes.R: annotation codes and mapping tables (port of lib/ecgcodes.h
# and lib/ecgmap.h), and the constructors of the structures of the C API
# (WFDB_Siginfo, WFDB_Anninfo, WFDB_Annotation, WFDB_Calinfo,
# WFDB_Seginfo).
#
# Copyright (C) 1999 George B. Moody (original C headers, lib/ecgcodes.h, by
# T. Baker and G. Moody, and lib/ecgmap.h). The structure constructors are
# wfdb-x's own.
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).
#
# The annotation codes are exported as constants (doubles, as all numbers
# in this package): NORMAL, PVC, ...; ecgcodes() returns them all as a
# named list.  The mapping functions (isann, isqrs, map1, map2, ammap,
# mamap, annpos) are vectorized over the code; their C library function
# versions are also provided under the C names (wfdb_isann, ...).

NOTQRS <- 0      # not-QRS (not a getann/putann code)
NORMAL <- 1      # normal beat
LBBB <- 2        # left bundle branch block beat
RBBB <- 3        # right bundle branch block beat
ABERR <- 4       # aberrated atrial premature beat
PVC <- 5         # premature ventricular contraction
FUSION <- 6      # fusion of ventricular and normal beat
NPC <- 7         # nodal (junctional) premature beat
APC <- 8         # atrial premature contraction
SVPB <- 9        # premature or ectopic supraventricular beat
VESC <- 10       # ventricular escape beat
NESC <- 11       # nodal (junctional) escape beat
PACE <- 12       # paced beat
UNKNOWN <- 13    # unclassifiable beat
NOISE <- 14      # signal quality change
ARFCT <- 16      # isolated QRS-like artifact
STCH <- 18       # ST change
TCH <- 19        # T-wave change
SYSTOLE <- 20    # systole
DIASTOLE <- 21   # diastole
NOTE <- 22       # comment annotation
MEASURE <- 23    # measurement annotation
PWAVE <- 24      # P-wave peak
BBB <- 25        # left or right bundle branch block
PACESP <- 26     # non-conducted pacer spike
TWAVE <- 27      # T-wave peak
RHYTHM <- 28     # rhythm change
UWAVE <- 29      # U-wave peak
LEARN <- 30      # learning
FLWAV <- 31      # ventricular flutter wave
VFON <- 32       # start of ventricular flutter/fibrillation
VFOFF <- 33      # end of ventricular flutter/fibrillation
AESC <- 34       # atrial escape beat
SVESC <- 35      # supraventricular escape beat
LINK <- 36       # link to external data (aux contains URL)
NAPC <- 37       # non-conducted P-wave (blocked APB)
PFUS <- 38       # fusion of paced and normal beat
WFON <- 39       # waveform onset
PQ <- 39         # PQ junction (beginning of QRS)
WFOFF <- 40      # waveform end
JPT <- 40        # J point (end of QRS)
RONT <- 41       # R-on-T premature ventricular contraction
ACMAX <- 49      # value of largest valid annot code (must be < 50)

# Annotation position codes
APUNDEF <- 0
APSTD <- 1
APHIGH <- 2
APLOW <- 3
APATT <- 4
APAHIGH <- 5
APALOW <- 6

.ecg_names <- c("NOTQRS", "NORMAL", "LBBB", "RBBB", "ABERR", "PVC", "FUSION",
                "NPC", "APC", "SVPB", "VESC", "NESC", "PACE", "UNKNOWN",
                "NOISE", "ARFCT", "STCH", "TCH", "SYSTOLE", "DIASTOLE", "NOTE",
                "MEASURE", "PWAVE", "BBB", "PACESP", "TWAVE", "RHYTHM",
                "UWAVE", "LEARN", "FLWAV", "VFON", "VFOFF", "AESC", "SVESC",
                "LINK", "NAPC", "PFUS", "WFON", "PQ", "WFOFF", "JPT", "RONT",
                "ACMAX", "APUNDEF", "APSTD", "APHIGH", "APLOW", "APATT",
                "APAHIGH", "APALOW")

#' All annotation codes and position codes, as a named list.
ecgcodes <- function() mget(.ecg_names, envir = environment(sys.function()))

# Mapping tables (indexed by code + 1); the setters modify them.
.ecgmap <- new.env(parent = emptyenv())

ecgmap_reset <- function() {
  m <- .ecgmap
  m$qrs <- c(0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
             1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
             1, 1, 0, 0, 1, 1, 0, 0, 1, 0,
             0, 1, 0, 0, 0, 0, 0, 0, 0, 0)
  m$mp1 <- c(0, 1, 1, 1, 1, 5, 6, 1, 1, 1,
             5, 1, 1, 1, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
             30, 5, 0, 0, 1, 1, 0, 0, 1, 0,
             0, 5, 0, 0, 0, 0, 0, 0, 0, 0)
  m$mp2 <- c(0, 1, 1, 1, 9, 5, 6, 9, 9, 9,
             5, 1, 1, 1, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
             30, 5, 0, 0, 1, 1, 0, 0, 1, 0,
             0, 5, 0, 0, 0, 0, 0, 0, 0, 0)
  m$annp <- c(0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 2, 0, 2, 0, 2, 2,
              2, 2, 2, 2, 2, 1, 2, 2, 3, 2,
              1, 1, 1, 1, 1, 1, 2, 2, 1, 2,
              2, 1, 0, 0, 0, 0, 0, 0, 0, 0)
  invisible()
}
ecgmap_reset()

# AHA code (character code 'E'..']') to MIT code
.ammp <- c(10, 6, 0, 0, 0,        # 'E' - 'I'
           0, 0, 0, 0, 1,         # 'J' - 'N'
           22, 12, 13, 41, 0,     # 'O' - 'S'
           0, 14, 5, 0, 0,        # 'T' - 'X'
           0, 0, 32, 0, 33)       # 'Y' - ']'
# MIT code to AHA code (character codes)
.mamp <- as.numeric(charToRaw(paste0("ONNNN", "VFNNN", "ENPQU", "OOOOO", "OOOOO",
                                     "NOOOO", "QO[]N", "NOONO", "OROOO", "OOOOO")))

#' TRUE if a is a legal annotation code (vectorized).
isann <- function(a) a > 0 & a <= ACMAX

#' 1 if annotation code a denotes a QRS complex, 0 otherwise (vectorized).
isqrs <- function(a) {
  r <- numeric(length(a))
  k <- isann(a)
  r[k] <- .ecgmap$qrs[a[k] + 1]
  r
}

#' Map codes into {NOTQRS, NORMAL, PVC, FUSION, LEARN} (vectorized).
map1 <- function(a) {
  r <- numeric(length(a))
  k <- isann(a)
  r[k] <- .ecgmap$mp1[a[k] + 1]
  r
}

#' Map codes into {NOTQRS, NORMAL, SVPB, PVC, FUSION, LEARN} (vectorized).
map2 <- function(a) {
  r <- numeric(length(a))
  k <- isann(a)
  r[k] <- .ecgmap$mp2[a[k] + 1]
  r
}

#' Annotation position code of a (vectorized).
annpos <- function(a) {
  r <- numeric(length(a))
  k <- isann(a)
  r[k] <- .ecgmap$annp[a[k] + 1]
  r
}

#' Map AHA annotation codes (character codes) into MIT codes (vectorized).
ammap <- function(a) {
  r <- numeric(length(a))
  k <- a > 68 & a <= 93            # 'D' < a <= ']'
  r[k] <- .ammp[a[k] - 68]
  r
}

#' Map MIT code a, subtype s, into an AHA annotation code (a character
#' code; vectorized).
mamap <- function(a, s) {
  r <- rep(79, length(a))          # 'O'
  k <- isann(a)
  m <- .mamp[a[k] + 1]
  ss <- rep_len(s, length(a))[k]
  m[m == 85 & ss != -1] <- 79      # 'U' only for subtype -1
  r[k] <- m
  r
}

# The setters store the value in a C char (signed), as ecgmap.h does.
.ecg_set <- function(tab, a, x, dflt) {
  if (isann(a)) {
    v <- cint8(x)
    .ecgmap[[tab]][a + 1] <- v
    v
  } else dflt
}
setisqrs <- function(a, x) .ecg_set("qrs", a, x, 0)
setmap1 <- function(a, x) .ecg_set("mp1", a, x, NOTQRS)
setmap2 <- function(a, x) .ecg_set("mp2", a, x, NOTQRS)
setannpos <- function(a, x) .ecg_set("annp", a, x, APUNDEF)

# Function versions with the names of the C library.
wfdb_isann <- isann
wfdb_isqrs <- isqrs
wfdb_setisqrs <- setisqrs
wfdb_map1 <- map1
wfdb_setmap1 <- setmap1
wfdb_map2 <- map2
wfdb_setmap2 <- setmap2
wfdb_ammap <- ammap
wfdb_mamap <- mamap
wfdb_annpos <- annpos
wfdb_setannpos <- setannpos

# ---------------------------------------------------------------------------
# Structures of the C API: lists with the C field names.  C NULL strings are
# NULL (note: in R, `x$f <- NULL` deletes a field; use `x["f"] <- list(NULL)`).

#' WFDB_Siginfo.
siginfo <- function(fname = NULL, desc = NULL, units = NULL, gain = 0,
                    initval = 0, group = 0, fmt = 0, spf = 1, bsize = 0,
                    adcres = 0, adczero = 0, baseline = 0, nsamp = 0,
                    cksum = 0) {
  list(fname = fname, desc = desc, units = units, gain = gain,
       initval = initval, group = group, fmt = fmt, spf = spf, bsize = bsize,
       adcres = adcres, adczero = adczero, baseline = baseline,
       nsamp = nsamp, cksum = cksum)
}

#' WFDB_Anninfo.
anninfo <- function(name = NULL, stat = WFDB_READ) list(name = name, stat = stat)

#' WFDB_Annotation.  aux is NULL or a raw vector whose first byte is the
#' length of the data that follows.
annotation <- function(time = 0, anntyp = 0, subtyp = 0, chan = 0, num = 0,
                       aux = NULL) {
  list(time = time, anntyp = anntyp, subtyp = subtyp, chan = chan, num = num,
       aux = aux)
}

#' WFDB_Calinfo.
calinfo <- function(low = 0, high = 0, scale = 0, sigtype = NULL,
                    units = NULL, caltype = 0) {
  list(low = low, high = high, scale = scale, sigtype = sigtype,
       units = units, caltype = caltype)
}

#' WFDB_Seginfo.
seginfo <- function(recname = "", nsamp = 0, samp0 = 0) {
  list(recname = recname, nsamp = nsamp, samp0 = samp0)
}
