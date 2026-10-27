# readid: read an AHA-format ID block, write record name and file lengths.
#
# The C program reads the record ID into a 9-byte buffer, which overflows
# for longer IDs; as the C program does, the whole ID is printed (see
# docs/KNOWN_C_BEHAVIORS.md).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/readid.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/readid.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2005 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Bytes of the ID block before the number of sample data blocks."
const _READID_NAME_BYTES = 24
"Bytes between the number of sample data blocks and of annotation blocks."
const _READID_GAP_BYTES = 14
"Size of an AHA logical block, in bytes."
const _READID_BLOCK = 512

# Read a 16-bit integer in PDP-11 format (as g16 in readid.c: EOF reads as
# 0xff bytes).
function _readid_g16(f::WfdbFile)
    l = getc(f)
    h = getc(f)
    ((h << 8) & 0xff00) | (l & 0xff)
end

function readid_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "readid"

    if argc < 3
        ceprintf("usage: %s data-block-size annot-block-size\n", pname)
        cexit(1)
    end
    dasize = Int64(max(atoi(argv[1]), Int32(1)))
    ansize = Int64(max(atoi(argv[2]), Int32(1)))
    f = wfdb_stdin()
    buf = zeros(UInt8, _READID_BLOCK)
    fread!(f, buf, _READID_NAME_BYTES)
    name = UInt8[]
    csscanf(cstr(buf), "%s", name)
    dcount = (_readid_g16(f) * Int64(_READID_BLOCK) + dasize - 1) ÷ dasize
    fread!(f, buf, _READID_GAP_BYTES)
    acount = (_readid_g16(f) * Int64(_READID_BLOCK) + ansize - 1) ÷ ansize
    cprintf("%s %ld %ld\n", name, dcount, acount)
    cexit(0)
end

register_workload("readid") do
    with_workload_data() do dir
        workload_tool("readid", "512", "512"; stdin=vcat(Vector{UInt8}(b"100s\0\0\0\0"), UInt8.(1:59)))
        workload_tool("readid", "100", "0"; stdin="x"^50)
        workload_tool("readid")
    end
end
