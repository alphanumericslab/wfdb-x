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

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::Instant;

use wfdbx::record::Error;
use wfdbx::{
    read_annotations, read_record, write_annotations, write_record, Annotations, ReadOptions,
    Record, WriteOptions,
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

/// The result of a call: what it read (the physical values too, for
/// read_long_phys).
#[derive(Default)]
struct Res {
    rec: Option<Record>,
    phys: Vec<Vec<f64>>,
    ann: Option<Annotations>,
}

/// Save the result of the first call of `op` as dump/op.* (see
/// benchmarks/python/bench.py), little-endian.
fn save(op: &str, res: &Res, out: &Path, dump: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let p = |ext: &str| dump.join(format!("{op}.{ext}"));
    let mut b: Vec<u8> = Vec::new();
    match (op, res) {
        ("read_long" | "read_mimic" | "read_wide", Res { rec: Some(r), .. }) => {
            for &x in &r.samples {
                b.extend_from_slice(&x.to_le_bytes());
            }
            std::fs::File::create(p("bin"))?.write_all(&b)?;
        }
        ("read_long_phys", Res { phys: v, .. }) => {
            for i in 0..v.first().map_or(0, |x| x.len()) {
                for x in v {
                    b.extend_from_slice(&x[i].to_le_bytes());
                }
            }
            std::fs::File::create(p("bin"))?.write_all(&b)?;
        }
        ("read_ann", Res { ann: Some(a), .. }) => {
            for k in 0..a.len() {
                b.extend_from_slice(&a.samples[k].to_le_bytes());
                for x in [a.codes[k], a.subtypes[k], a.chans[k], a.nums[k]] {
                    b.extend_from_slice(&x.to_le_bytes());
                }
                match &a.aux[k] {
                    Some(x) => {
                        b.extend_from_slice(&(x.len() as i32).to_le_bytes());
                        b.extend_from_slice(x);
                    }
                    None => b.extend_from_slice(&(-1i32).to_le_bytes()),
                }
            }
            std::fs::File::create(p("ann"))?.write_all(&b)?;
        }
        ("write_long", _) => {
            std::fs::copy(out.join("out.hea"), p("hea"))?;
            std::fs::copy(out.join("out.dat"), p("dat"))?;
        }
        ("write_ann", _) => {
            std::fs::copy(out.join("out.atr"), p("atr"))?;
        }
        _ => unreachable!(),
    }
    Ok(())
}

/// The size of a file in bytes.
fn size(path: &Path) -> String {
    std::fs::metadata(path)
        .map(|m| m.len())
        .unwrap_or(0)
        .to_string()
}

fn run(op: &str, out: &Path, reps: usize) -> Result<String, Box<dyn std::error::Error>> {
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

    // call() is the timed call: the operation alone, returning what it
    // read. check() is computed from the first call's result, outside the
    // timed calls.
    let call = || -> Result<Res, Error> {
        let read = |name: &str| -> Result<Res, Error> {
            Ok(Res {
                rec: Some(read_record(name, &ReadOptions::default())?),
                ..Default::default()
            })
        };
        match op {
            "read_long" => read("long"),
            "read_long_phys" => {
                let rec = read_record("long", &ReadOptions::default())?;
                let phys = (0..rec.nsig)
                    .map(|s| rec.physical_signal(s))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Res {
                    rec: Some(rec),
                    phys,
                    ann: None,
                })
            }
            "read_mimic" => read("mimic"),
            "read_wide" => read("wide"),
            "write_long" => {
                let r = src.as_ref().unwrap();
                write_record("out", &r.samples, r.nsig, r.fs, wopt.as_ref().unwrap())?;
                Ok(Res::default())
            }
            "read_ann" => Ok(Res {
                ann: Some(read_annotations("long", "atr", None, None, None, false)?),
                ..Default::default()
            }),
            "write_ann" => {
                write_annotations("out", "atr", ann.as_ref().unwrap(), 0.0, Some(out))?;
                Ok(Res::default())
            }
            _ => unreachable!(),
        }
    };
    let check = |res: &Res| -> String {
        match op {
            "read_long" | "read_mimic" | "read_wide" => res
                .rec
                .as_ref()
                .unwrap()
                .samples
                .iter()
                .map(|&v| v as i64)
                .sum::<i64>()
                .to_string(),
            "read_long_phys" => {
                let sum: f64 = res
                    .phys
                    .iter()
                    .flat_map(|v| v.iter())
                    .filter(|v| !v.is_nan())
                    .sum();
                format!("{}", (sum * 1000.0).round() / 1000.0)
            }
            "write_long" => size(&out.join("out.dat")),
            "read_ann" => res.ann.as_ref().unwrap().len().to_string(),
            "write_ann" => size(&out.join("out.atr")),
            _ => unreachable!(),
        }
    };

    let dump = std::env::var_os("WFDBX_BENCH_DUMP").filter(|d| !d.is_empty());
    let t = Instant::now();
    let res = call()?;
    let first = t.elapsed().as_secs_f64();
    let check = check(&res);
    if let Some(d) = &dump {
        save(op, &res, out, Path::new(d))?;
    }
    drop(res);
    let mut times = Vec::with_capacity(reps);
    for _ in 0..reps {
        let t = Instant::now();
        let res = call()?;
        times.push(t.elapsed().as_secs_f64());
        drop(res);
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
