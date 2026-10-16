//! wfdb2mat: convert (all or part of) a WFDB signal file to Matlab .mat
//! format (port of `convert/wfdb2mat.c`).
//!
//! If the input record name is REC, the output files are RECm.mat (a
//! version 5 MAT-file containing a single matrix named 'val' of raw
//! samples, one column per sample) and RECm.hea. See the C source for
//! details.
//
// Copyright (C) 2009-2013 George B. Moody (original C program,
// convert/wfdb2mat.c; revised 2014-2021 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

use wfdbx::cstd;
use wfdbx::{
    ceprintf, cprintf, Siginfo, NULL, WFDB_DEFGAIN, WFDB_HIGHRES, WFDB_INVALID_SAMPLE,
    WFDB_TIME_MAX,
};

// Output .mat data storage types (values of mattype), defined by the .mat
// format specification. These variables are for the sub4 tag data STORAGE
// type.
const MAT8: i32 = 2; // 8 bits per sample unsigned
const MAT16: i32 = 3; // 16 bits per sample signed
const MAT32: i32 = 5; // 32 bits per sample signed

const HELP_STRINGS: &[&[u8]] = &[
    b"usage: %s -r RECORD [OPTIONS ...]\n",
    b"where RECORD is the name of the input record, and OPTIONS may include:",
    b" -f TIME     begin at specified time",
    b" -h          print this usage summary",
    b" -H          read multifrequency signals in high resolution mode",
    b" -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    b" -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
    b" -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    b"\t\tthe time specified with -f, and begin converting then",
    b" -t TIME     stop at specified time",
    b"Outputs are written to the current directory as RECORD.mat and RECORDm.hea.",
];

fn help(pname: &[u8]) {
    ceprintf!(HELP_STRINGS[0], pname);
    for s in &HELP_STRINGS[1..] {
        ceprintf!(b"%s\n", s);
    }
}

/// Store the low 32 bits of `x` (little-endian) at `p[at..at + 4]`.
fn put32(p: &mut [u8], at: usize, x: u64) {
    p[at..at + 4].copy_from_slice(&(x as u32).to_le_bytes());
}

