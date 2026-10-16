// annot.cpp: WFDB library functions for annotations (C++ port of lib/annot.c)
//
// This file contains annopen, getann, ungetann, putann, iannsettime, the
// annotation code/mnemonic/description conversion functions (ecgstr,
// strecg, setecgstr, annstr, strann, setannstr, anndesc, setanndesc), the
// time resolution functions (setafreq, getafreq, setiafreq, getiafreq,
// getiaorigfreq), iannclose, oannclose, the function versions of the
// <ecgmap.h> macros (wfdb_isann, ...), and the library-private functions
// wfdb_anclose and wfdb_oaflush.
//
// Modification labels (NOTE annotations at time 0 that redefine annotation
// mnemonics and descriptions, and the time resolution record) are read by
// annopen and written before the first annotation of each output file.
// Output files whose annotations are not in canonical order are sorted when
// they are closed, by running the sortann program.
//
// Copyright (C) 1989-2013 George B. Moody (original C implementation,
// lib/annot.c; revised 2015-2020 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdblib.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace wfdbx {
namespace detail {

namespace {

// Annotation word format
constexpr unsigned CODE = 0176000;  // annotation code segment of word
constexpr int CS = 10;              // places by which code must be shifted
constexpr unsigned DATA = 01777;    // data segment of annotation word
constexpr unsigned MAXRR = 01777;   // longest interval coded in a word

constexpr long MAXSKIP = 0x7fffffff;    // largest interval of a SKIP
constexpr long MINSKIP = -0x7fffffff;   // smallest interval of a SKIP

// Pseudo-annotation codes
constexpr unsigned PAMIN = 59u << CS;
constexpr unsigned SKIP = 59u << CS;    // long null annotation
constexpr unsigned NUM = 60u << CS;     // change 'num' field
constexpr unsigned SUB = 61u << CS;     // subtype
constexpr unsigned CHN = 62u << CS;     // change 'chan' field
constexpr unsigned AUX = 63u << CS;     // auxiliary information

// Constants for AHA annotation files only
constexpr int ABLKSIZ = 1024;   // AHA annotation file block length
constexpr unsigned AUXBUFLEN = 771;   // size of the aux string buffer
constexpr int AUXLEN = 6;       // length of AHA aux field
constexpr int EOAF = 0377;      // padding for end of AHA annotation files

// An aux string is stored as a length byte followed by the data, so its
// length is at most MAXAUX bytes.
constexpr unsigned MAXAUX = 0377;

// Prefix of the NOTE annotation that records the time resolution
constexpr char TRES_PREFIX[] = "## time resolution: ";

using unsigned_time = unsigned long long;

struct IAData {
    FilePtr file;               // input annotation file
    WFDB_Anninfo info;          // input annotator information
    WFDB_Annotation ann;        // next annotation to be returned by getann
    WFDB_Annotation pann;       // pushed-back annotation from ungetann
    WFDB_Frequency afreq = 0;   // time resolution, in ticks/second
    unsigned word = 0;          // next word from the input file
    int ateof = 0;              // EOF-reached indicator
    unsigned char auxstr[AUXBUFLEN] = {};   // aux string buffer
    unsigned index = 0;         // next available position in auxstr
    int auxpos = -1;            // position of the aux string of 'ann' in
                                // auxstr (-1: none)
    double tmul = 0;            // tmul * annotation time = sample count
    double tt = 0;              // annotation time (MIT format only)
    double ann_tt = 0;          // unscaled annotation time of 'ann'
    double pann_tt = 0;         // unscaled annotation time of 'pann'
    double prev_tt = 0;         // unscaled time of the last annotation
                                // returned by getann
    WFDB_Time prev_time = 0;    // sample number of the last annotation
                                // returned by getann
};

struct OAData {
    FilePtr file;               // output annotation file
    WFDB_Anninfo info;          // output annotator information
    WFDB_Annotation ann;        // most recent annotation written by putann
    WFDB_Frequency afreq = 0;   // time resolution, in ticks/second
    int seqno = 0;              // annotation serial number (AHA only)
    std::string rname;          // record with which annotator is associated
    char out_of_order = 0;      // if > 0, annotations are not in order
    char table_written = 0;     // if > 0, table has been written
};

struct AnnState {
    std::vector<std::unique_ptr<IAData>> iad;
    std::vector<std::unique_ptr<OAData>> oad;
    WFDB_Frequency oafreq = 0;  // time resolution for new output annotators
    int annclose_error = 0;     // if < 0, error while closing files
    char modified[ACMAX + 1] = {};  // mnemonic or description modified
};

AnnState &as()
{
    static AnnState state;
    return state;
}

// Round a double to the nearest WFDB_Time, with halfway cases always
// rounded up.
WFDB_Time round_to_time(double x)
{
    if (x != x) return WFDB_TIME_MIN;   // as on x86 (NaN)
    if (x >= 0) {
        if (x >= static_cast<double>(WFDB_TIME_MAX)) return WFDB_TIME_MAX;
        WFDB_Time t = static_cast<WFDB_Time>(x);
        if (x - static_cast<double>(t) >= 0.5)
            return t + 1;
        else
            return t;
    } else {
        if (x <= static_cast<double>(WFDB_TIME_MIN)) return WFDB_TIME_MIN;
        WFDB_Time t = static_cast<WFDB_Time>(x);
        if (x - static_cast<double>(t) < -0.5)
            return t - 1;
        else
            return t;
    }
}

// The aux string of an annotation as a C string (the data following the
// length byte, up to the first null).
std::string aux_text(const std::string &aux)
{
    std::string s = aux.substr(1);
    size_t z = s.find('\0');
    if (z != std::string::npos) s.resize(z);
    return s;
}

std::string make_aux(const std::string &s)
{
    std::string a(1, static_cast<char>(s.size() & MAXAUX));
    return a + s;
}

int get_ann_table(WFDB_Annotator i)
{
    AnnState &st = as();
    WFDB_Annotation annot;

    st.iad[i]->tmul = 1.0;
    st.iad[i]->afreq = 0.0;

    if (getann(i, &annot) < 0)  // prime the pump
        return -1;
    while (getann(i, &annot) == 0 && annot.time == 0 &&
           annot.anntyp == NOTE && annot.subtyp == 0) {
        if (!annot.aux || annot.aux->empty() ||
            static_cast<unsigned char>((*annot.aux)[0]) < 1)
            continue;
        std::string text = aux_text(*annot.aux);
        if (text[0] == '#') {
            constexpr size_t n = sizeof(TRES_PREFIX) - 1;
            if (std::strncmp(text.c_str(), TRES_PREFIX, n) == 0)
                std::sscanf(text.c_str() + n - 1, "%lf", &st.iad[i]->afreq);
            continue;
        }
        char *buf = &text[0];
        char *p1, *p2;
        p1 = buf + std::strspn(buf, " \t");  // whitespace before code
        int a = static_cast<int>(std::strtol(p1, &p2, 10));
        if (a < 0 || a > ACMAX || p1 == p2) continue;
        p2 = p2 + std::strcspn(p2, " \t");   // non-whitespace after code
        p1 = p2 + std::strspn(p2, " \t");    // whitespace before mnemonic
        p2 = p1 + std::strcspn(p1, " \t");   // non-whitespace (mnemonic)
        if (p2 != p1) {
            if (*p2)
                setanndesc(a, p2 + 1);
            else
                setanndesc(a, nullptr);
            *p2 = 0;
            setannstr(a, p1);
        }
    }
    if (annot.time != 0 || annot.anntyp != NOTE || annot.subtyp != 0 ||
        !annot.aux) {
        (void)ungetann(i, &annot);
    }

    setiafreq(i, getifreq());
    return 0;
}

int put_ann_table(WFDB_Annotator i)
{
    AnnState &st = as();
    int flag = 0;
    WFDB_Annotation annot;

    annot.time = 0;
    annot.anntyp = NOTE;
    annot.subtyp = annot.chan = annot.num = 0;
    if (st.oafreq != st.oad[i]->afreq && st.oafreq > 0.) {
        annot.aux = make_aux(strprintf("%s%.12g", TRES_PREFIX, st.oafreq));
        st.oad[i]->afreq = st.oafreq;
        if (putann(i, &annot) < 0) return -1;
        flag = 1;
    }
    for (int a = 0; a <= ACMAX; a++)
        if (st.modified[a]) {
            if (flag < 2) {     // mark the beginning of the table
                annot.aux = make_aux("## annotation type definitions");
                if (putann(i, &annot) < 0) return -1;
            }
            std::string str;
            std::optional<std::string> d = anndesc(a);
            std::string m = annstr(a).value_or("");
            if (d)
                str = strprintf("%d %s %s", a, m.c_str(), d->c_str());
            else
                str = strprintf("%d %s ", a, m.c_str());
            size_t n = str.size();
            annot.aux = std::string(1, static_cast<char>(n > MAXAUX ? MAXAUX : n)) +
                        str;
            if (putann(i, &annot) < 0) return -1;
            flag = 2;
        }
    if (flag == 2) {    // if a table was written, mark its end
        annot.aux = make_aux("## end of definitions");
        if (putann(i, &annot) < 0) return -1;
    }

    if (flag) {         // if a table was written, mark its end
        annot.anntyp = 0;
        annot.aux.reset();
        if (putann(i, &annot) < 0) return -1;
    }

    return 0;
}

// Mnemonic and description tables

const char *const default_mnemonics[ACMAX + 1] = {
    " ",    "N",    "L",    "R",    "a",        // 0 - 4
    "V",    "F",    "J",    "A",    "S",        // 5 - 9
    "E",    "j",    "/",    "Q",    "~",        // 10 - 14
    "[15]", "|",    "[17]", "s",    "T",        // 15 - 19
    "*",    "D",    "\"",   "=",    "p",        // 20 - 24
    "B",    "^",    "t",    "+",    "u",        // 25 - 29
    "?",    "!",    "[",    "]",    "e",        // 30 - 34
    "n",    "@",    "x",    "f",    "(",        // 35 - 39
    ")",    "r",    "[42]", "[43]", "[44]",     // 40 - 44
    "[45]", "[46]", "[47]", "[48]", "[49]"      // 45 - 49
};

const char *const default_descriptions[ACMAX + 1] = {
    "",
    "Normal beat",
    "Left bundle branch block beat",
    "Right bundle branch block beat",
    "Aberrated atrial premature beat",
    "Premature ventricular contraction",
    "Fusion of ventricular and normal beat",
    "Nodal (junctional) premature beat",
    "Atrial premature beat",
    "Supraventricular premature or ectopic beat",
    "Ventricular escape beat",
    "Nodal (junctional) escape beat",
    "Paced beat",
    "Unclassifiable beat",
    "Change in signal quality",
    nullptr,
    "Isolated QRS-like artifact",
    nullptr,
    "ST segment change",
    "T-wave change",
    "Systole",
    "Diastole",
    "Comment annotation",
    "Measurement annotation",
    "P-wave peak",
    "Bundle branch block beat (unspecified)",
    "(Non-captured) pacemaker artifact",
    "T-wave peak",
    "Rhythm change",
    "U-wave peak",
    "Beat not classified during learning",
    "Ventricular flutter wave",
    "Start of ventricular flutter/fibrillation",
    "End of ventricular flutter/fibrillation",
    "Atrial escape beat",
    "Supraventricular escape beat",
    "Link to external data (aux contains URL)",
    "Non-conducted P-wave (blocked APC)",
    "Fusion of paced and normal beat",
    "Waveform onset",
    "Waveform end",
    "R-on-T premature ventricular contraction",
    nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr
};

struct Tables {
    std::string cstring[ACMAX + 1];     // ECG mnemonics for each code
    std::string astring[ACMAX + 1];     // mnemonic strings for each code
    std::optional<std::string> tstring[ACMAX + 1];  // descriptions
    Tables() {
        for (int i = 0; i <= ACMAX; i++) {
            cstring[i] = astring[i] = default_mnemonics[i];
            if (default_descriptions[i]) tstring[i] = default_descriptions[i];
        }
    }
};

Tables &tables()
{
    static Tables t;
    return t;
}

// Tables of <ecgmap.h>
signed char qrs_table[ACMAX + 1] = {
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
    1, 1, 0, 0, 1, 1, 0, 0, 1, 0,
    0, 1, 0, 0, 0, 0, 0, 0, 0, 0
};

signed char mp1_table[ACMAX + 1] = {
    NOTQRS, NORMAL, NORMAL, NORMAL, NORMAL,     // 0 - 4
    PVC,    FUSION, NORMAL, NORMAL, NORMAL,     // 5 - 9
    PVC,    NORMAL, NORMAL, NORMAL, NOTQRS,     // 10 - 14
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 15 - 19
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 20 - 24
    NORMAL, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 25 - 29
    LEARN,  PVC,    NOTQRS, NOTQRS, NORMAL,     // 30 - 34
    NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS,     // 35 - 39
    NOTQRS, PVC,    NOTQRS, NOTQRS, NOTQRS,     // 40 - 44
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS      // 45 - 49
};

signed char mp2_table[ACMAX + 1] = {
    NOTQRS, NORMAL, NORMAL, NORMAL, SVPB,       // 0 - 4
    PVC,    FUSION, SVPB,   SVPB,   SVPB,       // 5 - 9
    PVC,    NORMAL, NORMAL, NORMAL, NOTQRS,     // 10 - 14
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 15 - 19
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 20 - 24
    NORMAL, NOTQRS, NOTQRS, NOTQRS, NOTQRS,     // 25 - 29
    LEARN,  PVC,    NOTQRS, NOTQRS, NORMAL,     // 30 - 34
    NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS,     // 35 - 39
    NOTQRS, PVC,    NOTQRS, NOTQRS, NOTQRS,     // 40 - 44
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS      // 45 - 49
};

const signed char ammp_table[] = {
    VESC,   FUSION, NOTQRS, NOTQRS, NOTQRS,     // 'E' - 'I'
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NORMAL,     // 'J' - 'N'
    NOTE,   PACE,   UNKNOWN, RONT,  NOTQRS,     // 'O' - 'S'
    NOTQRS, NOISE,  PVC,    NOTQRS, NOTQRS,     // 'T' - 'X'
    NOTQRS, NOTQRS, VFON,   NOTQRS, VFOFF       // 'Y' - ']'
};

const char mamp_table[ACMAX + 1] = {
    'O', 'N', 'N', 'N', 'N',    // 0 - 4
    'V', 'F', 'N', 'N', 'N',    // 5 - 9
    'E', 'N', 'P', 'Q', 'U',    // 10 - 14
    'O', 'O', 'O', 'O', 'O',    // 15 - 19
    'O', 'O', 'O', 'O', 'O',    // 20 - 24
    'N', 'O', 'O', 'O', 'O',    // 25 - 29
    'Q', 'O', '[', ']', 'N',    // 30 - 34
    'N', 'O', 'O', 'N', 'O',    // 35 - 39
    'O', 'R', 'O', 'O', 'O',    // 40 - 44
    'O', 'O', 'O', 'O', 'O'     // 45 - 49
};

signed char annp_table[ACMAX + 1] = {
    0, 1, 1, 1, 1,      // APUNDEF, APSTD, ...
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 2,
    0, 2, 0, 2, 2,
    2, 2, 2, 2, 2,
    1, 2, 2, 3, 2,
    1, 1, 1, 1, 1,
    1, 2, 2, 1, 2,
    2, 1, 0, 0, 0,
    0, 0, 0, 0, 0
};

} // namespace

// ---------------------------------------------------------------------------
// Private functions (for the use of other WFDB library functions only)

void wfdb_oaflush()
{
    for (auto &oa : as().oad) (void)oa->file->flush();
}

void wfdb_anclose()
{
    AnnState &st = as();
    for (WFDB_Annotator an = static_cast<WFDB_Annotator>(st.iad.size());
         an != 0; an--)
        iannclose(an - 1);
    for (WFDB_Annotator an = static_cast<WFDB_Annotator>(st.oad.size());
         an != 0; an--)
        oannclose(an - 1);
}

} // namespace detail

