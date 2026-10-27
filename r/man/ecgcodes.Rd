\name{ecgcodes}
\alias{ecgcodes}
\alias{NOTQRS}
\alias{NORMAL}
\alias{LBBB}
\alias{RBBB}
\alias{ABERR}
\alias{PVC}
\alias{FUSION}
\alias{NPC}
\alias{APC}
\alias{SVPB}
\alias{VESC}
\alias{NESC}
\alias{PACE}
\alias{UNKNOWN}
\alias{NOISE}
\alias{ARFCT}
\alias{STCH}
\alias{TCH}
\alias{SYSTOLE}
\alias{DIASTOLE}
\alias{NOTE}
\alias{MEASURE}
\alias{PWAVE}
\alias{BBB}
\alias{PACESP}
\alias{TWAVE}
\alias{RHYTHM}
\alias{UWAVE}
\alias{LEARN}
\alias{FLWAV}
\alias{VFON}
\alias{VFOFF}
\alias{AESC}
\alias{SVESC}
\alias{LINK}
\alias{NAPC}
\alias{PFUS}
\alias{WFON}
\alias{PQ}
\alias{WFOFF}
\alias{JPT}
\alias{RONT}
\alias{ACMAX}
\alias{APUNDEF}
\alias{APSTD}
\alias{APHIGH}
\alias{APLOW}
\alias{APATT}
\alias{APAHIGH}
\alias{APALOW}
\title{Annotation Codes}
\description{
  The annotation type codes of the WFDB library (\file{ecgcodes.h} in C),
  such as \code{NORMAL} (a normal beat) or \code{PVC} (a premature
  ventricular contraction), and the annotation position codes, as numeric
  constants.  \code{ecgcodes()} returns all of them as a named list.
}
\usage{
ecgcodes()
}
\details{
  The annotation codes, with their standard mnemonics (see
  \code{\link{annstr}}) and meanings, are:
  \tabular{lrll}{
    \strong{Code} \tab \strong{Value} \tab \strong{Mnemonic} \tab \strong{Meaning} \cr
    \code{NOTQRS} \tab 0 \tab  \tab not an annotation (used as a value only) \cr
    \code{NORMAL} \tab 1 \tab \code{"N"} \tab normal beat \cr
    \code{LBBB} \tab 2 \tab \code{"L"} \tab left bundle branch block beat \cr
    \code{RBBB} \tab 3 \tab \code{"R"} \tab right bundle branch block beat \cr
    \code{ABERR} \tab 4 \tab \code{"a"} \tab aberrated atrial premature beat \cr
    \code{PVC} \tab 5 \tab \code{"V"} \tab premature ventricular contraction \cr
    \code{FUSION} \tab 6 \tab \code{"F"} \tab fusion of ventricular and normal beat \cr
    \code{NPC} \tab 7 \tab \code{"J"} \tab nodal (junctional) premature beat \cr
    \code{APC} \tab 8 \tab \code{"A"} \tab atrial premature contraction \cr
    \code{SVPB} \tab 9 \tab \code{"S"} \tab premature or ectopic supraventricular beat \cr
    \code{VESC} \tab 10 \tab \code{"E"} \tab ventricular escape beat \cr
    \code{NESC} \tab 11 \tab \code{"j"} \tab nodal (junctional) escape beat \cr
    \code{PACE} \tab 12 \tab \code{"/"} \tab paced beat \cr
    \code{UNKNOWN} \tab 13 \tab \code{"Q"} \tab unclassifiable beat \cr
    \code{NOISE} \tab 14 \tab \code{"~"} \tab signal quality change \cr
    \code{ARFCT} \tab 16 \tab \code{"|"} \tab isolated QRS-like artifact \cr
    \code{STCH} \tab 18 \tab \code{"s"} \tab ST change \cr
    \code{TCH} \tab 19 \tab \code{"T"} \tab T-wave change \cr
    \code{SYSTOLE} \tab 20 \tab \code{"*"} \tab systole \cr
    \code{DIASTOLE} \tab 21 \tab \code{"D"} \tab diastole \cr
    \code{NOTE} \tab 22 \tab \code{'"'} \tab comment annotation \cr
    \code{MEASURE} \tab 23 \tab \code{"="} \tab measurement annotation \cr
    \code{PWAVE} \tab 24 \tab \code{"p"} \tab P-wave peak \cr
    \code{BBB} \tab 25 \tab \code{"B"} \tab left or right bundle branch block \cr
    \code{PACESP} \tab 26 \tab \code{"^"} \tab non-conducted pacer spike \cr
    \code{TWAVE} \tab 27 \tab \code{"t"} \tab T-wave peak \cr
    \code{RHYTHM} \tab 28 \tab \code{"+"} \tab rhythm change \cr
    \code{UWAVE} \tab 29 \tab \code{"u"} \tab U-wave peak \cr
    \code{LEARN} \tab 30 \tab \code{"?"} \tab learning \cr
    \code{FLWAV} \tab 31 \tab \code{"!"} \tab ventricular flutter wave \cr
    \code{VFON} \tab 32 \tab \code{"["} \tab start of ventricular flutter/fibrillation \cr
    \code{VFOFF} \tab 33 \tab \code{"]"} \tab end of ventricular flutter/fibrillation \cr
    \code{AESC} \tab 34 \tab \code{"e"} \tab atrial escape beat \cr
    \code{SVESC} \tab 35 \tab \code{"n"} \tab supraventricular escape beat \cr
    \code{LINK} \tab 36 \tab \code{"@"} \tab link to external data (aux contains URL) \cr
    \code{NAPC} \tab 37 \tab \code{"x"} \tab non-conducted P-wave (blocked APB) \cr
    \code{PFUS} \tab 38 \tab \code{"f"} \tab fusion of paced and normal beat \cr
    \code{WFON} \tab 39 \tab \code{"("} \tab waveform onset \cr
    \code{PQ} \tab 39 \tab \code{"("} \tab PQ junction (beginning of QRS) \cr
    \code{WFOFF} \tab 40 \tab \code{")"} \tab waveform end \cr
    \code{JPT} \tab 40 \tab \code{")"} \tab J point (end of QRS) \cr
    \code{RONT} \tab 41 \tab \code{"r"} \tab R-on-T premature ventricular contraction \cr
    \code{ACMAX} \tab 49 \tab \tab the largest valid annotation code \cr
  }
  Codes 15, 17 and 42 to 49 have no predefined meaning; their mnemonics
  are \code{"[15]"}, \code{"[17]"}, \code{"[42]"}, and so on.  They can
  be given a meaning with \code{\link{setannstr}} and
  \code{\link{setanndesc}}.

  The annotation position codes, returned by \code{\link{annpos}}, are
  \code{APUNDEF} (0), \code{APSTD} (1), \code{APHIGH} (2), \code{APLOW}
  (3), \code{APATT} (4), \code{APAHIGH} (5) and \code{APALOW} (6).
}
\value{\code{ecgcodes()} returns a named list of all these constants.}
\section{Origin}{
  \code{ecgcodes()} is part of wfdb-x; not in the original WFDB package.

  Translation of the constants of lib/ecgcodes.h and of the annotation
  position codes of lib/ecgmap.h (WFDB 10.7.0): same names and values.
}
\seealso{
  \code{\link{annstr}} for mnemonics and descriptions;
  \code{\link{isqrs}} and \code{\link{map1}} for classifying codes.
}
\examples{
PVC
ecgcodes()$NORMAL
annstr(c(NORMAL, PVC, APC))
anndesc(RONT)
}