fn main() {
    let mut argv = cstd::args();
    let legacy = wfdbx::wfdbx_legacy_args(&mut argv) != 0; // wfdb-x: --legacy
    let argc = argv.len();
    let pname = cstd::prog_name(&argv[0]).to_vec();
    let mut record: Option<Vec<u8>> = None;
    let mut search: Option<Vec<u8>> = None;
    // The entire file is composed of:
    //  - 128 byte descriptive text
    //  - 8 byte master tag. 4 bytes indicate data type = matrix, 4 bytes
    //    indicate data size.
    //  - 4 subelements. Each subelement has a 4 byte tag giving the data
    //    type of the elements, a 4 byte tag giving the subelement size, and
    //    the subelement's actual content.
    //    - Subelement 1: array flags (8 + 8 bytes)
    //    - Subelement 2: array dimension (8 + 8 bytes)
    //    - Subelement 3: array name (8 + 8 bytes)
    //    - Subelement 4: array content (8 + ?? bytes)
    // (128 bytes of descriptive text, and 64 bytes of fixed-length content)
    const PROLOGLEN: usize = 192;
    let mut prolog = [0u8; PROLOGLEN];

    // mastertype=matrix, sub1type=UINT32, sub2type=INT32, sub3type=INT8
    // fieldversion=0x0100 indicating mat file
    let (mastertype, sub1type, sub2type, sub3type) = (14i32, 6i32, 5i32, 1i32);
    let fieldversion: i32 = 256;
    let sub1class: i32 = 6;
    let mut highres = false;
    let mut isiglist = 0usize;
    let mut nosig: usize = 0;
    let mut stat: i32 = 0;
    let (mut from, mut maxl, mut to): (i64, i64, i64) = (0, 0, 0);

    let mut i = 1;
    while i < argc {
        if argv[i].first() == Some(&b'-') {
            match argv[i].get(1).copied().unwrap_or(0) {
                b'f' => {
                    // starting time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -f\n", pname);
                        cstd::exit(1);
                    }
                    from = i as i64;
                }
                b'h' => {
                    // help requested
                    help(&pname);
                    cstd::exit(0);
                }
                b'H' => highres = true, // select high-resolution mode
                b'l' => {
                    // maximum length of output follows
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: max output length must follow -l\n", pname);
                        cstd::exit(1);
                    }
                    maxl = i as i64;
                }
                b'r' => {
                    // record name
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: record name must follow -r\n", pname);
                        cstd::exit(1);
                    }
                    record = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b's' => {
                    // signal list follows
                    isiglist = i + 1; // index of first argument containing a signal #
                    while i + 1 < argc && argv[i + 1].first() != Some(&b'-') {
                        i += 1;
                        nosig += 1; // number of elements in signal list
                    }
                    if nosig == 0 {
                        ceprintf!(b"%s: signal list must follow -s\n", pname);
                        cstd::exit(1);
                    }
                }
                b'S' => {
                    // search for valid sample of specified signal
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: signal name or number must follow -S\n", pname);
                        cstd::exit(1);
                    }
                    search = Some(cstd::cstr(&argv[i]).to_vec());
                }
                b't' => {
                    // end time
                    i += 1;
                    if i >= argc {
                        ceprintf!(b"%s: time must follow -t\n", pname);
                        cstd::exit(1);
                    }
                    to = i as i64;
                }
                _ => {
                    ceprintf!(b"%s: unrecognized option %s\n", pname, argv[i]);
                    cstd::exit(1);
                }
            }
        } else {
            ceprintf!(b"%s: unrecognized argument %s\n", pname, argv[i]);
            cstd::exit(1);
        }
        i += 1;
    }
    let Some(record) = record else {
        help(&pname);
        cstd::exit(1);
    };
    let mut nisig = wfdbx::isigopen(&record, &mut [], 0);
    if nisig <= 0 {
        cstd::exit(2);
    }
    let mut si = vec![Siginfo::default(); nisig as usize];
    let mut vi = vec![0i32; nisig as usize];
    nisig = wfdbx::isigopen(&record, &mut si, nisig);
    if nisig <= 0 {
        cstd::exit(2);
    }
    // wfdb-x: uncalibrated signals remain uncalibrated in the output (the C
    // program assumed 200 adu/mV), and the output header needs the sampling
    // frequency (the C program assumed 250 Hz).  Legacy mode: as in the C
    // program.
    if legacy {
        for s in si.iter_mut().take(nisig as usize) {
            if s.gain == 0.0 {
                s.gain = WFDB_DEFGAIN;
            }
        }
    }
    if highres {
        wfdbx::setgvmode(WFDB_HIGHRES);
    }
    let freq = wfdbx::sampfreq(NULL);
    if freq <= 0.0 && !legacy {
        ceprintf!(
            b"%s: sampling frequency of record %s is not specified\n",
            pname,
            record
        );
        cstd::exit(2);
    }
    if from > 0 {
        from = wfdbx::strtim(&argv[from as usize]);
        if from < 0 {
            from = from.wrapping_neg();
        }
    }
    if wfdbx::isigsettime(from) < 0 {
        cstd::exit(2);
    }
    if to > 0 {
        to = wfdbx::strtim(&argv[to as usize]);
        if to < 0 {
            to = to.wrapping_neg();
        }
    }
    let mut sig: Vec<usize>;
    if nosig != 0 {
        // convert samples only from specified signals
        sig = vec![0; nosig];
        for (i, sg) in sig.iter_mut().enumerate() {
            let s = wfdbx::findsig(&argv[isiglist + i]);
            if s < 0 {
                ceprintf!(b"%s: can't read signal '%s'\n", pname, argv[isiglist + i]);
                cstd::exit(2);
            }
            *sg = s as usize;
        }
    } else {
        // convert samples from all signals
        nosig = nisig as usize;
        sig = (0..nosig).collect();
    }
    let mut so = vec![Siginfo::default(); nosig];
    let mut vo = vec![0i32; nosig];

    // Reset 'from' if a search was requested.
    if let Some(search) = &search {
        let s = wfdbx::findsig(search);
        let ok = s >= 0 && {
            from = wfdbx::tnextvec(s as u32, from);
            from >= 0
        };
        if !ok {
            ceprintf!(b"%s: can't read signal '%s'\n", pname, search);
            cstd::exit(2);
        }
    }

    // Reset 'to' if a duration limit was specified.
    if maxl > 0 {
        maxl = wfdbx::strtim(&argv[maxl as usize]);
        if maxl < 0 {
            maxl = maxl.wrapping_neg();
        }
    }
    if maxl != 0 && (to == 0 || to > from.wrapping_add(maxl)) {
        to = from.wrapping_add(maxl);
    }

    let mut t = wfdbx::strtim("e"); // the end of the record
    if t == 0 {
        // record length unspecified; determine length by a binary search
        wfdbx::wfdbquiet();
        let mut lower: i64 = 0;
        let mut upper: i64 = WFDB_TIME_MAX;
        t = 16 * 1024;
        while lower < upper {
            if wfdbx::isigsettime(t) >= 0 && wfdbx::getvec(&mut vi) > 0 {
                lower = t + 1;
            } else {
                upper = t;
            }
            if upper == WFDB_TIME_MAX && t < WFDB_TIME_MAX / 2 {
                t *= 2;
            } else {
                t = lower + (upper - lower) / 2;
            }
        }
        wfdbx::wfdbverbose();
        if wfdbx::isigsettime(from) < 0 {
            cstd::exit(2);
        }
    }
    if to == 0 || to > t {
        to = t;
    }

    // Quit if there will be no output.
    if to <= from {
        wfdbx::wfdbquit();
        ceprintf!(b"%s: no output\n", pname);
        ceprintf!(
            b" Use the -f and -t options to specify time limits\n(or type '%s -h' for help)\n",
            pname
        );
        cstd::exit(1);
    }

    // Generate the names for the output .mat file and the output record.
    let mut orec: Vec<u8> = {
        let r = &record[..];
        let mut sfname = 0usize;
        let mut q: isize = r.len() as isize - 1; // r[q] = final char of record name
        if q >= 0 && r[q as usize] == b'/' {
            // short form name ('rec/' rather than 'rec/rec')
            sfname = 1;
        }
        loop {
            q -= 1;
            if q <= 0 {
                break;
            }
            if r[q as usize] == b'/' {
                // omit path components from orec
                q += 1;
                break;
            }
        }
        if q < 0 {
            q = 0;
        }
        let tail = &r[q as usize..];
        tail[..tail.len() - sfname].to_vec()
    };
    // If the input record is an EDF file, it will have a '.' in its name.
    // The output record will not be an EDF file, so it may not have a '.'
    // in its name. Replace any '.' with '_' here.
    for c in &mut orec {
        if *c == b'.' {
            *c = b'_';
        }
    }
    orec.push(b'm'); // append 'm' to the output record name
    let mut matname = orec.clone();
    matname.extend_from_slice(b".mat");

    // Determine if we can write 8-bit unsigned samples, or if 16 or 32 bits
    // are needed per sample.
    let mut nbytesperelement: i32 = 1;
    for &sg in &sig {
        let s = &si[sg];
        if s.adcres > 0 {
            if s.adcres > 16 {
                nbytesperelement = 4;
            } else if s.adcres > 8 && nbytesperelement < 2 {
                nbytesperelement = 2;
            }
        } else {
            // adcres not specified; try to guess from format
            if s.fmt == 24 || s.fmt == 32 {
                nbytesperelement = 4;
            } else if s.fmt != 80 && nbytesperelement < 2 {
                nbytesperelement = 2;
            }
        }
    }
    let (sub4type, wfdbtype) = match nbytesperelement {
        1 => (MAT8, 80),
        2 => (MAT16, 16),
        _ => (MAT32, 32),
    };

    for (i, o) in so.iter_mut().enumerate() {
        let s = &si[sig[i]];
        *o = s.clone();
        o.fname = Some(matname.clone());
        o.group = 0;
        o.spf = 1;
        o.fmt = wfdbtype;
        o.adczero = 0;
        o.baseline = o.baseline.wrapping_sub(s.adczero);
        // handle possibly missing units strings
        match &o.units {
            // wfdb-x: missing units are not assumed to be millivolts (except
            // in legacy mode: "in a .hea file, missing units can be assumed
            // to be millivolts")
            None if legacy => o.units = Some(b"mV".to_vec()),
            None => o.units = Some(b"nd".to_vec()),
            // this can happen only in an EDF file; in this case, the signal
            // is dimensionless (nd => "no dimension")
            Some(u) if u.is_empty() => o.units = Some(b"nd".to_vec()),
            _ => {}
        }
    }

    // Ensure the signal size does not exceed 2^31 byte limit
    let max_length: u64 = (1u64 << 31) / nbytesperelement as u64 / nosig as u64;
    if (to.wrapping_sub(from) as u64) > max_length {
        ceprintf!(
            b"%s: cannot write mat file - data size exceeds 2GB limit\n",
            pname
        );
        cstd::exit(1);
    }

    // Bytes of actual data
    let nbytesofdata: u64 =
        ((nbytesperelement.wrapping_mul(nosig as i32)) as i64).wrapping_mul(to - from) as u64;
    // This is the remaining no. bytes that don't fit into integer multiple
    // of 8. ie if 18 bytes, lremain=2, from 17 to 18.
    let lremain = nbytesofdata % 8;

    // nbytesmaster = (8 + 8) + (8 + 8) + (8 + 8) + (8 + nbytesofdata)
    //  + padding. Must be integer multiple 8.
    let nbytesmaster: u64 = if lremain == 0 {
        nbytesofdata + 56
    } else {
        for o in &mut so {
            o.bsize = 8;
        }
        nbytesofdata + 64 - lremain
    };

    // Create an empty .mat file.
    if wfdbx::osigfopen(&so, nosig as u32) != nosig as i32 {
        wfdbx::wfdbquit(); // failed to open output, quit
        cstd::exit(1);
    }

    // Fill in the .mat file's prolog and write it. (Elements of prolog[]
    // not set explicitly below are always zero.)

    // Start with 128 byte header
    prolog[..10].copy_from_slice(b"MATLAB 5.0"); // first 116 bytes: descriptive text
                                                 // Bytes 125-126 indicate version, set to 0x0100 hex = 256.
    prolog[124] = (fieldversion & 0xff) as u8;
    prolog[125] = ((fieldversion >> 8) & 0xff) as u8;
    prolog[126] = b'I'; // Characters IM to indicate little endian
    prolog[127] = b'M';

    // 8 byte MASTER TAG, followed by the actual data. First 4 is data type,
    // next 4 is number of bytes of entire field.
    prolog[128] = (mastertype & 0xff) as u8; // Data type is always 14 for matrix.
                                             // Number of bytes of data element
                                             //  = (8 + 8) + (8 + 8) + (8 + 8) + (8 + Nvalues*bytespervalue)
                                             //  = 56 + Nvalues*bytespervalue
    put32(&mut prolog, 132, nbytesmaster);

    // Matrix data has 4 subelements (5 if imag): Array flags, dimensions
    // array, array name, real part. Each subelement has its own subtag, and
    // subdata.

    // Subelement 1: Array flags.
    prolog[136] = (sub1type & 0xff) as u8; // Sub tag 1: type
    prolog[140] = 8; // Sub tag 1: size
                     // Value class, indicating the MATLAB data type. NOT the same as sub4type.
    prolog[144] = (sub1class & 0xff) as u8;

    // Subelement 2: Rows and Cols
    prolog[152] = (sub2type & 0xff) as u8; // Sub tag 2: type
    prolog[156] = 8; // sub tag 2: size
    put32(&mut prolog, 160, nosig as u64); // Number of signals.
    put32(&mut prolog, 164, (to - from) as u64); // Value nrows.

    // Subelement 3: Array Name
    prolog[168] = (sub3type & 0xff) as u8;
    prolog[172] = 3; // Sub tag 3: size (that of the name)
    prolog[176..179].copy_from_slice(b"val");

    // Subelement 4: Data itself
    prolog[184] = (sub4type & 0xff) as u8;
    put32(&mut prolog, 188, nbytesofdata);

    // Total size of everything before actual data:
    //   128 byte header
    // + 8 byte master tag
    // + 56 byte Subelements (48 byte default + 8 byte name)
    // = 192.
    wfdbx::wfdbputprolog(&prolog, PROLOGLEN as i64, 0);

    // Copy the selected data into the .mat file.
    t = from;
    while t < to && stat >= 0 {
        stat = wfdbx::getvec(&mut vi);
        for (i, v) in vo.iter_mut().enumerate() {
            *v = vi[sig[i]].wrapping_sub(si[sig[i]].adczero);
        }
        if wfdbx::putvec(&vo) != nosig as i32 {
            break;
        }
        t += 1;
    }

    // If the input ended prematurely, pad the matrix with invalid samples.
    if t != to {
        ceprintf!(
            b"%s (warning): final %lld columns are invalid\n",
            pname,
            to - t
        );
        vo.fill(WFDB_INVALID_SAMPLE);
        while t < to {
            t += 1;
            wfdbx::putvec(&vo);
        }
    }

    // Create the new header file.
    wfdbx::setsampfreq(freq);
    let p = wfdbx::mstimstr(from.wrapping_neg());
    if p.first() == Some(&b'[') {
        wfdbx::setbasetime(&p[1..]);
    }
    wfdbx::newheader(&orec);

    // Copy info from the old record, if any
    while let Some(info) = wfdbx::getinfo(NULL) {
        wfdbx::putinfo(&info);
    }

    // Append additional info summarizing what wfdb2mat has done.
    let mut p = b"Creator: ".to_vec();
    p.extend_from_slice(&pname);
    wfdbx::putinfo(&p);
    let mut p = b"Source: record ".to_vec();
    p.extend_from_slice(&record);
    let qs = wfdbx::mstimstr(0);
    let k = qs.iter().take_while(|&&c| c == b' ').count();
    let q = &qs[k..];
    if from != 0 || q.first() == Some(&b'[') {
        p.extend_from_slice(b"  Start: ");
        p.extend_from_slice(q);
    }
    wfdbx::putinfo(&p);

    // Determine offset between sample values and the raw byte/word values
    // as interpreted by Matlab/Octave.
    // (Format 80 stores samples offset by 128, as unsigned bytes.)
    let offset: i32 = if wfdbtype == 80 { 128 } else { 0 };

    // Summarize the contents of the .mat file.
    let ns = nosig as i32;
    let s1: &[u8] = if ns == 1 { b"" } else { b"s" };
    let s2: &[u8] = if to == from + 1 { b"" } else { b"s" };
    cprintf!(b"%s\n", p);
    cprintf!(
        b"val has %d row%s (signal%s) and %lld column%s (sample%s/signal)\n",
        ns,
        s1,
        s1,
        to - from,
        s2,
        s2
    );
    cprintf!(b"Duration: %s\n", wfdbx::timstr(to - from));
    cprintf!(
        b"Sampling frequency: %.12g Hz  Sampling interval: %.10g sec\n",
        freq,
        1.0 / freq
    );
    cprintf!(b"Row\tSignal\tGain\tBase\tUnits\n");
    for (i, o) in so.iter().enumerate() {
        let desc: &[u8] = o.desc.as_deref().unwrap_or(b"(null)");
        cprintf!(
            b"%d\t%s\t%.12g\t%d\t%s\n",
            i as i32 + 1,
            desc,
            o.gain,
            o.baseline.wrapping_add(offset),
            o.units.as_deref().unwrap_or(b"")
        );
    }
    cprintf!(
        b"\nTo convert from raw units to the physical units shown\nabove, call the 'rdmat.m' function from the wfdb-matlab\ntoolbox: https://physionet.org/physiotools/matlab/wfdb-app-matlab/\n"
    );
    wfdbx::wfdbquit();
    cstd::exit(0);
}