using namespace detail;

// ---------------------------------------------------------------------------
// WFDB library functions

// annopen: open annotation files for the specified record
int annopen(const char *record_arg, const WFDB_Anninfo *aiarray, unsigned nann)
{
    AnnState &st = as();
    st.annclose_error = 0;

    const char *record = record_arg ? record_arg : "";
    if (*record == '+')         // don't close open annotation files
        record++;               // discard the '+' prefix
    else
        wfdb_anclose();         // close previously opened annotation files

    // If no annotation files are to be opened, report whether errors
    // occurred while closing previously-opened files.
    if (nann == 0) return st.annclose_error;

    // Remove trailing .hea, if any, from record name.
    std::string rec = wfdb_striphea(record);
    record = rec.c_str();

    // Check the stat of each annotator.
    for (unsigned i = 0; i < nann; i++)
        switch (aiarray[i].stat) {
        case WFDB_READ:
        case WFDB_AHA_READ:
        case WFDB_WRITE:
        case WFDB_AHA_WRITE:
            break;
        default:
            wfdb_error("annopen: illegal stat %d for annotator %s, record %s\n",
                       aiarray[i].stat, aiarray[i].name.c_str(), record);
            return -5;
        }

    for (unsigned i = 0; i < nann; i++) {   // open the annotation files
        const char *name = aiarray[i].name.c_str();
        switch (aiarray[i].stat) {
        case WFDB_READ:         // standard (MIT-format) input file
        case WFDB_AHA_READ: {   // AHA-format input file
            auto ia = std::make_unique<IAData>();
            wfdb_setirec(record);
            if (!(ia->file = wfdb_open(name, record, WFDB_READ))) {
                wfdb_error("annopen: can't read annotator %s for record %s\n",
                           name, record);
                return -3;
            }
            ia->info.name = aiarray[i].name;

            // Try to figure out what format the file is in.  AHA-format
            // files begin with a null byte and an ASCII character which is
            // one of the legal AHA annotation codes other than '[' or ']'.
            // MIT annotation files cannot begin in this way.
            ia->word = static_cast<unsigned>(ia->file->g16());
            int a = static_cast<int>((ia->word >> 8) & 0xff);
            if ((ia->word & 0xff) || wfdb_ammap(a) == NOTQRS || a == '[' ||
                a == ']') {
                if (aiarray[i].stat != WFDB_READ) {
                    wfdb_error("warning (annopen, annotator %s, record %s):\n",
                               name, record);
                    wfdb_error(" file appears to be in MIT format\n");
                    wfdb_error(" ... continuing under that assumption\n");
                }
                ia->info.stat = WFDB_READ;
                // read any initial null annotation(s)
                while ((ia->word & CODE) == SKIP) {
                    ia->tt += ia->file->g32();
                    ia->word = static_cast<unsigned>(ia->file->g16());
                }
            } else {
                if (aiarray[i].stat != WFDB_AHA_READ) {
                    wfdb_error("warning (annopen, annotator %s, record %s):\n",
                               name, record);
                    wfdb_error(" file appears to be in AHA format\n");
                    wfdb_error(" ... continuing under that assumption\n");
                }
                ia->info.stat = WFDB_AHA_READ;
            }
            ia->ann.anntyp = 0;     // any pushed-back annot is invalid
            st.iad.push_back(std::move(ia));
            (void)get_ann_table(static_cast<WFDB_Annotator>(st.iad.size() - 1));
            break;
        }
        case WFDB_WRITE:        // standard (MIT-format) output file
        case WFDB_AHA_WRITE: {  // AHA-format output file
            // Quit (with message from wfdb_checkname) if name is illegal
            if (wfdb_checkname(name, "annotator")) return -4;
            auto oa = std::make_unique<OAData>();
            if (!(oa->file = wfdb_open(name, record, WFDB_WRITE))) {
                wfdb_error("annopen: can't write annotator %s for record %s\n",
                           name, record);
                return -4;
            }
            oa->info.name = aiarray[i].name;
            oa->rname = record;
            oa->ann.time = 0;
            oa->info.stat = aiarray[i].stat;
            oa->out_of_order = 0;
            oa->table_written = 0;
            st.oad.push_back(std::move(oa));
            break;
        }
        }
    }
    return 0;
}

