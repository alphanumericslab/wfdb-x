//! Tests of the bulk path of `getvecs` (signal.rs): for records in every
//! format it handles, with invalid samples, several signal groups, frames
//! that cross the end of the input buffers, the frame at which the
//! checksums are verified, truncated files and seeks, `getvecs` returns
//! exactly what the per-frame path returns (the same samples, statuses,
//! messages and input position), and leaves the same state behind (the
//! frames read afterwards, frame by frame, are the same too).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::path::PathBuf;

use wfdbx::*;

/// A fresh, empty current directory (the tests of this file run in one
/// test function, so there is no concurrency).
fn enter_tmp() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wfdbx-rs-bulk-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::env::set_current_dir(&dir).unwrap();
    dir
}

/// A small deterministic random number generator.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn range(&mut self, lo: i64, hi: i64) -> i64 {
        lo + (self.next() as i64).rem_euclid(hi - lo + 1)
    }
}

/// The range of the samples of a format (the lowest value is the code of
/// an invalid sample, except in format 8).
fn range(fmt: i32) -> (i64, i64) {
    match fmt {
        80 => (-128, 127),
        310 | 311 => (-512, 511),
        212 => (-2048, 2047),
        16 | 61 | 160 => (-32768, 32767),
        24 => (-(1 << 23), (1 << 23) - 1),
        _ => (i32::MIN as i64, i32::MAX as i64),
    }
}

/// Writes record `name`: groups of signals (one signal file per group, in
/// the format of the group), `n` frames of random samples, about 5% of
/// them invalid (format 8: a random walk, without invalid samples).
fn write_rec(w: &mut Wfdb, rng: &mut Rng, name: &str, groups: &[(i32, usize)], n: usize) {
    let mut si = Vec::new();
    for (g, &(fmt, nn)) in groups.iter().enumerate() {
        for k in 0..nn {
            si.push(Siginfo {
                fname: Some(format!("{name}_{g}.dat").into_bytes()),
                desc: Some(format!("s{g}.{k}").into_bytes()),
                group: g as _,
                fmt,
                gain: 200.0,
                adcres: 16,
                units: Some(b"mV".to_vec()),
                ..Default::default()
            });
        }
    }
    let nsig = si.len();
    let r = w.osigfopen(&si, nsig as u32);
    assert_eq!(
        r,
        nsig as i32,
        "{name}: {}",
        String::from_utf8_lossy(&w.wfdberror())
    );
    w.setsampfreq(100.0);
    let mut prev = vec![0i64; nsig];
    let mut v = vec![0i32; nsig];
    for _ in 0..n {
        for s in 0..nsig {
            let fmt = si[s].fmt;
            v[s] = if fmt == 8 {
                prev[s] = (prev[s] + rng.range(-60, 60)).clamp(-2000, 2000);
                prev[s] as i32
            } else if rng.below(20) == 0 {
                if fmt == 32 && rng.below(2) == 0 {
                    i32::MIN
                } else {
                    WFDB_INVALID_SAMPLE
                }
            } else {
                let (lo, hi) = range(fmt);
                // (mostly small values, some extreme ones)
                match rng.below(10) {
                    0 => lo as i32,
                    1 => hi as i32,
                    _ => rng.range(lo.max(-3000), hi.min(3000)) as i32,
                }
            };
        }
        assert!(w.putvec(&v) >= 0);
    }
    assert_eq!(w.newheader(name), 0);
    w.wfdbquit();
}

/// Everything observable about a read: the result of each `getvecs` call,
/// the samples, the last error message and the input position after each
/// call, and the frames read frame by frame (with `getvec`) afterwards.
#[derive(Debug, PartialEq)]
struct Trace {
    calls: Vec<(i64, i32, i64, Vec<u8>)>,
    samples: Vec<i32>,
    after: Vec<(i32, Vec<i32>)>,
}

