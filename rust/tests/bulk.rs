//! Tests of the bulk path of `getvecs` (signal.rs): for records in every
//! format it handles, with invalid samples, several signal groups, frames
//! that cross the end of the input buffers, the frame at which the
//! checksums are verified, truncated files and seeks, `getvecs` returns
//! exactly what the per-frame path returns (the same samples, statuses,
//! messages and input position), and leaves the same state behind (the
//! frames read afterwards, frame by frame, are the same too).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests wfdb-x; it has no counterpart in the original package.
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