namespace detail {
namespace {

// The aux string at position pos of the aux buffer: the length byte, the
// data, and any following bytes up to a null (as a C string would be read).
std::string aux_from_buffer(const IAData *ia, int pos)
{
    size_t p = static_cast<size_t>(pos);
    size_t len = ia->auxstr[p];
    std::string s(1, static_cast<char>(len));
    for (size_t i = p + 1; i < AUXBUFLEN && (i - p - 1 < len || ia->auxstr[i]);
         i++)
        s.push_back(static_cast<char>(ia->auxstr[i]));
    return s;
}

// Read the next annotation of an input annotator into ia->ann (the second
// part of getann).
void getann_next(IAData *ia)
{
    WFDBFile *f = ia->file.get();
    switch (ia->info.stat) {
    case WFDB_READ:             // MIT-format input file
    default:
        if (ia->word == 0) {    // logical end of file
            ia->ateof = 1;
            return;
        }
        ia->tt += ia->word & DATA;      // annotation time
        ia->ann_tt = ia->tt;
        ia->ann.anntyp = static_cast<char>((ia->word & CODE) >> CS);
        ia->ann.subtyp = 0;     // reset subtype field
        ia->auxpos = -1;        // reset aux field
        while (((ia->word = static_cast<unsigned>(f->g16())) & CODE) >= PAMIN &&
               !f->eof())
            switch (ia->word & CODE) {  // process pseudo-annotations
            case SKIP: ia->tt += f->g32(); break;
            case SUB:
                ia->ann.subtyp = static_cast<signed char>(DATA & ia->word);
                break;
            case CHN:
                ia->ann.chan = static_cast<unsigned char>(DATA & ia->word);
                break;
            case NUM:
                ia->ann.num = static_cast<signed char>(DATA & ia->word);
                break;
            case AUX: {         // auxiliary information
                unsigned len = ia->word & MAXAUX;   // length of auxiliary data
                if (ia->index >= AUXBUFLEN - 2 - len)
                    ia->index = 0;  // buffer index
                ia->auxpos = static_cast<int>(ia->index);   // save position
                ia->auxstr[ia->index++] = static_cast<unsigned char>(len);
                // Now read the data.  Note that an extra byte may be
                // present in the annotation file to preserve word
                // alignment;  if so, this extra byte is read and then
                // overwritten by the null below.
                (void)f->read(ia->auxstr + ia->index, 1, (len + 1) & ~1u);
                ia->auxstr[ia->index + len] = '\0';     // add a null
                ia->index += len + 1;   // update buffer index
                break;
            }
            default: break;
            }
        break;
    case WFDB_AHA_READ: {       // AHA-format input file
        if ((ia->word & 0377) == EOAF) {    // logical end of file
            ia->ateof = 1;
            return;
        }
        int a = static_cast<int>(ia->word >> 8);    // AHA annotation code
        ia->ann.anntyp = static_cast<char>(wfdb_ammap(a));
        ia->ann_tt = static_cast<double>(static_cast<WFDB_Time>(f->g32()));
        if (f->g16() <= 0)      // serial number (starts at 1)
            wfdb_error("getann: unexpected annot number in annotator %s\n",
                       ia->info.name.c_str());
        ia->ann.subtyp = static_cast<signed char>(f->getc());
        if (a == 'U' && ia->ann.subtyp == 0)
            ia->ann.subtyp = -1;    // unreadable (noise subtype -1)
        ia->ann.chan = static_cast<unsigned char>(f->getc());
        // (As in C, the AHA aux strings use only the first 256 bytes of
        // auxstr.)
        if (ia->index >= 256 - (AUXLEN + 2)) ia->index = 0;
        // read aux data
        (void)f->read(ia->auxstr + ia->index + 1, 1, AUXLEN);
        // There is very limited space in AHA format files for auxiliary
        // information, so no length byte is recorded; instead, we assume
        // that if the first byte of auxiliary data is not null, that up to
        // AUXLEN bytes may be significant.
        if (ia->auxstr[ia->index + 1]) {
            ia->auxstr[ia->index] = AUXLEN;
            ia->auxpos = static_cast<int>(ia->index);   // save position
            ia->auxstr[ia->index + 1 + AUXLEN] = '\0';  // add a null
            ia->index += AUXLEN + 2;    // update buffer index
        } else
            ia->auxpos = -1;
        ia->word = static_cast<unsigned>(f->g16());
        break;
    }
    }
    ia->ann.time = round_to_time(ia->ann_tt * ia->tmul);
    if (f->eof()) ia->ateof = -1;
}

} // namespace
} // namespace detail

