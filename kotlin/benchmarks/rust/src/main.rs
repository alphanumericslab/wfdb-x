//! The benchmark program of the Rust implementation, with the operations of
//! kotlin/benchmarks/src/Bench.kt (see kotlin/benchmarks/run.sh):
//!
//!   wfdbx-bench read   DIR REC REPS
//!   wfdbx-bench write  DIR REC OUTDIR REPS
//!   wfdbx-bench ann    OUTDIR REPS
//!   wfdbx-bench getvec DIR REC REPS
//!
//! Each prints the best time of REPS runs (after one untimed run) and a
//! digest of the data (FNV-1a of the samples).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::path::PathBuf;
use std::time::Instant;
use wfdbx::*;

const FNV0: u64 = 14695981039346656037;

fn fnv(h: u64, v: i32) -> u64 {
    (h ^ u64::from(v as u32)).wrapping_mul(1099511628211)
}

fn best_ms(reps: usize, mut f: impl FnMut()) -> f64 {
    f(); // (warm-up, as for the JVM)
    let mut best = f64::MAX;
    for _ in 0..reps {
        let t = Instant::now();
        f();
        best = best.min(t.elapsed().as_secs_f64() * 1000.0);
    }
    best
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a[1].as_str() {
        "read" => {
            let opt = ReadOptions { input_dir: Some(a[2].clone()), ..Default::default() };
            let mut r = None;
            let ms = best_ms(a[4].parse().unwrap(), || r = Some(read_record(&a[3], &opt).unwrap()));
            let r = r.unwrap();
            let h = r.samples.iter().fold(FNV0, |h, &v| fnv(h, v));
            println!("read_record {ms:.1} ms frames={} nsig={} digest={h:x}", r.nsamples(), r.nsig);
        }
        "write" => {
            let opt = ReadOptions { input_dir: Some(a[2].clone()), ..Default::default() };
            let r = read_record(&a[3], &opt).unwrap();
            let w = WriteOptions {
                fmt: 16,
                gains: r.siginfo.iter().map(|s| s.gain).collect(),
                baselines: r.siginfo.iter().map(|s| s.baseline).collect(),
                adcres: vec![16],
                units: vec![Some("mV".into())],
                names: r.names(),
                dir: Some(PathBuf::from(&a[4])),
                ..Default::default()
            };
            let ms = best_ms(a[5].parse().unwrap(), || {
                write_record(&a[3], &r.samples, r.nsig, r.fs, &w).unwrap()
            });
            println!("write_record {ms:.1} ms");
        }
        "ann" => {
            let n = 200000usize;
            let cyc = [1, 1, 1, 5, 8, 1, 12, 1];
            let ann = Annotations {
                samples: (0..n as i64).map(|k| 10 * k + (7 * k) % 9).collect(),
                codes: (0..n).map(|k| cyc[k % 8]).collect(),
                subtypes: (0..n).map(|k| i32::from(k % 50 == 0)).collect(),
                aux: (0..n).map(|k| if k % 1000 == 0 { Some(b"(N".to_vec()) } else { None }).collect(),
                ..Default::default()
            };
            let dir = PathBuf::from(&a[2]);
            let ms = best_ms(a[3].parse().unwrap(), || {
                write_annotations("big", "bench", &ann, 0.0, Some(&dir)).unwrap()
            });
            println!("write_annotations {ms:.1} ms");
        }
        "getvec" => {
            wfdbx_set_input_dir(a[2].as_str());
            let rec = a[3].as_str();
            let mut h = FNV0;
            let mut frames = 0u64;
            let ms = best_ms(a[4].parse().unwrap(), || {
                wfdbquit();
                let n = isigopen(rec, &mut [], 0);
                let mut si = vec![Siginfo::default(); n as usize];
                isigopen(rec, &mut si, n);
                let mut v = vec![0i32; n as usize];
                h = FNV0;
                frames = 0;
                while getvec(&mut v) >= 0 {
                    for &x in &v {
                        h = fnv(h, x);
                    }
                    frames += 1;
                }
                wfdbquit();
            });
            println!("getvec {ms:.1} ms frames={frames} digest={h:x}");
        }
        c => panic!("unknown command {c}"),
    }
}