/// Reads record `name` with `getvecs` (bulk path on or off), in calls of
/// the sizes of `chunks` (repeated), after seeking to each time of
/// `seeks` in turn (no seek if empty), then reads up to 50 more frames
/// with `getvec`.
fn trace(
    w: &mut Wfdb,
    name: &str,
    bulk: bool,
    mode: i32,
    ibsize: i32,
    chunks: &[i64],
    seeks: &[i64],
) -> Trace {
    w.setibsize(ibsize);
    let nsig = w.isigopen(name, &mut [], 0);
    let mut si = vec![Siginfo::default(); nsig as usize];
    assert_eq!(w.isigopen(name, &mut si, nsig), nsig);
    w.wfdbx_bulk_read(bulk);
    w.setgvmode(mode);
    let nsig = nsig as usize;
    let mut t = Trace {
        calls: Vec::new(),
        samples: Vec::new(),
        after: Vec::new(),
    };
    let mut buf = vec![0i32; 20000 * nsig];
    let passes = if seeks.is_empty() { 1 } else { seeks.len() };
    for p in 0..passes {
        if let Some(&s) = seeks.get(p) {
            let r = w.isigsettime(s);
            t.calls.push((-100, r, w.strtim("i"), w.wfdberror()));
        }
        let mut i = 0;
        loop {
            let n = chunks[i % chunks.len()];
            i += 1;
            let (got, stat) = w.getvecs_status(&mut buf, n);
            t.calls.push((got, stat, w.strtim("i"), w.wfdberror()));
            let mut k = got.max(0) as usize;
            if stat < 0 && stat != -1 && got < n {
                k += 1; // (the frame of a negative status: also compared)
            }
            t.samples.extend_from_slice(&buf[..k * nsig]);
            if got < n || (!seeks.is_empty() && i > 3) {
                break;
            }
        }
    }
    let mut v = vec![0i32; nsig];
    for _ in 0..50 {
        let r = w.getvec(&mut v);
        t.after.push((r, v.clone()));
        if r < 0 {
            break;
        }
    }
    w.wfdbx_bulk_read(true);
    w.wfdbquit();
    w.setibsize(0);
    t
}

/// Compares the bulk and the per-frame paths on record `name`.
fn check(w: &mut Wfdb, rng: &mut Rng, name: &str, nframes: i64) {
    let modes = [WFDB_LOWRES, WFDB_LOWRES | WFDB_GVPAD];
    for (k, &mode) in modes.iter().enumerate() {
        for &ibsize in &[0, 7, 100, 1000] {
            let chunk_sets: [Vec<i64>; 4] = [
                vec![nframes + 10],
                vec![nframes],
                vec![1, 333, 2, 1000, 5],
                vec![rng.range(1, 2000), rng.range(1, 50), rng.range(1, 5000)],
            ];
            for chunks in &chunk_sets {
                let a = trace(w, name, true, mode, ibsize, chunks, &[]);
                let b = trace(w, name, false, mode, ibsize, chunks, &[]);
                assert_eq!(a, b, "{name} mode {mode} ibsize {ibsize} chunks {chunks:?}");
                assert!(!a.samples.is_empty() || nframes == 0);
            }
            // seeks, then reads
            let seeks: Vec<i64> = (0..6)
                .map(|_| rng.range(0, nframes + 2))
                .chain([nframes - 1, 0, 1, 2])
                .collect();
            let chunks = [rng.range(1, 3000), rng.range(1, 7)];
            let a = trace(w, name, true, mode, ibsize, &chunks, &seeks);
            let b = trace(w, name, false, mode, ibsize, &chunks, &seeks);
            assert_eq!(a, b, "{name} mode {k} ibsize {ibsize} seeks {seeks:?}");
        }
    }
}