// getann: read an annotation from annotator n into *annot
int getann(WFDB_Annotator n, WFDB_Annotation *annot)
{
    AnnState &st = as();
    IAData *ia;

    if (n >= st.iad.size() || (ia = st.iad[n].get()) == nullptr ||
        !ia->file) {
        wfdb_error("getann: can't read annotator %d\n", n);
        return -2;
    }

    if (ia->pann.anntyp) {      // an annotation was pushed back
        *annot = ia->pann;
        ia->pann.anntyp = 0;
        ia->prev_time = annot->time;
        ia->prev_tt = ia->pann_tt;
        return 0;
    }

    if (ia->ateof) {
        if (ia->ateof != -1) return -1;     // reached logical EOF
        wfdb_error("getann: unexpected EOF in annotator %s\n",
                   ia->info.name.c_str());
        return -3;
    }
    *annot = ia->ann;
    ia->prev_time = annot->time;
    ia->prev_tt = ia->ann_tt;
    // The aux data of the annotation returned are those in the aux buffer
    // when getann returns (as in C, where annot->aux points into the
    // buffer, reading the next annotation may overwrite them).
    int retpos = ia->auxpos;
    getann_next(ia);
    if (retpos >= 0)
        annot->aux = aux_from_buffer(ia, retpos);
    else
        annot->aux.reset();
    return 0;
}

