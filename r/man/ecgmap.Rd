\name{isann}
\alias{isann}
\alias{isqrs}
\alias{setisqrs}
\alias{map1}
\alias{setmap1}
\alias{map2}
\alias{setmap2}
\alias{ammap}
\alias{mamap}
\alias{annpos}
\alias{setannpos}
\alias{wfdb_isann}
\alias{wfdb_isqrs}
\alias{wfdb_setisqrs}
\alias{wfdb_map1}
\alias{wfdb_setmap1}
\alias{wfdb_map2}
\alias{wfdb_setmap2}
\alias{wfdb_ammap}
\alias{wfdb_mamap}
\alias{wfdb_annpos}
\alias{wfdb_setannpos}
\title{Classification and Mapping of Annotation Codes}
\description{
  Classify annotation codes (is it a legal code, is it a QRS complex?),
  map them into the simpler classes used by beat classifiers, convert
  between MIT and AHA annotation codes, and give annotation positions.
  These are the macros of \file{ecgmap.h} in C; they are also available
  under the names of the corresponding C library functions
  (\code{wfdb_isann}, \code{wfdb_isqrs}, \ldots), which are the same R
  functions.
}
\usage{
isann(a)
isqrs(a)
setisqrs(a, x)
map1(a)
setmap1(a, x)
map2(a)
setmap2(a, x)
ammap(a)
mamap(a, s)
annpos(a)
setannpos(a, x)
}
\arguments{
  \item{a}{annotation codes (see \code{\link{ecgcodes}}): a numeric
    vector for the query functions, a single code for the setters.  For
    \code{ammap}, AHA annotation codes, given as character codes (for
    example \code{utf8ToInt("V")}).}
  \item{s}{annotation subtypes (\code{mamap}; recycled).}
  \item{x}{the new value of the table entry for code \code{a}.  As in C,
    it is stored in a signed byte, so it is taken modulo 256 in the range
    -128 to 127.}
}
\details{
  The query functions are vectorized over \code{a}.  The setters change
  the tables used by the query functions for the rest of the R session
  (they are not reset by \code{\link{wfdbquit}}).
}
\value{
  \code{isann} returns \code{TRUE} for legal annotation codes (1 to
  \code{ACMAX}), \code{FALSE} otherwise.

  \code{isqrs} returns 1 for codes that denote QRS complexes (beats), 0
  otherwise.

  \code{map1} maps codes into \code{NOTQRS}, \code{NORMAL}, \code{PVC},
  \code{FUSION} and \code{LEARN}; \code{map2} into the same classes and
  \code{SVPB}.

  \code{ammap} maps AHA codes into MIT codes; \code{mamap} maps MIT codes
  (and subtypes) into AHA codes, returned as character codes (use
  \code{intToUtf8} to get the letters).

  \code{annpos} returns annotation position codes (\code{APUNDEF},
  \code{APSTD}, \ldots; see \code{\link{ecgcodes}}).

  The query functions return 0 (\code{NOTQRS}, \code{APUNDEF}) for
  illegal codes.  The setters return the value stored, or 0 if \code{a}
  is not a legal code (and nothing is stored).
}
\seealso{\code{\link{ecgcodes}}, \code{\link{annstr}}.}
\examples{
isqrs(c(NORMAL, NOTE, PVC))
map1(c(NORMAL, APC, PVC, RONT))
map2(APC)
intToUtf8(mamap(PVC, 0))
ammap(utf8ToInt("V")) == PVC
}
