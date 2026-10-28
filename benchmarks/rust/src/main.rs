//! Benchmark driver for the Rust implementation of WFDB-x.
//!
//! Usage: `wfdbx_bench OP DATADIR REPS`
//!
//! See benchmarks/README.md for the operations and the output (one JSON
//! line on the standard output).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::Instant;

use wfdbx::record::Error;
use wfdbx::{
    read_annotations, read_record, write_annotations, write_record, Annotations, ReadOptions,
    WriteOptions,
};

const OPS: [&str; 7] = [
    "read_long",
    "read_long_phys",
    "read_mimic",
    "read_wide",
    "write_long",
    "read_ann",
    "write_ann",
];

/// The 64-bit sum of the samples of a record read with default options.
fn digital_sum(record: &str) -> Result<String, Error> {
    let rec = read_record(record, &ReadOptions::default())?;
    Ok(rec
        .samples
        .iter()
        .map(|&v| v as i64)
        .sum::<i64>()
        .to_string())
}

/// The size of a file in bytes.
fn size(path: &Path) -> String {
    std::fs::metadata(path)
        .map(|m| m.len())
        .unwrap_or(0)
        .to_string()
}

fn run(op: &str, out: &Path, reps: usize) -> Result<String, Error> {
    // Untimed preparation.
    let src = if op == "write_long" {
        Some(read_record("long", &ReadOptions::default())?)
    } else {
        None
    };
    let ann = if op == "write_ann" {
        let a = read_annotations("long", "atr", None, None, None, false)?;
        Some(Annotations {
            samples: a.samples,
            codes: a.codes,
            aux: a.aux,
            ..Default::default()
        })
    } else {
        None
    };
    let wopt = src.as_ref().map(|r| WriteOptions {
        fmt: 16,
        gains: r.siginfo.iter().map(|s| s.gain).collect(),
        adcres: vec![16],
        units: r.siginfo.iter().map(|s| s.units.clone()).collect(),
        dir: Some(out.to_path_buf()),
        ..Default::default()
    });

    let call = || -> Result<String, Error> {
        match op {
            "read_long" => digital_sum("long"),
            "read_long_phys" => {
                let rec = read_record("long", &ReadOptions::default())?;
                let mut sum = 0.0;
                for s in 0..rec.nsig {
                    sum += rec
                        .physical_signal(s)?
                        .iter()
                        .filter(|v| !v.is_nan())
                        .sum::<f64>();
                }
                Ok(format!("{}", (sum * 1000.0).round() / 1000.0))
            }
            "read_mimic" => digital_sum("mimic"),
            "read_wide" => digital_sum("wide"),
            "write_long" => {
                let r = src.as_ref().unwrap();
                write_record("out", &r.samples, r.nsig, r.fs, wopt.as_ref().unwrap())?;
                Ok(size(&out.join("out.dat")))
            }
            "read_ann" => Ok(read_annotations("long", "atr", None, None, None, false)?
                .len()
                .to_string()),
            "write_ann" => {
                write_annotations("out", "atr", ann.as_ref().unwrap(), 0.0, Some(out))?;
                Ok(size(&out.join("out.atr")))
            }
            _ => unreachable!(),
        }
    };

    let t = Instant::now();
    let check = call()?;
    let first = t.elapsed().as_secs_f64();
    let mut times = Vec::with_capacity(reps);
    for _ in 0..reps {
        let t = Instant::now();
        call()?;
        times.push(t.elapsed().as_secs_f64());
    }
    let best = times.iter().copied().fold(f64::INFINITY, f64::min);
    let times: Vec<String> = times.iter().map(|t| format!("{t:?}")).collect();
    Ok(format!(
        "{{\"op\": \"{op}\", \"first\": {first:?}, \"best\": {best:?}, \"times\": [{}], \"check\": {check}}}",
        times.join(", ")
    ))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: wfdbx_bench OP DATADIR REPS");
        exit(2);
    }
    let (op, dir) = (args[1].as_str(), args[2].as_str());
    if !OPS.contains(&op) {
        eprintln!("wfdbx_bench: unknown operation {op}");
        exit(2);
    }
    let reps: usize = match args[3].parse() {
        Ok(n) if n >= 1 => n,
        _ => {
            eprintln!("wfdbx_bench: REPS must be an integer >= 1");
            exit(2);
        }
    };
    wfdbx::wfdbx_set_input_dir(dir);
    let out: PathBuf = std::env::temp_dir().join(format!("wfdbx-bench-{}", std::process::id()));
    if let Err(e) = std::fs::create_dir_all(&out) {
        eprintln!("wfdbx_bench: can't create {}: {e}", out.display());
        exit(1);
    }
    let result = run(op, &out, reps);
    let _ = std::fs::remove_dir_all(&out);
    match result {
        Ok(line) => println!("{line}"),
        Err(e) => {
            eprintln!("wfdbx_bench: {op}: {e}");
            exit(1);
        }
    }
}