// ungetann: push back an annotation into an input stream
int ungetann(WFDB_Annotator n, const WFDB_Annotation *annot)
{
    AnnState &st = as();
    if (n >= st.iad.size() || st.iad[n] == nullptr) {
        wfdb_error("ungetann: annotator %d is not initialized\n", n);
        return -2;
    }
    IAData *ia = st.iad[n].get();
    if (ia->pann.anntyp) {
        wfdb_error("ungetann: pushback buffer is full\n");
        wfdb_error("ungetann: annotation at %lld, annotator %d "
                   "not pushed back\n", annot->time, n);
        return -1;
    }
    ia->pann = *annot;
    if (annot->time == ia->prev_time)
        ia->pann_tt = ia->prev_tt;
    else
        ia->pann_tt = static_cast<double>(annot->time) / ia->tmul;
    return 0;
}

// putann: write annotation at annot to annotator n
int putann(WFDB_Annotator n, const WFDB_Annotation *annot)
{
    AnnState &st = as();
    OAData *oa;

    if (n >= st.oad.size() || (oa = st.oad[n].get()) == nullptr ||
        !oa->file) {
        wfdb_error("putann: can't write annotation file %d\n", n);
        return -2;
    }
    WFDB_Time t = annot->time;
    if (!oa->table_written) {
        oa->table_written = 1;
        if (put_ann_table(n) < 0) return -1;
    }
    WFDBFile *f = oa->file.get();
    unsigned_time delta = static_cast<unsigned_time>(t) -
                          static_cast<unsigned_time>(oa->ann.time);
    if (!(annot->chan > oa->ann.chan || annot->num > oa->ann.num ||
          t > oa->ann.time || (t == 0 && oa->ann.time == 0)))
        oa->out_of_order = 1;
    // aux length (a null aux, or an empty string, has none)
    unsigned auxlen = (annot->aux && !annot->aux->empty())
        ? static_cast<unsigned char>((*annot->aux)[0]) : 0;
    switch (oa->info.stat) {
    case WFDB_WRITE:            // MIT-format output file
    default: {
        // Do not allow annotations to be written at the minimum or maximum
        // possible time value.
        if (t == WFDB_TIME_MIN || t == WFDB_TIME_MAX) {
            wfdb_error("putann: time overflow in annotation file %d\n", n);
            return -1;
        }
        if (t > oa->ann.time) {
            while (delta > static_cast<unsigned_time>(MAXSKIP)) {
                f->p16(SKIP);
                f->p32(MAXSKIP);
                delta -= MAXSKIP;
            }
        } else {
            while (-delta > static_cast<unsigned_time>(-MINSKIP)) {
                f->p16(SKIP);
                f->p32(MINSKIP);
                delta -= static_cast<unsigned_time>(MINSKIP);
            }
        }
        if (annot->anntyp == 0) {
            // putann must not write a word of zeroes that would be
            // interpreted as an EOF, so it writes a SKIP to the location
            // just before the desired one;  thus annwd is never 0.
            f->p16(SKIP);
            f->p32(static_cast<long>(delta - 1));
            delta = 1;
        } else if (delta > MAXRR) {
            // skip forward by more than MAXRR, or skip backward by any
            // distance
            f->p16(SKIP);
            f->p32(static_cast<long>(delta));
            delta = 0;
        }
        unsigned annwd = static_cast<unsigned>(static_cast<int>(delta)) +
            (static_cast<unsigned>(static_cast<int>(annot->anntyp)) << CS);
        f->p16(annwd);
        if (annot->subtyp != 0) {
            annwd = SUB + (DATA & static_cast<unsigned>(annot->subtyp));
            f->p16(annwd);
        }
        if (annot->chan != oa->ann.chan) {
            annwd = CHN + (DATA & annot->chan);
            f->p16(annwd);
        }
        if (annot->num != oa->ann.num) {
            annwd = NUM + (DATA & static_cast<unsigned>(annot->num));
            f->p16(annwd);
        }
        if (auxlen != 0) {
            annwd = AUX + auxlen;
            f->p16(annwd);
            std::string data = annot->aux->substr(1, auxlen);
            data.resize(auxlen, '\0');
            (void)f->write(data.data(), 1, auxlen);
            if (auxlen & 1) (void)f->putc('\0');
        }
        break;
    }
    case WFDB_AHA_WRITE: {      // AHA-format output file
        (void)f->putc('\0');
        (void)f->putc(wfdb_mamap(annot->anntyp, annot->subtyp));
        f->p32(static_cast<long>(t));
        f->p16(static_cast<unsigned>(++(oa->seqno)));
        (void)f->putc(annot->subtyp);
        (void)f->putc(annot->anntyp);
        int len = auxlen < static_cast<unsigned>(AUXLEN)
                      ? static_cast<int>(auxlen) : AUXLEN;
        int i;
        for (i = 0; i < len; i++) {
            size_t k = static_cast<size_t>(i) + 1;
            (void)f->putc(k < annot->aux->size()
                              ? static_cast<unsigned char>((*annot->aux)[k]) : 0);
        }
        for (; i < AUXLEN; i++) (void)f->putc('\0');
        break;
    }
    }
    if (f->error()) {
        wfdb_error("putann: write error on annotation file %s\n",
                   oa->info.name.c_str());
        return -1;
    }
    oa->ann = *annot;
    oa->ann.time = t;
    return 0;
}