#[test]
fn bulk_equals_per_frame() {
    let old = std::env::current_dir().unwrap();
    let dir = enter_tmp();
    let mut w = Wfdb::new();
    w.setwfdb(".");
    w.wfdbquiet();
    let mut rng = Rng(20261026);
    let fmts = [8, 80, 16, 61, 160, 24, 32, 212, 310, 311];
    let mut cases: Vec<(String, Vec<(i32, usize)>)> = Vec::new();
    for &fmt in &fmts {
        for nn in [1, 2, 3, 4, 5] {
            cases.push((format!("r{fmt}_{nn}"), vec![(fmt, nn)]));
        }
    }
    // several groups (files), in the same or different formats
    cases.push(("g1".into(), vec![(212, 3), (16, 2)]));
    cases.push(("g2".into(), vec![(310, 1), (311, 2), (212, 1)]));
    cases.push(("g3".into(), vec![(16, 1), (16, 1), (8, 2), (24, 1)]));
    cases.push(("g4".into(), vec![(80, 2), (32, 1), (160, 3), (61, 1)]));
    for (name, groups) in &cases {
        let n = rng.range(2000, 6000);
        write_rec(&mut w, &mut rng, name, groups, n as usize);
        // as written (correct checksums)
        check(&mut w, &mut rng, name, n);
        let files: Vec<String> = (0..groups.len())
            .map(|g| format!("{name}_{g}.dat"))
            .collect();
        let orig: Vec<Vec<u8>> = files.iter().map(|f| std::fs::read(f).unwrap()).collect();
        // a checksum error (one byte changed, in the middle of the file)
        let mut d = orig[0].clone();
        let k = d.len() / 2;
        d[k] ^= 0x11;
        std::fs::write(&files[0], &d).unwrap();
        check(&mut w, &mut rng, name, n);
        // a truncated file (the end of a frame, and the middle of one)
        let last = files.len() - 1;
        for cut in [orig[last].len() / 3, orig[last].len() - 1] {
            std::fs::write(&files[0], &orig[0]).unwrap();
            std::fs::write(&files[last], &orig[last][..cut]).unwrap();
            check(&mut w, &mut rng, name, n);
        }
        std::fs::write(&files[last], &orig[last]).unwrap();
    }
    // a record whose header gives no number of samples (no checksums)
    write_rec(&mut w, &mut rng, "nolen", &[(16, 2)], 3000);
    let h = std::fs::read_to_string("nolen.hea").unwrap();
    let h = h.replacen("nolen 2 100 3000", "nolen 2 100", 1);
    std::fs::write("nolen.hea", h).unwrap();
    check(&mut w, &mut rng, "nolen", 3000);
    std::env::set_current_dir(old).unwrap();
    let _ = std::fs::remove_dir_all(dir);
}

/// read_record gives the same record with the bulk path on and off.
#[test]
fn read_record_bulk() {
    let mut w = Wfdb::new();
    w.wfdbquiet();
    let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
    w.setwfdb(data.to_str().unwrap());
    for rec in ["100s", "fmt16", "fmt212", "vlay", "multi"] {
        for (to, cols) in [(None, vec![]), (Some(1000.into()), vec!["0".to_string()])] {
            let opt = wfdbx::ReadOptions {
                to,
                channels: cols,
                ..Default::default()
            };
            let a = w.read_record(rec, &opt);
            // (read_record opens the record itself: the switch persists)
            w.wfdbx_bulk_read(false);
            let b = w.read_record(rec, &opt);
            w.wfdbx_bulk_read(true);
            assert_eq!(a, b, "{rec}");
        }
    }
}

