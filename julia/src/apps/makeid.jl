# makeid: make an AHA-format ID block for a database record (port of
# convert/makeid.c).
#
# Where the C program uses uninitialized variables (the time of the last
# annotation if there is only one, or of the first if there is none), 0 is
# used (see docs/KNOWN_C_BEHAVIORS.md).
#
# Copyright (C) 2003 George B. Moody (original C program, convert/makeid.c).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

"Length of an AHA record ID (bytes 1-8 of the ID block)."
const _MAKEID_IDLEN = 8
"Length of the unused tail of the ID block (bytes 49-512)."
const _MAKEID_TAIL = 464
"Length of each unused gap within the ID block."
const _MAKEID_GAP = 6

# Write a 16-bit integer in PDP-11 (little-endian) byte order.
function _makeid_p16(x::Integer)
    cputchar(x % UInt8)
    cputchar((x >> 8) % UInt8)
end

# Write a 32-bit integer in PDP-11 format (high 16-bit word first).
function _makeid_p32(x::Int64)
    _makeid_p16(x >> 16)
    _makeid_p16(x)
end

_makeid_nulls(n::Integer) = cout_write(zeros(UInt8, n))

function makeid_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "makeid"

    if argc < 3
        ceprintf("usage: %s annotator record\n", pname)
        cexit(1)
    end
    rec = cstr(argv[2])
    len = length(rec)
    if len > _MAKEID_IDLEN
        ceprintf("record name must be 8 characters or less\n")
        cexit(1)
    end
    afarray = [Anninfo(cstr(argv[1]), WFDB_READ)]
    dfarray = [Siginfo() for _ in 1:2]
    wfdbinit(rec, afarray, 1, dfarray, 2) < 1 && cexit(2)
    nsamp = dfarray[1].nsamp
    annot = Annotation()
    getann(0, annot)
    first = annot.time
    last = Int64(0)
    nann = Int32(1)
    while getann(0, annot) >= 0
        last = annot.time
        nann += Int32(1)
    end
    wfdbquit()

    # Bytes 1-8: record ID (null-padded)
    cout_write(rec)
    len < _MAKEID_IDLEN && _makeid_nulls(_MAKEID_IDLEN - len)
    ceprintf("%s\n", rec)

    # Bytes 9-10: number of annotations
    _makeid_p16(nann)
    ceprintf("%d annotations\n", nann)

    # Bytes 11-16: unused
    _makeid_nulls(_MAKEID_GAP)

    # Bytes 17-20: time of first sample in the annotated segment of the
    # record, relative to the beginning of the record
    _makeid_p32(Int64(0))
    ceprintf("Annotated segment begins at sample 0\n")

    # Bytes 21-24: time of last sample in the annotated segment of the
    # record, relative to the beginning of the record
    _makeid_p32(nsamp)
    ceprintf("Annotated segment ends at sample %ld\n", nsamp)

    # Bytes 25-26: number of 512-byte logical blocks of sample data
    # (nsamp * 2 bytes per sample * 2 channels / 512, rounded upward)
    blocks = ((nsamp + 127) >> 7) % Int32
    _makeid_p16(blocks)
    ceprintf("%d blocks of sample data\n", blocks)

    # Bytes 27-32: unused
    _makeid_nulls(_MAKEID_GAP)

    # Bytes 33-36: TOC of first annotation, relative to the beginning of the
    # annotated segment
    _makeid_p32(first)
    ceprintf("First annotation is at sample %ld\n", first)

    # Bytes 37-40: TOC of last annotation, relative to the beginning of the
    # annotated segment
    _makeid_p32(last)
    ceprintf("Last annotation is at sample %ld\n", last)

    # Bytes 41-42: number of 512-byte logical blocks of annotations
    # (nann * 16 bytes per annotation / 512, rounded upward)
    blocks = (nann + Int32(31)) >> 5
    _makeid_p16(blocks)
    ceprintf("%d blocks of annotations\n", blocks)

    # Bytes 43-48: unused
    _makeid_nulls(_MAKEID_GAP)

    # Bytes 49-512: may contain information such as a copyright notice
    _makeid_nulls(_MAKEID_TAIL)
    cexit(0)
end

register_workload("makeid") do
    with_workload_data() do dir
        workload_tool("makeid", "atr", "100s")
        workload_tool("makeid", "atr", "fmt16_too_long")
        workload_tool("makeid", "atr", "nosuch")
        workload_tool("makeid")
    end
end