// iannsettime: seek so that for the next annotation read from each input
// annotator, anntime >= t
int iannsettime(WFDB_Time t)
{
    AnnState &st = as();
    int stat = 0;
    int niavalid = static_cast<int>(st.iad.size());
    WFDB_Annotation tempann;

    // Handle negative arguments as equivalent positive arguments.  As an
    // exception, WFDB_TIME_MIN indicates that we should rewind to the very
    // beginning of the annotation file, even if there are annotations at
    // negative time values.
    if (t < 0 && t != WFDB_TIME_MIN) t = -t;

    for (WFDB_Annotator i = 0; i < st.iad.size(); i++) {
        IAData *ia = st.iad[i].get();
        if (ia->ann.time >= t) {    // "rewind" the annotation file
            ia->pann.anntyp = 0;    // flush pushback buffer
            if (ia->file->seek(0L, 0) == -1) {
                wfdb_error("iannsettime: improper seek\n");
                return -1;
            }
            ia->ann.subtyp = 0;
            ia->ann.chan = 0;
            ia->ann.num = 0;
            ia->ateof = 0;
            ia->ann.time = 0;
            ia->tt = 0;
            ia->word = static_cast<unsigned>(ia->file->g16());
            if (ia->info.stat == WFDB_READ)
                while ((ia->word & CODE) == SKIP) {
                    ia->tt += ia->file->g32();
                    ia->word = static_cast<unsigned>(ia->file->g16());
                }
            (void)getann(i, &tempann);
        }
        while (ia->ann.time < t && (stat = getann(i, &tempann)) == 0)
            ;
        if (stat < 0) niavalid--;
    }
    return (niavalid > 0) ? 0 : -1;
}