/// A fresh, empty directory for test `tag` (the tests read and write in it
/// through absolute paths, without changing the current directory).
fn test_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wfdbx-rs-bulk-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Writes the random multi-frequency record `name` in `dir` (`spf`: samples
/// per frame of each signal; `n` frames), with about 1% invalid samples
/// (also at the start and at the end; format 8: a random walk).
#[allow(clippy::too_many_arguments)]
fn mf_record(
    w: &mut Wfdb,
    dir: &std::path::Path,
    name: &str,
    rng: &mut Rng,
    fmt: i32,
    spf: &[i32],
    n: usize,
    gains: &[f64],
    names: &[&str],
) {
    let cols: usize = spf.iter().map(|&k| k as usize).sum();
    let mut x = vec![0i32; n * cols];
    if fmt == 8 {
        for c in 0..cols {
            let mut v = 0i64;
            for i in 0..n {
                v += rng.range(-60, 60);
                x[i * cols + c] = v as i32;
            }
        }
    } else {
        let (lo, hi) = range(fmt);
        for v in x.iter_mut() {
            *v = if rng.below(1000) < 10 {
                WFDB_INVALID_SAMPLE
            } else {
                rng.range(lo + 1, hi) as i32
            };
        }
        x[0] = WFDB_INVALID_SAMPLE;
        x[cols] = WFDB_INVALID_SAMPLE;
        x[n * cols - 1] = WFDB_INVALID_SAMPLE;
    }
    let opt = WriteOptions {
        fmt,
        gains: gains.to_vec(),
        adcres: vec![16],
        units: vec![Some(b"mV".to_vec())],
        samps_per_frame: spf.to_vec(),
        names: names.iter().map(|s| s.as_bytes().to_vec()).collect(),
        dir: Some(dir.to_path_buf()),
        ..Default::default()
    };
    w.write_record(name, &x, spf.len(), 250.0, &opt).unwrap();
}

/// A reading mode of the multi-frequency tests (`physical`: compare the
/// samples in physical units too).
#[derive(Clone, Default)]
struct Mode {
    opt: ReadOptions,
    physical: bool,
}

fn mf_modes() -> Vec<Mode> {
    let mut v = vec![Mode::default(); 9];
    v[1].opt.pad = true;
    v[2].opt.highres = true;
    v[3].opt.highres = true;
    v[3].opt.pad = true;
    v[4].physical = true;
    v[5].opt.from = Some(1234.into());
    v[6].opt.from = Some(7.into());
    v[6].opt.to = Some(15000.into());
    v[7].opt.highres = true;
    v[7].opt.from = Some(3.into());
    v[7].opt.to = Some(9001.into());
    v[8].opt.channels = vec!["1".into(), "0".into(), "1".into()];
    v
}

/// What read_record returns (also in physical units if `m.physical`; NaN
/// compared by its bits), with the bulk path on or off.
fn read_mode(
    w: &mut Wfdb,
    rec: &str,
    m: &Mode,
    bulk: bool,
) -> (Result<Record, wfdbx::record::Error>, Vec<u64>) {
    w.wfdbx_bulk_read(bulk);
    let r = w.read_record(rec, &m.opt);
    w.wfdbx_bulk_read(true);
    let mut phys = Vec::new();
    if let (Ok(r), true) = (&r, m.physical) {
        for s in 0..r.nsig {
            phys.extend(r.physical_signal(s).unwrap().iter().map(|v| v.to_bits()));
        }
    }
    (r, phys)
}

/// read_record gives the same with and without the bulk path.
fn same_read(w: &mut Wfdb, rec: &str, m: &Mode) {
    let a = read_mode(w, rec, m, true);
    let b = read_mode(w, rec, m, false);
    assert!(
        a == b,
        "{rec}: highres {} pad {} from {:?} to {:?} channels {:?}",
        m.opt.highres,
        m.opt.pad,
        m.opt.from,
        m.opt.to,
        m.opt.channels
    );
}

/// (vectors read by read_record, vectors of them read in blocks)
fn bulk_rows(w: &mut Wfdb, rec: &str, opt: &ReadOptions) -> (i64, i64) {
    let before = w.wfdbx_bulk_vectors();
    let r = w.read_record(rec, opt).unwrap();
    (r.nsamples() as i64, w.wfdbx_bulk_vectors() - before)
}

/// Checks that almost all the vectors of a read of `rec` are read in
/// blocks (at least 99%, and all but a few frames of `per` vectors in short
/// records): all but those of a few frames per input buffer (whose last
/// frame is read frame by frame) and per segment, and near the end.
fn mostly_bulk(w: &mut Wfdb, rec: &str, highres: bool, per: i64) {
    let opt = ReadOptions {
        highres,
        ..Default::default()
    };
    let (rows, bulk) = bulk_rows(w, rec, &opt);
    assert!(
        (rows - bulk) * 100 <= rows + 100 * 6 * per,
        "{rec} highres {highres}: {bulk} of {rows} vectors read in blocks"
    );
}

/// Writes the segments name_1, name_2, ... (one per length) and returns
/// the lines of the master header naming them, and their total length.
#[allow(clippy::too_many_arguments)]
fn write_segments(
    w: &mut Wfdb,
    dir: &std::path::Path,
    name: &str,
    rng: &mut Rng,
    fmt: i32,
    spf: &[i32],
    lens: &[usize],
    gains: &[f64],
    names: &[&str],
) -> (String, usize) {
    let mut lines = String::new();
    for (k, &len) in lens.iter().enumerate() {
        let seg = format!("{name}_{}", k + 1);
        mf_record(w, dir, &seg, rng, fmt, spf, len, gains, names);
        lines += &format!("{seg} {len}\n");
    }
    (lines, lens.iter().sum())
}

const FORMATS: [i32; 10] = [8, 80, 16, 61, 160, 24, 32, 212, 310, 311];

/// Records of several sampling frequencies are read in blocks: the same
/// samples as frame by frame, in low- and high-resolution modes.
#[test]
fn bulk_read_multifrequency() {
    let dir = test_dir("mf");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    let spfs: [&[i32]; 5] = [&[4, 1, 1, 1], &[2, 3], &[1, 2], &[8, 1], &[3, 3, 1]];
    for fmt in FORMATS {
        let mut rng = Rng(fmt as u64 + 1);
        for spf in spfs {
            let n = rng.range(16000, 23999) as usize;
            mf_record(&mut w, &dir, "m", &mut rng, fmt, spf, n, &[200.0], &[]);
            for m in &mf_modes() {
                same_read(&mut w, "m", m);
            }
            let mx = *spf.iter().max().unwrap() as i64;
            mostly_bulk(&mut w, "m", true, mx);
            mostly_bulk(&mut w, "m", false, 1);
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// Large input buffers (many tiles of frames decoded at once by the bulk
/// path) and lengths that are not multiples of the tile: the same samples
/// as frame by frame, in every mode.
#[test]
fn bulk_read_tiles() {
    let dir = test_dir("tl");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    let spfs: [&[i32]; 4] = [&[1], &[1, 1, 1], &[2, 3], &[4, 1, 1, 1]];
    for fmt in FORMATS {
        let mut rng = Rng(fmt as u64 + 100);
        for spf in spfs {
            for n in [1023, 1024, 2049, rng.range(5000, 9000) as usize] {
                mf_record(&mut w, &dir, "t", &mut rng, fmt, spf, n, &[200.0], &[]);
                for ibsize in [0, 1 << 16, 1 << 20] {
                    w.setibsize(ibsize);
                    for m in &mf_modes() {
                        same_read(&mut w, "t", m);
                    }
                    mostly_bulk(&mut w, "t", false, 1);
                }
                w.setibsize(0);
            }
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// read_record gives what getvec gives, vector by vector (the vector of
/// status -4 kept, reading stopped by another negative status or at `to`).
fn getvec_reference(w: &mut Wfdb, rec: &str, opt: &ReadOptions) -> (Vec<i32>, i32) {
    let nsig = w.isigopen(rec, &mut [], 0);
    let mut si = vec![Siginfo::default(); nsig as usize];
    assert_eq!(w.isigopen(rec, &mut si, nsig), nsig);
    w.setgvmode(if opt.highres {
        WFDB_HIGHRES
    } else {
        WFDB_LOWRES
    });
    let from = match &opt.from {
        Some(t) => t.resolve(w),
        None => 0,
    };
    let to = opt.to.as_ref().map(|t| t.resolve(w));
    assert!(w.isigsettime(from) >= 0);
    let mut v = vec![0i32; nsig as usize];
    let mut x = Vec::new();
    let mut k = from;
    let stat = loop {
        if to.is_some_and(|t| k >= t) {
            break 0;
        }
        let r = w.getvec(&mut v);
        if r < 0 && r != -4 {
            break r;
        }
        x.extend_from_slice(&v);
        k += 1;
    };
    w.wfdbquit();
    (x, stat)
}

/// The end of the data in read_record: files as long as their header
/// says, longer, shorter, and headers without a length.
#[test]
fn read_record_end() {
    let dir = test_dir("end");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    let mut rng = Rng(77);
    for (fmt, spf) in [
        (212, &[1, 1][..]),
        (16, &[4, 1, 1, 1][..]),
        (311, &[1, 2][..]),
    ] {
        let n = 10000;
        mf_record(&mut w, &dir, "e", &mut rng, fmt, spf, n, &[200.0], &[]);
        let hea = std::fs::read_to_string(dir.join("e.hea")).unwrap();
        let first = hea.lines().next().unwrap().to_string();
        let nsig = spf.len();
        // header lengths: as the file, shorter (by a few vectors and by more
        // than a block), longer, none
        for len in [
            Some(n),
            Some(n - 1),
            Some(n - 7),
            Some(n - 7000),
            Some(n + 5),
            None,
        ] {
            let line = match len {
                Some(l) => format!("e {nsig} 250 {l}"),
                None => format!("e {nsig} 250"),
            };
            std::fs::write(dir.join("e.hea"), hea.replacen(&first, &line, 1)).unwrap();
            for highres in [false, true] {
                for (from, to) in [(None, None), (Some(3), None), (Some(0), Some(n as i64 - 2))] {
                    let opt = ReadOptions {
                        highres,
                        from: from.map(|t: i64| t.into()),
                        to: to.map(|t: i64| t.into()),
                        checksum_warning: false,
                        ..Default::default()
                    };
                    let (want, stat) = getvec_reference(&mut w, "e", &opt);
                    let got = w.read_record("e", &opt);
                    let what = format!("fmt {fmt} len {len:?} highres {highres} {from:?}-{to:?}");
                    if stat < -1 && stat != -4 {
                        assert!(got.is_err(), "{what}");
                    } else {
                        assert_eq!(got.unwrap().samples, want, "{what}");
                    }
                }
            }
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// physical_signal gives what physical gives, sample by sample (NaN for
/// invalid samples), and the same errors.
#[test]
fn physical_signal_per_sample() {
    let dir = test_dir("ph");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    // (the WFDB path of legacy mode)
    w.wfdbx_set_legacy(1);
    w.setwfdb(dir.to_str().unwrap());
    w.wfdbx_set_legacy(0);
    let mut rng = Rng(3);
    mf_record(
        &mut w,
        &dir,
        "p",
        &mut rng,
        16,
        &[1, 1, 1],
        3001,
        &[200.0, 0.0, 12.5],
        &[],
    );
    let hea = std::fs::read_to_string(dir.join("p.hea")).unwrap();
    // (a baseline other than 0)
    std::fs::write(
        dir.join("p.hea"),
        hea.replacen("12.5/mV", "12.5(-300)/mV", 1),
    )
    .unwrap();
    for legacy in [false, true] {
        for channels in [vec![], vec!["2".to_string(), "0".to_string()]] {
            let opt = ReadOptions {
                legacy,
                channels,
                ..Default::default()
            };
            let r = w.read_record("p", &opt).unwrap();
            assert!(r.siginfo.iter().any(|s| s.baseline == -300));
            assert_eq!(r.siginfo.iter().any(|s| s.gain == 0.0), r.nsig == 3);
            assert!(r.samples.contains(&WFDB_INVALID_SAMPLE));
            for s in 0..r.nsig {
                let per: Result<Vec<u64>, String> = (0..r.nsamples())
                    .map(|i| {
                        r.physical(i, s)
                            .map(f64::to_bits)
                            .map_err(|e| e.to_string())
                    })
                    .collect();
                let all = r
                    .physical_signal(s)
                    .map(|v| v.iter().map(|x| x.to_bits()).collect::<Vec<u64>>())
                    .map_err(|e| e.to_string());
                assert_eq!(all, per, "legacy {legacy} signal {s}");
            }
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// Multi-segment records, of fixed and of variable layout (with signals
/// missing from some segments, other gains, and a null segment), are read
/// in blocks: the same samples as frame by frame.
#[test]
fn bulk_read_multisegment() {
    let dir = test_dir("ms");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    let mut rng = Rng(11);
    let names = ["ECG", "ABP", "RESP"];
    // fixed layout
    let (segs, total) = write_segments(
        &mut w,
        &dir,
        "fx",
        &mut rng,
        212,
        &[4, 1, 1],
        &[9000, 7001, 12000],
        &[200.0],
        &names,
    );
    std::fs::write(dir.join("fx.hea"), format!("fx/3 3 250 {total}\n{segs}")).unwrap();
    let mut modes = mf_modes();
    let mut m = Mode::default();
    m.opt.from = Some(8999.into());
    m.opt.to = Some(16002.into());
    modes.push(m);
    for m in &modes {
        same_read(&mut w, "fx", m);
    }
    let opt = ReadOptions::default();
    assert_eq!(w.read_record("fx", &opt).unwrap().nsamples(), 28001);
    mostly_bulk(&mut w, "fx", false, 3);
    mostly_bulk(&mut w, "fx", true, 3 * 4);
    // variable layout
    std::fs::write(
        dir.join("vl_0.hea"),
        "vl_0 3 250 0\n\
         ~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n\
         ~ 0 100/mV 16 0 0 0 0 ABP\n\
         ~ 0 50/mV 16 0 0 0 0 RESP\n",
    )
    .unwrap();
    let (s1, t1) = write_segments(
        &mut w,
        &dir,
        "va",
        &mut rng,
        16,
        &[4, 1, 1],
        &[5000],
        &[400.0, 100.0, 50.0],
        &names,
    );
    let (s2, t2) = write_segments(
        &mut w,
        &dir,
        "vb",
        &mut rng,
        16,
        &[1, 4],
        &[6003],
        &[25.0, 200.0],
        &["RESP", "ECG"],
    );
    let (s3, t3) = write_segments(
        &mut w,
        &dir,
        "vc",
        &mut rng,
        212,
        &[1],
        &[4000],
        &[100.0],
        &["ABP"],
    );
    let total = 2500 + t1 + t2 + t3;
    std::fs::write(
        dir.join("vl.hea"),
        format!("vl/5 3 250 {total}\nvl_0 0\n{s1}~ 2500\n{s2}{s3}"),
    )
    .unwrap();
    let last = modes.len() - 1;
    modes[last].opt.from = Some(4990.into());
    modes[last].opt.to = Some(9000.into());
    for m in &modes {
        same_read(&mut w, "vl", m);
    }
    mostly_bulk(&mut w, "vl", false, 6);
    mostly_bulk(&mut w, "vl", true, 6 * 4);
    let r = w.read_record("vl", &opt).unwrap();
    assert_eq!(r.nsamples(), 17503);
    for i in 5000..7500 {
        for s in 0..3 {
            assert!(r.physical(i, s).unwrap().is_nan());
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// Every record of tests/data (but those read from the standard input, 8
/// and 16): the same in blocks as frame by frame, in five reading modes (or
/// the same error).
#[test]
fn bulk_read_all_test_records() {
    let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
    let mut recs: Vec<String> = std::fs::read_dir(&data)
        .unwrap()
        .filter_map(|e| {
            let p = e.unwrap().path();
            let stem = p.file_stem()?.to_str()?.to_string();
            (p.extension()? == "hea" && stem != "8" && stem != "16").then_some(stem)
        })
        .collect();
    recs.sort();
    let mut modes = vec![Mode::default(); 5];
    modes[1].opt.pad = true;
    modes[2].opt.highres = true;
    modes[3].opt.highres = true;
    modes[3].opt.pad = true;
    modes[4].opt.from = Some(3.into());
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(data.to_str().unwrap());
    for rec in &recs {
        for m in &modes {
            same_read(&mut w, rec, m);
        }
    }
}

/// getvecs (bulk) mixed with getvec and isigsettime on a multi-frequency
/// record, in high resolution also from the middle of a frame: the same
/// vectors, statuses and library state as frame by frame.
#[test]
fn bulk_multifrequency_interleaved() {
    let dir = test_dir("il");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    w.setwfdb(dir.to_str().unwrap());
    let mut rng = Rng(5);
    mf_record(
        &mut w,
        &dir,
        "mf",
        &mut rng,
        212,
        &[4, 1, 3],
        20001,
        &[200.0],
        &[],
    );
    let steps = [
        ('f', 999),
        ('v', 3),
        ('f', 4097),
        ('t', 17),
        ('v', 1),
        ('f', 9001),
        ('v', 2),
        ('t', 30),
        ('f', 200000),
    ];
    for hr in [false, true] {
        let mut out = [String::new(), String::new()];
        for (run, t) in out.iter_mut().enumerate() {
            w.wfdbx_bulk_read(run == 0);
            let mut si = vec![Siginfo::default(); 3];
            assert_eq!(w.isigopen("mf", &mut si, 3), 3);
            w.setgvmode(if hr { WFDB_HIGHRES } else { WFDB_LOWRES } | WFDB_GVPAD);
            for (op, k) in steps {
                match op {
                    'f' => {
                        let mut buf = vec![0i32; k as usize * 3];
                        let (m, stat) = w.getvecs_status(&mut buf, k);
                        *t += &format!("getvecs {m} {stat}: {:?}", &buf[..m.max(0) as usize * 3]);
                    }
                    'v' => {
                        for _ in 0..k {
                            let mut v = [0i32; 3];
                            let r = w.getvec(&mut v);
                            *t += &format!("getvec {r}: {v:?}\n");
                        }
                    }
                    _ => *t += &format!("isigsettime {}", w.isigsettime(k)),
                }
                *t += &format!("\n{}\n", w.wfdbx_input_state());
            }
            w.wfdbquit();
        }
        w.wfdbx_bulk_read(true);
        assert!(out[0] == out[1], "highres {hr}");
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// Descriptions that end (or begin) with white space in the header are
/// given without it by the high-level readers, and found by that name; the
/// C-style functions keep it, as in C.
#[test]
fn names_without_spaces() {
    let dir = test_dir("sp");
    let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
    std::fs::copy(data.join("fmt16.dat"), dir.join("fmt16.dat")).unwrap();
    std::fs::write(
        dir.join("sp.hea"),
        "sp 3 250 4\n\
         fmt16.dat 16 200/mV 16 0 0 0 0 III \n\
         fmt16.dat 16 200/mV 16 0 0 0 0 ABP\t \n\
         fmt16.dat 16 200/mV 16 0 0 0 0 PLETH\n",
    )
    .unwrap();
    let mut w = Wfdb::new();
    w.wfdbquiet();
    // (the input directory, and the WFDB path of legacy mode)
    w.setwfdb(dir.to_str().unwrap());
    w.wfdbx_set_legacy(1);
    w.setwfdb(dir.to_str().unwrap());
    w.wfdbx_set_legacy(0);
    let sp = "sp";
    let want: Vec<Vec<u8>> = vec![b"III".to_vec(), b"ABP".to_vec(), b"PLETH".to_vec()];
    let descs = |si: &[Siginfo]| -> Vec<Vec<u8>> {
        si.iter()
            .map(|s| s.desc.clone().unwrap_or_default())
            .collect()
    };
    for legacy in [false, true] {
        let opt = ReadOptions {
            legacy,
            checksum_warning: false,
            ..Default::default()
        };
        let r = w.read_record(sp, &opt).unwrap();
        assert_eq!(r.names(), want);
        assert_eq!(descs(&r.siginfo), want);
        let h = w.read_header_with(sp, &opt).unwrap();
        assert_eq!(descs(&h.siginfo), want);
        let opt2 = ReadOptions {
            channels: vec!["ABP".into(), "III ".into(), "2".into()],
            ..opt.clone()
        };
        let r2 = w.read_record(sp, &opt2).unwrap();
        assert_eq!(
            r2.names(),
            vec![b"ABP".to_vec(), b"III".to_vec(), b"PLETH".to_vec()]
        );
        assert_eq!(r2.nsamples(), r.nsamples());
        for i in 0..r.nsamples() {
            assert_eq!(r2.at(i, 0), r.at(i, 1));
            assert_eq!(r2.at(i, 1), r.at(i, 0));
            assert_eq!(r2.at(i, 2), r.at(i, 2));
        }
    }
    let mut si = vec![Siginfo::default(); 3];
    assert_eq!(w.isigopen(sp, &mut si, 3), 3);
    assert_eq!(
        descs(&si),
        vec![b"III ".to_vec(), b"ABP\t ".to_vec(), b"PLETH".to_vec()]
    );
    w.wfdbquit();
    let _ = std::fs::remove_dir_all(dir);
}
