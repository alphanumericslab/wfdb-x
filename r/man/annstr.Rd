\name{annstr}
\alias{annstr}
\alias{strann}
\alias{setannstr}
\alias{anndesc}
\alias{setanndesc}
\alias{ecgstr}
\alias{strecg}
\alias{setecgstr}
\title{Annotation Mnemonics and Descriptions}
\description{
  Convert between numeric annotation codes (such as \code{NORMAL} or
  \code{PVC}) and their mnemonics (such as \code{"N"} or \code{"V"}) or
  descriptions, and redefine them.
}
\usage{
annstr(code)
strann(s)
setannstr(code, s)
anndesc(code)
setanndesc(code, s)
ecgstr(code)
strecg(s)
setecgstr(code, s)
}
\arguments{
  \item{code}{annotation codes (see \code{\link{ecgcodes}}).
    \code{annstr} and \code{ecgstr} accept a vector; the other functions a
    single code.  For \code{setannstr} and \code{setanndesc}, a negative
    value \code{-code} redefines \code{code} without marking it as
    modified (see Details).}
  \item{s}{\code{strann}, \code{strecg}: mnemonics (a character vector).
    The setters: the new mnemonic or description (a character string).}
}
\details{
  There are two tables of mnemonics.  The one used by \code{annstr},
  \code{strann} and \code{anndesc} (and by the annotation tools such as
  \command{rdann}) can be redefined by \code{setannstr} and
  \code{setanndesc}, and by the modification labels of the annotation
  files read (see \code{\link{annopen}}).  When \code{setannstr} or
  \code{setanndesc} is given a positive code, the code is marked as
  modified, and its new definition is written as a modification label at
  the start of the annotation files written afterwards; with a negative
  code, it is not.

  The table used by \code{ecgstr} and \code{strecg} keeps the standard
  mnemonics, unless it is changed with \code{setecgstr}.

  The tables are not reset by \code{\link{wfdbquit}}.
}
\value{
  \code{annstr} and \code{ecgstr} return the mnemonics of the codes (a
  character vector).  Codes that have no mnemonic, including codes out of
  range (not between 0 and \code{ACMAX}), give the code in brackets, such
  as \code{"[43]"}.

  \code{strann} and \code{strecg} return the codes of the mnemonics (a
  numeric vector), \code{NOTQRS} (0) for strings that are not mnemonics.

  \code{anndesc} returns the description of a code (a character string),
  \code{NULL} if it has none, or \code{"illegal annotation code"} if the
  code is out of range.

  The setters return 0, or -1 for an illegal code.
}
\section{Origin}{
  Translation of the C functions annstr(), strann(), setannstr(),
  anndesc(), setanndesc(), ecgstr(), strecg() and setecgstr()
  (lib/annot.c, WFDB 10.7.0): same arguments and results.
}
\seealso{
  \code{\link{ecgcodes}} for the list of codes; \code{\link{isqrs}} and
  \code{\link{map1}} for classifying them.
}
\examples{
annstr(c(NORMAL, PVC, 99))
strann(c("N", "V", "xyz"))
anndesc(PVC)

## give code 43 (unused by default) a mnemonic and a description
## (negative code: not marked as modified, so annotation files written
## later do not record these definitions)
annstr(43)
setannstr(-43, "Z")
setanndesc(-43, "my event")
annstr(43)
strann("Z")
anndesc(43)
}