// Conversion between annotation codes, mnemonics, and descriptions

std::optional<std::string> ecgstr(int code)
{
    if (0 <= code && code <= ACMAX) return tables().cstring[code];
    return strprintf("[%d]", code);
}

int strecg(const char *str)
{
    if (str == nullptr) str = "";
    Tables &tb = tables();
    for (int code = 1; code <= ACMAX; code++)
        if (tb.cstring[code] == str) return code;
    return NOTQRS;
}

int setecgstr(int code, const char *string)
{
    if (NOTQRS <= code && code <= ACMAX) {
        if (string == nullptr) string = "";
        tables().cstring[code] = string;
        return 0;
    }
    wfdb_error("setecgstr: illegal annotation code %d\n", code);
    return -1;
}

std::optional<std::string> annstr(int code)
{
    if (0 <= code && code <= ACMAX) return tables().astring[code];
    return strprintf("[%d]", code);
}

int strann(const char *str)
{
    if (str == nullptr) str = "";
    Tables &tb = tables();
    for (int code = 1; code <= ACMAX; code++)
        if (tb.astring[code] == str) return code;
    return NOTQRS;
}

int setannstr(int code, const char *string)
{
    int mflag = 0;

    if (code > 0)
        mflag = 1;
    else
        code = -code;
    if (code <= ACMAX) {
        if (string == nullptr) string = "";
        Tables &tb = tables();
        if (tb.astring[code] != string) {
            tb.astring[code] = string;
            if (mflag) as().modified[code] = 1;
        }
        return 0;
    }
    wfdb_error("setannstr: illegal annotation code %d\n", code);
    return -1;
}

std::optional<std::string> anndesc(int code)
{
    if (0 <= code && code <= ACMAX) return tables().tstring[code];
    return std::string("illegal annotation code");
}

int setanndesc(int code, const char *string)
{
    int mflag = 0;

    if (code > 0)
        mflag = 1;
    else
        code = -code;
    if (code <= ACMAX) {
        if (string == nullptr) string = "";
        Tables &tb = tables();
        if (!tb.tstring[code] || *tb.tstring[code] != string) {
            tb.tstring[code] = std::string(string);
            if (mflag) as().modified[code] = 1;
        }
        return 0;
    }
    wfdb_error("setanndesc: illegal annotation code %d\n", code);
    return -1;
}

// setafreq: set time resolution for output annotation files
void setafreq(WFDB_Frequency f) { as().oafreq = f; }

// getafreq: return time resolution for output annotation files
WFDB_Frequency getafreq() { return as().oafreq; }

// setiafreq: set time resolution for input annotations
void setiafreq(WFDB_Annotator n, WFDB_Frequency f)
{
    AnnState &st = as();
    IAData *ia;
    WFDB_Frequency sfreq;

    if (n < st.iad.size() && (ia = st.iad[n].get()) != nullptr) {
        if (f > 0.0 && ia->afreq > 0.0)
            ia->tmul = f / ia->afreq;
        else if (f > 0.0 && (sfreq = sampfreq(nullptr)) > 0.0)
            ia->tmul = f * getspf() / sfreq;
        else
            ia->tmul = 1.0;

        ia->ann.time = round_to_time(ia->ann_tt * ia->tmul);
        ia->pann.time = round_to_time(ia->pann_tt * ia->tmul);
        ia->prev_time = round_to_time(ia->prev_tt * ia->tmul);
    }
}

// getiafreq: return time resolution for input annotations
WFDB_Frequency getiafreq(WFDB_Annotator n)
{
    AnnState &st = as();
    IAData *ia;

    if (n < st.iad.size() && (ia = st.iad[n].get()) != nullptr) {
        if (ia->afreq > 0.0)
            return ia->afreq * ia->tmul;
        else
            return sampfreq(nullptr) * ia->tmul / getspf();
    }
    return -2;
}

// getiaorigfreq: return the original time resolution of an input
// annotation file
WFDB_Frequency getiaorigfreq(WFDB_Annotator n)
{
    AnnState &st = as();
    if (n < st.iad.size() && st.iad[n] != nullptr) return st.iad[n]->afreq;
    return -2;
}

// iannclose: close input annotation file n
void iannclose(WFDB_Annotator n)
{
    AnnState &st = as();
    if (n < st.iad.size() && st.iad[n] != nullptr && st.iad[n]->file) {
        (void)st.iad[n]->file->close();
        st.iad.erase(st.iad.begin() + n);
    }
}

// oannclose: close output annotation file n
void oannclose(WFDB_Annotator n)
{
    AnnState &st = as();
    OAData *oa;

    if (n < st.oad.size() && (oa = st.oad[n].get()) != nullptr && oa->file) {
        WFDBFile *f = oa->file.get();
        switch (oa->info.stat) {
        case WFDB_WRITE:        // write logical EOF for MIT-format files
            f->p16(0);
            break;
        case WFDB_AHA_WRITE: {  // write logical EOF for AHA-format files
            int i = ABLKSIZ -
                static_cast<int>(static_cast<unsigned>(f->tell()) % ABLKSIZ);
            while (i-- > 0) (void)f->putc(EOAF);
            break;
        }
        }
        int errflag = f->error();
        if (f->close()) errflag = 1;
        if (errflag) {
            wfdb_error("oannclose: write error on annotation file %s\n",
                       oa->info.name.c_str());
            st.annclose_error = -7;
        }
        if (oa->out_of_order) {
            int dosort = DEFWFDBANNSORT;
            const char *p = std::getenv("WFDBANNSORT");

            if (p) dosort = static_cast<int>(std::strtol(p, nullptr, 10));
            if (dosort) {
                wfdb_error("Rearranging annotations for output annotator %s ...",
                           oa->info.name.c_str());
                if (run_sortann(oa->rname, oa->info.name) == 0) {
                    wfdb_error("done!\n");
                    oa->out_of_order = 0;
                } else
                    wfdb_error("\nAnnotations still need to be rearranged.\n");
                if (st.annclose_error == 0) st.annclose_error = -6;
            }
        }
        if (oa->out_of_order) {
            wfdb_error("Use the command:\n  sortann -r %s -a %s\n",
                       oa->rname.c_str(), oa->info.name.c_str());
            wfdb_error("to rearrange annotations in the correct order.\n");
            if (st.annclose_error == 0) st.annclose_error = -6;
        }
        st.oad.erase(st.oad.begin() + n);
    }
}

// Function versions of the <ecgmap.h> macros

int wfdb_isann(int code) { return 0 < code && code <= ACMAX; }

int wfdb_isqrs(int code) { return wfdb_isann(code) ? qrs_table[code] : 0; }

int wfdb_setisqrs(int code, int newval)
{
    return wfdb_isann(code)
        ? (qrs_table[code] = static_cast<signed char>(newval)) : 0;
}

int wfdb_map1(int code) { return wfdb_isann(code) ? mp1_table[code] : NOTQRS; }

int wfdb_setmap1(int code, int newval)
{
    return wfdb_isann(code)
        ? (mp1_table[code] = static_cast<signed char>(newval)) : NOTQRS;
}

int wfdb_map2(int code) { return wfdb_isann(code) ? mp2_table[code] : NOTQRS; }

int wfdb_setmap2(int code, int newval)
{
    return wfdb_isann(code)
        ? (mp2_table[code] = static_cast<signed char>(newval)) : NOTQRS;
}

int wfdb_ammap(int code)
{
    return ('D' < code && code <= ']') ? ammp_table[code - 'E'] : NOTQRS;
}

int wfdb_mamap(int code, int subtype)
{
    if (!wfdb_isann(code)) return 'O';
    int m = mamp_table[code];
    return (m == 'U' && subtype != -1) ? 'O' : m;
}

int wfdb_annpos(int code)
{
    return wfdb_isann(code) ? annp_table[code] : 0;
}

int wfdb_setannpos(int code, int newval)
{
    return wfdb_isann(code)
        ? (annp_table[code] = static_cast<signed char>(newval)) : 0;
}

} // namespace wfdbx
