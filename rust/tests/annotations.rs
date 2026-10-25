//! Tests of the annotation and calibration functions (`wfdbx::annot`,
//! `wfdbx::calib`), ports of the annotation parts of `cpp/tests/test_api.cpp`
//! and `cpp/tests/test_api_c.cpp`. The expected values were produced by the
//! original C library.
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

use std::path::PathBuf;
use std::sync::Mutex;

use wfdbx::cstd;
use wfdbx::*;

/// The tests change the current directory: they run one at a time.
static LOCK: Mutex<()> = Mutex::new(());

/// A fresh copy of tests/data, made the current directory while the value
/// lives.
struct DataDir {
    old: PathBuf,
    dir: PathBuf,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl DataDir {
    fn new(name: &str) -> DataDir {
        let guard = LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
        let dir =
            std::env::temp_dir().join(format!("wfdbx-rust-ann-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for e in std::fs::read_dir(&data).unwrap() {
            let e = e.unwrap();
            if e.file_type().unwrap().is_file() {
                std::fs::copy(e.path(), dir.join(e.file_name())).unwrap();
            }
        }
        let old = std::env::current_dir().unwrap();
        std::env::set_current_dir(&dir).unwrap();
        DataDir {
            old,
            dir,
            _guard: guard,
        }
    }

    /// A new library state with the WFDB path ".".
    fn wfdb(&self) -> Wfdb {
        let mut w = Wfdb::new();
        w.setwfdb(".");
        w
    }
}

impl Drop for DataDir {
    fn drop(&mut self) {
        let _ = std::env::set_current_dir(&self.old);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn unhex(h: &str) -> Vec<u8> {
    let d: Vec<u8> = h.bytes().filter(|&c| c != b' ').collect();
    d.chunks(2)
        .map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap(), 16).unwrap())
        .collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|c| format!("{c:02x}")).collect()
}

/// getann: status, time, anntyp, subtyp, chan, num.
fn ann(w: &mut Wfdb, n: u32) -> Vec<i64> {
    let mut a = Annotation::default();
    let stat = w.getann(n, &mut a);
    vec![
        stat as i64,
        a.time,
        a.anntyp as i64,
        a.subtyp as i64,
        a.chan as i64,
        a.num as i64,
    ]
}

fn ai(name: &str, stat: i32) -> [Anninfo; 1] {
    [Anninfo {
        name: name.as_bytes().to_vec(),
        stat,
    }]
}

fn aux(s: &[u8]) -> Option<Vec<u8>> {
    let mut v = vec![s.len() as u8];
    v.extend_from_slice(s);
    Some(v)
}

#[test]
fn annopen_errors() {
    let d = DataDir::new("errors");
    let mut w = d.wfdb();
    w.wfdbquiet();
    assert_eq!(w.annopen("nosuch", &ai("atr", WFDB_READ), 1), -3);
    assert_eq!(
        w.wfdberror(),
        b"annopen: can't read annotator atr for record nosuch\n"
    );
}

#[test]
fn annotations_read() {
    let d = DataDir::new("read");
    let mut w = d.wfdb();
    assert_eq!(w.annopen("100s", &ai("atr", WFDB_READ), 1), 0);
    let mut a = Annotation::default();
    let mut v = Vec::new();
    while w.getann(0, &mut a) == 0 {
        v.push(a.clone());
    }
    assert_eq!(v.len(), 75);
    assert_eq!(w.annstr(v[0].anntyp as i32), b"+");
    assert_eq!(w.annstr(v[1].anntyp as i32), b"N");
    // (the aux string of the file includes its terminating null)
    assert_eq!(cstd::cstr(&v[0].aux.as_ref().unwrap()[1..]), b"(N");
    w.wfdbquit();
}

/// The C API, as in the C program that produced the expected output and
/// files (MIT and AHA output, reading back, iannsettime, wrong formats,
/// errors).
#[test]
fn api_like_c() {
    let d = DataDir::new("apic");
    let mut w = d.wfdb();
    w.wfdbquiet();
    let mut out = String::new();
    let times: [i64; 12] = [
        0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000, 4000000000, 10, 3000000000,
    ];
    let codes = [
        NOTE, NORMAL, NORMAL, NORMAL, PVC, ARFCT, RHYTHM, NORMAL, NOISE, NORMAL, 0, VFON,
    ];
    let chans = [0, 0, 1, 1, 0, 3, 0, 0, 2, 200, 0, 5];
    let nums = [0, 0, 0, 2, 0, -1, 0, 0, 1, 0, 3, -128];
    let subs = [0, 0, 0, 0, 3, 0, 0, 0, -1, 0, 0, 7];

    cstd::setenv("WFDBANNSORT", b"0", true);
    let aiw = [
        Anninfo {
            name: b"mit".to_vec(),
            stat: WFDB_WRITE,
        },
        Anninfo {
            name: b"aha".to_vec(),
            stat: WFDB_AHA_WRITE,
        },
    ];
    assert_eq!(w.annopen("x", &aiw, 2), 0);
    for i in 0..12 {
        let a = Annotation {
            time: times[i],
            anntyp: codes[i] as i8,
            subtyp: subs[i] as i8,
            chan: chans[i] as u8,
            num: nums[i] as i8,
            aux: match i {
                0 => aux(b"start"),
                6 => aux(b"(AFIB"),
                8 => aux(&[b'x'; 200]),
                11 => aux(b"ab"),
                _ => None,
            },
        };
        let s1 = w.putann(1, &a);
        let s0 = w.putann(0, &a);
        out += &format!("put {s0} {s1}\n");
    }
    w.wfdbquit();

    fn pr(w: &mut Wfdb, n: u32, out: &mut String) {
        let mut a = Annotation::default();
        let s = loop {
            let s = w.getann(n, &mut a);
            if s != 0 {
                break s;
            }
            *out += &format!("{} {} {} {} {}", a.time, a.anntyp, a.subtyp, a.chan, a.num);
            if let Some(x) = &a.aux {
                *out += &format!(" aux[{}]={}", x[0], hex(&x[1..=x[0] as usize]));
            }
            *out += "\n";
        };
        *out += &format!("end {s}\n");
    }

    let air = [
        Anninfo {
            name: b"mit".to_vec(),
            stat: WFDB_READ,
        },
        Anninfo {
            name: b"aha".to_vec(),
            stat: WFDB_AHA_READ,
        },
    ];
    out += &format!("open {}\n", w.annopen("x", &air, 2));
    pr(&mut w, 0, &mut out);
    pr(&mut w, 1, &mut out);
    let mut a = Annotation::default();
    out += &format!("settime {}\n", w.iannsettime(300));
    w.getann(0, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    w.getann(1, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    out += &format!("settime {}\n", w.iannsettime(-70000));
    w.getann(0, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    out += &format!("settime {}\n", w.iannsettime(6000000000));
    out += &format!("settime {}\n", w.iannsettime(0));
    w.getann(0, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    w.wfdbquit();

    // read with the wrong stat
    let mut air2 = air.clone();
    air2[0].stat = WFDB_AHA_READ;
    air2[1].stat = WFDB_READ;
    out += &format!("open {}\n", w.annopen("x", &air2, 2));
    w.getann(0, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    w.getann(1, &mut a);
    out += &format!("{} {}\n", a.time, a.anntyp);
    w.wfdbquit();
    let mut bad = ai("bad name", WFDB_WRITE);
    out += &format!("open {}\n", w.annopen("x", &bad, 1));
    bad[0].stat = 9;
    out += &format!("open {}\n", w.annopen("x", &bad, 1));
    out += &String::from_utf8(w.wfdberror()).unwrap();
    let p = w.putann(0, &a);
    let g = w.getann(0, &mut a);
    out += &format!("getann {g} putann {p}\n");

    let expect = "put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\n\
        put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nopen 0\n5 1 0 0 0\n5 1 0 1 0\n\
        5 1 0 1 2\n300 5 3 0 0\n70000 16 0 3 -1\n70001 28 0 0 0 aux[5]=2841464942\n\
        5000000000 1 0 0 0\n5000000000 14 -1 2 1 aux[200]=XXX\n4000000000 1 0 200 0\n\
        10 0 0 0 3\n3000000000 32 7 5 -128 aux[2]=6162\nend -1\n5 1 0 1 0\n5 1 0 1 0\n\
        5 1 0 1 0\n300 5 3 5 0\n70000 22 0 16 0\n70001 22 0 28 0 aux[6]=284146494200\n\
        705032704 1 0 1 0\n705032704 14 -1 14 0 aux[6]=787878787878\n\
        -294967296 1 0 1 0\n10 22 0 0 0\n-1294967296 32 7 32 0 aux[6]=616200000000\n\
        end -1\nsettime 0\n300 5\n300 5\nsettime 0\n70000 16\nsettime -1\nsettime 0\n\
        0 22\nopen 0\n5 1\n5 1\nopen -4\nopen -5\n\
        annopen: illegal stat 9 for annotator bad name, record x\ngetann -2 putann -2\n"
        .replace("XXX", &"78".repeat(200));
    assert_eq!(out, expect);

    let mit = std::fs::read("x.mit").unwrap();
    let expect_mit = format!(
        "005805fc7374617274000504000401f8000402f0271503f400f800f000ec01004410004003f8\
         fff3017000f800f005fc28414649420000ecff7fffff00ecff7fffff00ec042a91e000040038\
         fff702f801f0c8fc{}00ec65c400360004c8f800f000ec0080010000ec949108d8010000f803\
         f000ecff7fffff00ecd032f75d008007f405f880f302fc61620000",
        "78".repeat(200)
    );
    assert_eq!(hex(&mit), expect_mit);
    let aha = std::fs::read("x.aha").unwrap();
    assert_eq!(aha.len(), 1024);
    let expect_aha = "004f0000000001000016737461727400004e000005000200000100000000000000\
        4e0000050003000001000000000000004e0000050004000001000000000000005600002c010500\
        0305000000000000004f0100701106000010000000000000004f010071110700001c2841464942\
        00004e052a00f2080000010000000000000055052a00f20900ff0e787878787878004e6bee0028\
        0a000001000000000000004f00000a000b000000000000000000005bd0b2005e0c000720616200\
        000000";
    let n = expect_aha.len() / 2;
    assert_eq!(hex(&aha[..n]), expect_aha);
    assert!(aha[n..].iter().all(|&c| c == 0xff));
    cstd::setenv("WFDBANNSORT", b"1", true);
}

#[test]
fn input_annotators() {
    let d = DataDir::new("input");
    let mut w = d.wfdb();
    assert_eq!(w.getafreq(), 0.0);
    assert_eq!(w.sampfreq("100s"), 360.0);
    let ais = [
        Anninfo {
            name: b"atr".to_vec(),
            stat: WFDB_READ,
        },
        Anninfo {
            name: b"ooo".to_vec(),
            stat: WFDB_READ,
        },
    ];
    assert_eq!(w.annopen("100s", &ais, 2), 0);
    assert_eq!(w.getiafreq(0), 360.0);
    assert_eq!(w.getiafreq(1), 360.0);
    assert_eq!(w.getiafreq(2), -2.0);
    assert_eq!(w.getiaorigfreq(0), 0.0);
    assert_eq!(w.getiaorigfreq(1), 360.0);
    assert_eq!(w.getiaorigfreq(2), -2.0);
    assert_eq!(ann(&mut w, 0), [0, 18, 28, 0, 0, 0]);
    assert_eq!(ann(&mut w, 0), [0, 77, 1, 0, 0, 0]);
    w.setiafreq(0, 1000.0);
    assert_eq!(w.getiafreq(0), 1000.0);
    assert_eq!(w.getiaorigfreq(0), 0.0);
    let mut a = Annotation::default();
    assert_eq!(w.getann(0, &mut a), 0);
    assert!(a.time == 1028 && a.anntyp == 1);
    w.wfdbquiet();
    assert_eq!(w.ungetann(0, &a), 0);
    assert_eq!(w.ungetann(0, &a), -1); // the pushback buffer is full
    assert_eq!(w.ungetann(5, &a), -2);
    w.wfdbverbose();
    assert_eq!(ann(&mut w, 0), [0, 1028, 1, 0, 0, 0]);
    assert_eq!(ann(&mut w, 0), [0, 1839, 1, 0, 0, 0]);
    a.time = 5;
    a.anntyp = PVC as i8;
    assert_eq!(w.ungetann(0, &a), 0);
    assert_eq!(ann(&mut w, 0), [0, 5, 5, 0, 0, 0]);
    w.setiafreq(0, 0.0);
    assert_eq!(w.getiafreq(0), 360.0);
    assert_eq!(ann(&mut w, 0), [0, 946, 1, 0, 0, 0]);
    w.iannclose(0); // annotator 1 (ooo) becomes annotator 0
    assert_eq!(w.getiafreq(0), 360.0);
    assert_eq!(w.getiafreq(1), -2.0);
    assert_eq!(ann(&mut w, 0), [0, 18, 1, 0, 0, 0]);
    w.wfdbquiet();
    assert_eq!(ann(&mut w, 1)[0], -2);
    w.iannclose(0);
    assert_eq!(ann(&mut w, 0)[0], -2);
    w.iannclose(3);
    w.wfdbverbose();
}

#[test]
fn annotation_time_resolution() {
    let d = DataDir::new("tres");
    let mut w = d.wfdb();
    w.setafreq(1000.0);
    assert_eq!(w.getafreq(), 1000.0);
    let mut a1 = ai("hf", WFDB_WRITE);
    w.annopen("100s", &a1, 1);
    let mut a = Annotation {
        anntyp: NORMAL as i8,
        time: 1000,
        ..Default::default()
    };
    w.putann(0, &a);
    a.time = 2500;
    w.putann(0, &a);
    w.wfdbquit();
    assert_eq!(w.getafreq(), 1000.0);
    w.setafreq(0.0);
    a1[0].stat = WFDB_READ;
    w.annopen("100s", &a1, 1);
    assert_eq!(w.getiafreq(0), 1000.0);
    assert_eq!(w.getiaorigfreq(0), 1000.0);
    assert_eq!(ann(&mut w, 0), [0, 1000, 1, 0, 0, 0]);
    w.setiafreq(0, 360.0);
    assert_eq!(w.getiafreq(0), 360.0);
    assert_eq!(ann(&mut w, 0), [0, 900, 1, 0, 0, 0]);
    w.wfdbquit();
}

#[test]
fn output_annotations_flush() {
    let d = DataDir::new("flush");
    let mut w = d.wfdb();
    assert_eq!(w.annopen("out", &ai("tst", WFDB_WRITE), 1), 0);
    let mut a = Annotation {
        time: 3,
        anntyp: NORMAL as i8,
        ..Default::default()
    };
    w.putann(0, &a);
    a.time = 4;
    a.anntyp = PVC as i8;
    w.putann(0, &a);
    w.wfdbflush();
    assert_eq!(std::fs::metadata("out.tst").unwrap().len(), 4);
    w.wfdbquit();
    assert_eq!(std::fs::read("out.tst").unwrap(), unhex("0304 0114 0000"));
}

#[test]
fn ecgstr_functions() {
    let mut w = Wfdb::new();
    assert_eq!(w.ecgstr(1), b"N");
    assert_eq!(w.ecgstr(0), b" ");
    assert_eq!(w.ecgstr(15), b"[15]");
    assert_eq!(w.ecgstr(22), b"\"");
    assert_eq!(w.ecgstr(50), b"[50]");
    assert_eq!(w.ecgstr(-1), b"[-1]");
    assert_eq!(w.strecg("V"), 5);
    assert_eq!(w.strecg("xx"), 0);
    assert_eq!(w.strecg(""), 0);
    assert_eq!(w.strecg("[15]"), 15);
    assert_eq!(w.setecgstr(5, "PVC"), 0);
    assert_eq!(w.ecgstr(5), b"PVC");
    assert_eq!(w.annstr(5), b"V");
    assert_eq!(w.strecg("PVC"), 5);
    assert_eq!(w.strecg("V"), 0);
    w.wfdbquiet();
    assert_eq!(w.setecgstr(50, "x"), -1);
    assert_eq!(w.setecgstr(-1, "x"), -1);
    w.wfdbverbose();
    assert_eq!(w.setecgstr(0, "Z"), 0);
    assert_eq!(w.ecgstr(0), b"Z");
}

#[test]
fn annstr_anndesc() {
    let d = DataDir::new("annstr");
    let mut w = d.wfdb();
    assert_eq!(w.setannstr(5, "pvc"), 0);
    assert_eq!(w.annstr(5), b"pvc");
    assert_eq!(w.ecgstr(5), b"V");
    assert_eq!(w.strann("pvc"), 5);
    assert_eq!(w.strann("V"), 0);
    assert_eq!(w.setannstr(-6, "fus"), 0);
    assert_eq!(w.annstr(6), b"fus");
    w.wfdbquiet();
    assert_eq!(w.setannstr(60, "x"), -1);
    assert_eq!(w.setannstr(-60, "x"), -1);
    w.wfdbverbose();
    assert_eq!(w.setannstr(0, "zero"), 0);
    assert_eq!(w.annstr(0), b"zero");
    assert_eq!(w.annstr(60), b"[60]");
    assert_eq!(w.setannstr(42, "new"), 0);
    assert_eq!(w.strann("new"), 42);
    assert_eq!(w.anndesc(1).unwrap(), b"Normal beat");
    assert_eq!(w.anndesc(15), None);
    assert_eq!(w.anndesc(60).unwrap(), b"illegal annotation code");
    assert_eq!(w.anndesc(-1).unwrap(), b"illegal annotation code");
    assert_eq!(w.setanndesc(15, "my description"), 0);
    assert_eq!(w.anndesc(15).unwrap(), b"my description");
    assert_eq!(w.setanndesc(-43, "negative"), 0);
    assert_eq!(w.anndesc(43).unwrap(), b"negative");
    w.wfdbquiet();
    assert_eq!(w.setanndesc(50, "x"), -1);
    w.wfdbverbose();

    // Modified mnemonics (but not those set with a negative code) are
    // written into output annotation files ...
    let mut a1 = ai("mod", WFDB_WRITE);
    w.annopen("100s", &a1, 1);
    let a = Annotation {
        time: 10,
        anntyp: PVC as i8,
        ..Default::default()
    };
    w.putann(0, &a);
    w.wfdbquit();
    let mut expect = unhex("0058 1efc");
    expect.extend_from_slice(b"## annotation type definitions");
    expect.extend(unhex("0058 27fc"));
    expect.extend_from_slice(b"5 pvc Premature ventricular contraction");
    expect.extend(unhex("00 0058 16fc"));
    expect.extend_from_slice(b"15 [15] my description");
    expect.extend(unhex("0058 07fc"));
    expect.extend_from_slice(b"42 new ");
    expect.extend(unhex("00 0058 15fc"));
    expect.extend_from_slice(b"## end of definitions");
    expect.extend(unhex("00 00ec ffff ffff 0100 0a14 0000"));
    assert_eq!(std::fs::read("100s.mod").unwrap(), expect);
    w.setannstr(5, "V");
    w.setannstr(-6, "F");
    w.setannstr(0, " ");
    w.setannstr(-42, "[42]");
    w.setanndesc(-15, "");
    w.setanndesc(-43, "");
    // ... and reading the file defines them again.
    a1[0].stat = WFDB_READ;
    w.annopen("100s", &a1, 1);
    assert_eq!(ann(&mut w, 0), [0, 10, 5, 0, 0, 0]);
    assert_eq!(w.annstr(5), b"pvc");
    assert_eq!(w.anndesc(15).unwrap(), b"my description");
    assert_eq!(w.anndesc(42).unwrap(), b"");
    w.wfdbquit();
}

#[test]
fn mnemonics() {
    assert_eq!(annstr(NORMAL), b"N");
    assert_eq!(strann("V"), PVC);
    assert_eq!(anndesc(PVC).unwrap(), b"Premature ventricular contraction");
    assert_eq!(ecgstr(99), b"[99]");
    assert!(isqrs(NORMAL) != 0 && isqrs(NOTE) == 0);
    assert!(map1(APC) == NORMAL && map2(APC) == SVPB);
}

/// isann, isqrs, map1, map2, annpos, mamap(code, 0) and mamap(code, -1) of
/// the codes -1 to 50 (from the C library).
#[rustfmt::skip]
const MAPS: [[i32; 8]; 52] = [
    [-1, 0, 0, 0, 0, 0, 79, 79],
    [0, 0, 0, 0, 0, 0, 79, 79],
    [1, 1, 1, 1, 1, 1, 78, 78],
    [2, 1, 1, 1, 1, 1, 78, 78],
    [3, 1, 1, 1, 1, 1, 78, 78],
    [4, 1, 1, 1, 9, 1, 78, 78],
    [5, 1, 1, 5, 5, 1, 86, 86],
    [6, 1, 1, 6, 6, 1, 70, 70],
    [7, 1, 1, 1, 9, 1, 78, 78],
    [8, 1, 1, 1, 9, 1, 78, 78],
    [9, 1, 1, 1, 9, 1, 78, 78],
    [10, 1, 1, 5, 5, 1, 69, 69],
    [11, 1, 1, 1, 1, 1, 78, 78],
    [12, 1, 1, 1, 1, 1, 80, 80],
    [13, 1, 1, 1, 1, 1, 81, 81],
    [14, 1, 0, 0, 0, 2, 79, 85],
    [15, 1, 0, 0, 0, 0, 79, 79],
    [16, 1, 0, 0, 0, 2, 79, 79],
    [17, 1, 0, 0, 0, 0, 79, 79],
    [18, 1, 0, 0, 0, 2, 79, 79],
    [19, 1, 0, 0, 0, 2, 79, 79],
    [20, 1, 0, 0, 0, 2, 79, 79],
    [21, 1, 0, 0, 0, 2, 79, 79],
    [22, 1, 0, 0, 0, 2, 79, 79],
    [23, 1, 0, 0, 0, 2, 79, 79],
    [24, 1, 0, 0, 0, 2, 79, 79],
    [25, 1, 1, 1, 1, 1, 78, 78],
    [26, 1, 0, 0, 0, 2, 79, 79],
    [27, 1, 0, 0, 0, 2, 79, 79],
    [28, 1, 0, 0, 0, 3, 79, 79],
    [29, 1, 0, 0, 0, 2, 79, 79],
    [30, 1, 1, 30, 30, 1, 81, 81],
    [31, 1, 1, 5, 5, 1, 79, 79],
    [32, 1, 0, 0, 0, 1, 91, 91],
    [33, 1, 0, 0, 0, 1, 93, 93],
    [34, 1, 1, 1, 1, 1, 78, 78],
    [35, 1, 1, 1, 1, 1, 78, 78],
    [36, 1, 0, 0, 0, 2, 79, 79],
    [37, 1, 0, 0, 0, 2, 79, 79],
    [38, 1, 1, 1, 1, 1, 78, 78],
    [39, 1, 0, 0, 0, 2, 79, 79],
    [40, 1, 0, 0, 0, 2, 79, 79],
    [41, 1, 1, 5, 5, 1, 82, 82],
    [42, 1, 0, 0, 0, 0, 79, 79],
    [43, 1, 0, 0, 0, 0, 79, 79],
    [44, 1, 0, 0, 0, 0, 79, 79],
    [45, 1, 0, 0, 0, 0, 79, 79],
    [46, 1, 0, 0, 0, 0, 79, 79],
    [47, 1, 0, 0, 0, 0, 79, 79],
    [48, 1, 0, 0, 0, 0, 79, 79],
    [49, 1, 0, 0, 0, 0, 79, 79],
    [50, 0, 0, 0, 0, 0, 79, 79],
];

#[test]
fn code_maps() {
    let w = Wfdb::new();
    for r in MAPS.iter() {
        let c = r[0];
        // the free functions (default instance), with and without the
        // wfdb_ prefix, and the methods of an instance
        let got = [
            c,
            isann(c),
            isqrs(c),
            map1(c),
            map2(c),
            annpos(c),
            mamap(c, 0),
            mamap(c, -1),
        ];
        assert_eq!(&got, r, "code {}", c);
        let got = [
            c,
            wfdb_isann(c),
            wfdb_isqrs(c),
            wfdb_map1(c),
            wfdb_map2(c),
            wfdb_annpos(c),
            wfdb_mamap(c, 0),
            wfdb_mamap(c, -1),
        ];
        assert_eq!(&got, r, "code {}", c);
        let got = [
            c,
            wfdb_isann(c),
            w.wfdb_isqrs(c),
            w.wfdb_map1(c),
            w.wfdb_map2(c),
            w.wfdb_annpos(c),
            wfdb_mamap(c, 0),
            wfdb_mamap(c, -1),
        ];
        assert_eq!(&got, r, "code {}", c);
    }
}

/// Restores the default instance's maps changed by `code_map_setters`.
struct RestoreMaps;

impl Drop for RestoreMaps {
    fn drop(&mut self) {
        wfdb_setisqrs(1, 1);
        wfdb_setisqrs(2, 1);
        wfdb_setmap1(14, NOTQRS);
        wfdb_setmap2(14, NOTQRS);
        wfdb_setannpos(14, 2);
    }
}

#[test]
fn code_map_setters() {
    // on the default instance (the free functions)
    {
        let _restore = RestoreMaps;
        assert_eq!(wfdb_setisqrs(1, 0), 0);
        assert_eq!(isqrs(1), 0);
        assert_eq!(wfdb_setisqrs(60, 1), 0);
        assert_eq!(wfdb_setisqrs(2, 300), 44); // (stored in a char)
        assert_eq!(isqrs(2), 44);
        assert_eq!(wfdb_setmap1(14, PVC), 5);
        assert_eq!(map1(14), 5);
        assert_eq!(wfdb_setmap1(0, PVC), 0);
        assert_eq!(wfdb_setmap2(14, SVPB), 9);
        assert_eq!(map2(14), 9);
        assert_eq!(wfdb_setmap2(-3, PVC), 0);
        assert_eq!(wfdb_setannpos(14, 6), 6);
        assert_eq!(annpos(14), 6);
        assert_eq!(wfdb_setannpos(50, 2), 0);
        // the aliases without the wfdb_ prefix
        assert_eq!(setisqrs(1, 1), 1);
        assert_eq!(setmap1(14, NORMAL), 1);
        assert_eq!(setmap2(14, NORMAL), 1);
        assert_eq!(setannpos(14, 300), 44);
        assert_eq!(annpos(14), 44);
    }
    assert_eq!(
        [isqrs(1), isqrs(2), map1(14), map2(14), annpos(14)],
        [1, 1, 0, 0, 2]
    );
    // on an instance (which does not affect the default instance)
    let mut w = Wfdb::new();
    assert_eq!(w.wfdb_setisqrs(2, 300), 44);
    assert_eq!(w.wfdb_isqrs(2), 44);
    assert_eq!(w.wfdb_setmap1(14, PVC), 5);
    assert_eq!(w.wfdb_setmap1(0, PVC), 0);
    assert_eq!(w.wfdb_setmap2(14, SVPB), 9);
    assert_eq!(w.wfdb_setmap2(-3, PVC), 0);
    assert_eq!(w.wfdb_setannpos(14, 6), 6);
    assert_eq!(w.wfdb_annpos(14), 6);
    assert_eq!(w.wfdb_setannpos(50, 2), 0);
    assert_eq!([w.wfdb_map1(14), w.wfdb_map2(14)], [5, 9]);
    assert_eq!([isqrs(2), map1(14), map2(14), annpos(14)], [1, 0, 0, 2]);
}

#[derive(Debug, PartialEq)]
struct Cal {
    stat: i32,
    low: f64,
    high: f64,
    scale: f64,
    caltype: i32,
    sigtype: String,
    units: String,
}

fn cal(w: &mut Wfdb, desc: Option<&str>, units: Option<&str>) -> Cal {
    let mut c = Calinfo::default();
    let stat = w.getcal(desc, units, &mut c);
    let s = |x: &Option<Vec<u8>>| match x {
        Some(v) => String::from_utf8(v.clone()).unwrap(),
        None => "(null)".to_string(),
    };
    if stat != 0 {
        return Cal {
            stat,
            low: 0.0,
            high: 0.0,
            scale: 0.0,
            caltype: 0,
            sigtype: String::new(),
            units: String::new(),
        };
    }
    Cal {
        stat,
        low: c.low,
        high: c.high,
        scale: c.scale,
        caltype: c.caltype,
        sigtype: s(&c.sigtype),
        units: s(&c.units),
    }
}

fn c(low: f64, high: f64, scale: f64, caltype: i32, sigtype: &str, units: &str) -> Cal {
    Cal {
        stat: 0,
        low,
        high,
        scale,
        caltype,
        sigtype: sigtype.to_string(),
        units: units.to_string(),
    }
}

fn calinfo(low: f64, high: f64, scale: f64, sigtype: &str, units: &str, caltype: i32) -> Calinfo {
    Calinfo {
        low,
        high,
        scale,
        sigtype: Some(sigtype.as_bytes().to_vec()),
        units: Some(units.as_bytes().to_vec()),
        caltype,
    }
}

#[test]
fn calibration() {
    let d = DataDir::new("cal");
    let mut w = d.wfdb();
    assert_eq!(w.calopen("wfdbcal"), 0);
    assert_eq!(
        cal(&mut w, Some("ECG lead II"), Some("mV")),
        c(0.0, 1.0, 1.0, 4, "ECG", "mV")
    );
    assert_eq!(
        cal(&mut w, Some("ECG"), Some("uV")),
        c(0.0, 1.0, 1000.0, 4, "ECG", "uV")
    );
    assert_eq!(
        cal(&mut w, Some("ABP"), Some("mmHg")),
        c(0.0, 0.0, 100.0, 3, "ABP", "mmHg")
    );
    assert_eq!(
        cal(&mut w, Some("BP"), None),
        c(0.0, 100.0, 100.0, 3, "BP", "mmHg")
    );
    assert_eq!(cal(&mut w, None, None), c(0.0, 1.0, 1.0, 4, "ECG", "mV"));
    assert_eq!(cal(&mut w, Some("nosuch"), Some("x")).stat, -1);
    let test = calinfo(
        -1.5,
        2.5,
        3.0,
        "TEST",
        "xu",
        WFDB_DC_COUPLED | WFDB_CAL_SINE,
    );
    let ac = calinfo(0.0, 0.0, 7.0, "AC", "yu", WFDB_AC_COUPLED | WFDB_CAL_UNDEF);
    assert_eq!(w.putcal(&test), 0);
    assert_eq!(w.putcal(&ac), 0);
    assert_eq!(
        cal(&mut w, Some("TEST signal"), Some("xu")),
        c(-1.5, 2.5, 3.0, 5, "TEST", "xu")
    );
    w.flushcal();
    assert_eq!(cal(&mut w, Some("ECG"), Some("mV")).stat, -1);
    w.putcal(&test);
    w.putcal(&ac);
    w.putcal(&calinfo(
        1.0,
        2.0,
        0.25,
        "SQ",
        "zu",
        WFDB_DC_COUPLED | WFDB_CAL_SQUARE,
    ));
    w.putcal(&calinfo(
        1.0,
        2.0,
        0.25,
        "SAW",
        "zu",
        WFDB_AC_COUPLED | WFDB_CAL_SAWTOOTH,
    ));
    w.wfdbquiet();
    assert_eq!(w.newcal("my.cal"), -1); // illegal name
    w.wfdbverbose();
    assert_eq!(w.newcal("mycal"), 0);
    assert_eq!(
        std::fs::read("mycal").unwrap(),
        b"TEST\t-1.5 2.5 sine 3 xu\r\n\
          AC\t- - undefined 7 yu\r\n\
          SQ\t1 2 square 0.25 zu\r\n\
          SAW\t- 2 sawtooth 0.25 zu\r\n"
    );
    assert_eq!(w.calopen("mycal"), 0);
    assert_eq!(
        cal(&mut w, Some("AC"), Some("yu")),
        c(0.0, 0.0, 7.0, 0, "AC", "yu")
    );
    assert_eq!(cal(&mut w, Some("ECG"), Some("mV")).stat, -1);
    assert_eq!(w.calopen("+wfdbcal"), 0);
    assert_eq!(
        cal(&mut w, Some("ECG"), Some("mV")),
        c(0.0, 1.0, 1.0, 4, "ECG", "mV")
    );
    assert_eq!(
        cal(&mut w, Some("SAW"), None),
        c(0.0, 2.0, 0.25, 6, "SAW", "zu")
    );
    w.wfdbquiet();
    assert_eq!(w.calopen("nosuch.cal"), -2);
    w.wfdbverbose();
    w.flushcal();
}

// ---------------------------------------------------------------------------
// wfdb-x: in-process sorting of out-of-order output annotation files

/// Writes `rec.srt` with annotations out of order: ties in time with
/// different num and chan, duplicates (time, num, chan), a NOTQRS
/// annotation, aux strings, a negative time, a modified mnemonic and a time
/// resolution. The input annotator `atr` of `100s` is open at the same time
/// (as input annotator 0), and is read on after the output file is closed.
/// Returns the times read from `atr`.
fn write_tricky(w: &mut Wfdb, rec: &str) -> Vec<i64> {
    w.setafreq(1000.5);
    w.setannstr(42, "new");
    assert_eq!(w.annopen("100s", &ai("atr", WFDB_READ), 1), 0);
    let mut times = Vec::new();
    let mut a = Annotation::default();
    for _ in 0..10 {
        assert_eq!(w.getann(0, &mut a), 0);
        times.push(a.time);
    }
    let rec = format!("+{rec}");
    assert_eq!(w.annopen(&rec[..], &ai("srt", WFDB_WRITE), 1), 0);
    // (time, anntyp, num, chan, aux)
    type Ann = (i64, i32, i8, u8, Option<&'static [u8]>);
    let anns: &[Ann] = &[
        (10, NORMAL, 0, 0, None),
        (5, PVC, 0, 0, Some(b"first")),
        (5, NORMAL, 1, 0, None),
        (5, APC, 0, 2, Some(b"odd")),
        (5, PVC, 0, 0, Some(b"second")), // replaces (5, 0, 0)
        (3, NOTQRS, 0, 0, None),         // dropped by the sort
        (-4, NORMAL, 0, 0, None),        // negative: dropped
        (20, NORMAL, 0, 1, Some(b"hello world")),
        (15, 42, 0, 0, None),
        (5, NORMAL, 1, 0, Some(b"dup")), // replaces (5, 1, 0)
        (7, NOTE, -3, 0, Some(b"note")),
        (2, NORMAL, 0, 0, None),
        (12, NORMAL, 0, 0, None),
        (12, NORMAL, 0, 0, None),
        (1, PVC, 2, 1, None),
    ];
    for &(time, anntyp, num, chan, x) in anns {
        let a = Annotation {
            time,
            anntyp: anntyp as i8,
            num,
            chan,
            aux: x.and_then(aux),
            ..Default::default()
        };
        assert_eq!(w.putann(0, &a), 0);
    }
    w.oannclose(0);
    while w.getann(0, &mut a) == 0 {
        times.push(a.time);
    }
    w.wfdbquit();
    w.setafreq(0.0);
    times
}

/// Writes two annotations out of order to `rec.srt`, closes the file (with
/// annopen) and returns the status of closing.
fn write_two(w: &mut Wfdb, rec: &str) -> i32 {
    assert_eq!(w.annopen(rec, &ai("srt", WFDB_WRITE), 1), 0);
    for t in [5, 3] {
        let a = Annotation {
            time: t,
            anntyp: NORMAL as i8,
            ..Default::default()
        };
        w.putann(0, &a);
    }
    w.wfdbflush();
    w.annopen(NULL, &[], 0)
}

#[test]
fn sort_in_process() {
    let d = DataDir::new("sort");
    let sortann = PathBuf::from(env!("CARGO_BIN_EXE_sortann"));
    let path = std::env::var_os("PATH");
    let mut w = d.wfdb();
    w.wfdbquiet();

    // The atr times of 100s, as read without an output annotator.
    let mut expected = Vec::new();
    assert_eq!(w.annopen("100s", &ai("atr", WFDB_READ), 1), 0);
    let mut a = Annotation::default();
    while w.getann(0, &mut a) == 0 {
        expected.push(a.time);
    }
    w.wfdbquit();

    // WFDBANNSORT=0: the file is left as written.
    std::env::set_var("WFDBANNSORT", "0");
    assert_eq!(write_two(&mut w, "two"), -6);
    assert_eq!(
        std::fs::read("two.srt").unwrap(),
        unhex("0504 00ec ffff feff 0004 0000")
    );
    assert_eq!(write_tricky(&mut w, "unsorted"), expected);
    assert_eq!(
        w.wfdberror(),
        b"to rearrange annotations in the correct order.\n"
    );
    std::env::remove_var("WFDBANNSORT");

    // The result of the sortann program on that file.
    std::fs::copy("unsorted.srt", "child.srt").unwrap();
    let st = std::process::Command::new(&sortann)
        .args(["-r.", "child", "-a", "srt"])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(st.success());
    let child = std::fs::read("child.srt").unwrap();
    assert_ne!(child, std::fs::read("unsorted.srt").unwrap());

    // Modern mode: sorted in this process, with no sortann program to be
    // found (PATH empty), and without disturbing the open input annotator.
    std::env::set_var("PATH", "");
    let mut w2 = d.wfdb(); // (w has a modified mnemonic)
    w2.wfdbquiet();
    assert_eq!(write_two(&mut w2, "two"), -6); // as in C, also when sorted
    assert_eq!(w2.wfdberror(), b"done!\n");
    assert_eq!(std::fs::read("two.srt").unwrap(), unhex("0304 0204 0000"));
    assert_eq!(write_tricky(&mut w, "modern"), expected);
    assert_eq!(w.wfdberror(), b"done!\n");
    assert_eq!(std::fs::read("modern.srt").unwrap(), child);

    // Legacy mode: the sortann program is run (here not found: the file
    // still needs to be sorted), then found in the PATH.
    w.wfdbx_set_legacy(1);
    write_tricky(&mut w, "legacy");
    assert_eq!(
        w.wfdberror(),
        b"to rearrange annotations in the correct order.\n"
    );
    assert_eq!(
        std::fs::read("legacy.srt").unwrap(),
        std::fs::read("unsorted.srt").unwrap()
    );
    std::env::set_var("PATH", sortann.parent().unwrap());
    assert_eq!(write_tricky(&mut w, "legacy"), expected);
    assert_eq!(w.wfdberror(), b"done!\n");
    assert_eq!(std::fs::read("legacy.srt").unwrap(), child);
    w.wfdbx_set_legacy(0);
    if let Some(p) = path {
        std::env::set_var("PATH", p);
    }

    // The sorted file: in order, without the NOTQRS and negative-time
    // annotations, with the replacements, the time resolution and the
    // definition of code 42 (read with a fresh library state).
    let mut w = d.wfdb();
    assert_eq!(w.annopen("modern", &ai("srt", WFDB_READ), 1), 0);
    assert_eq!(w.getiaorigfreq(0), 1000.5);
    let mut got = Vec::new();
    while w.getann(0, &mut a) == 0 {
        let x = a
            .aux
            .as_ref()
            .map(|x| String::from_utf8_lossy(cstd::cstr(&x[1..])).into_owned());
        got.push((a.time, a.anntyp as i32, a.num, a.chan, x));
    }
    w.wfdbquit();
    let s = |v: &str| Some(v.to_string());
    assert_eq!(
        got,
        vec![
            (1, PVC, 2, 1, None),
            (2, NORMAL, 0, 0, None),
            (5, PVC, 0, 0, s("second")),
            (5, APC, 0, 2, s("odd")),
            (5, NORMAL, 1, 0, s("dup")),
            (7, NOTE, -3, 0, s("note")),
            (10, NORMAL, 0, 0, None),
            (12, NORMAL, 0, 0, None),
            (15, 42, 0, 0, None),
            (20, NORMAL, 0, 1, s("hello world")),
        ]
    );
    assert_eq!(w.annstr(42), b"new");
}

/// A sort that fails (here: the file cannot be read back, its directory
/// having been removed) leaves the annotations to be rearranged.
#[cfg(unix)]
#[test]
fn sort_errors() {
    let d = DataDir::new("sorterr");
    let mut w = d.wfdb();
    w.wfdbquiet();
    assert_eq!(w.annopen("gone/rec", &ai("srt", WFDB_WRITE), 1), 0);
    for t in [5, 3] {
        let a = Annotation {
            time: t,
            anntyp: NORMAL as i8,
            ..Default::default()
        };
        w.putann(0, &a);
    }
    w.wfdbflush();
    std::fs::remove_dir_all("gone").unwrap();
    assert_eq!(w.annopen(NULL, &[], 0), -6);
    assert_eq!(
        w.wfdberror(),
        b"to rearrange annotations in the correct order.\n"
    );
}

/// wfdb-x: the list no longer loses an out-of-order annotation at time 0
/// (num and chan 0) and those inserted after it; the original insertion
/// (legacy) does.
#[test]
fn annlist_time0() {
    let list = |legacy: bool, anns: &[(i64, u8)]| {
        let mut l = AnnList::with_legacy(legacy);
        for &(time, chan) in anns {
            l.insert(&Annotation {
                time,
                chan,
                anntyp: NORMAL as i8,
                ..Default::default()
            });
        }
        assert!(!l.in_order());
        l.iter().map(|a| (a.time, a.chan)).collect::<Vec<_>>()
    };
    let x = [(5, 0), (0, 0), (3, 0)];
    assert_eq!(list(false, &x), [(0, 0), (3, 0), (5, 0)]);
    assert_eq!(list(true, &x), [(5, 0)]);
    // several channels; a later (0, 0, 0) replaces a real (0, 0, 0) entry
    let x = [(5, 0), (0, 1), (0, 0), (2, 0), (0, 0), (0, 2)];
    assert_eq!(list(false, &x), [(0, 0), (0, 1), (0, 2), (2, 0), (5, 0)]);
    // (original: the (0, 0) entries replace the head; (0, 1) and what
    // follows it remain reachable)
    assert_eq!(list(true, &x), [(0, 1), (0, 2), (2, 0), (5, 0)]);
    // (0, 0, chan > 0) was never lost
    let x = [(5, 0), (0, 1), (3, 0)];
    assert_eq!(list(false, &x), list(true, &x));
    assert_eq!(AnnList::default().iter().count(), 0);
}

/// wfdb-x: the library sort keeps time-0 annotations, with the result of
/// the sortann tool; in legacy mode, the sortann program run with --legacy
/// loses them, as the original did.
#[test]
fn sort_time0() {
    let d = DataDir::new("sort0");
    let sortann = PathBuf::from(env!("CARGO_BIN_EXE_sortann"));
    let path = std::env::var_os("PATH");
    std::env::set_var("PATH", sortann.parent().unwrap());
    let write = |w: &mut Wfdb, rec: &str| {
        assert_eq!(w.annopen(rec, &ai("srt", WFDB_WRITE), 1), 0);
        for (t, x) in [(5, None), (0, Some(&b"+ (N"[..])), (3, None)] {
            let a = Annotation {
                time: t,
                anntyp: NORMAL as i8,
                aux: x.and_then(aux),
                ..Default::default()
            };
            w.putann(0, &a);
        }
        w.wfdbquit();
    };
    let times = |w: &mut Wfdb, rec: &str| {
        assert_eq!(w.annopen(rec, &ai("srt", WFDB_READ), 1), 0);
        let mut v = Vec::new();
        let mut a = Annotation::default();
        while w.getann(0, &mut a) == 0 {
            v.push(a.time);
        }
        w.wfdbquit();
        v
    };
    let mut w = d.wfdb();
    w.wfdbquiet();
    write(&mut w, "modern");
    assert_eq!(times(&mut w, "modern"), [0, 3, 5]);
    std::env::set_var("WFDBANNSORT", "0");
    write(&mut w, "child");
    std::env::remove_var("WFDBANNSORT");
    let st = std::process::Command::new(&sortann)
        .args(["-r.", "child", "-a", "srt"])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(st.success());
    assert_eq!(
        std::fs::read("modern.srt").unwrap(),
        std::fs::read("child.srt").unwrap()
    );
    w.wfdbx_set_legacy(1);
    write(&mut w, "legacy");
    assert_eq!(w.wfdberror(), b"done!\n");
    w.wfdbx_set_legacy(0);
    assert_eq!(times(&mut w, "legacy"), [5]);
    if let Some(p) = path {
        std::env::set_var("PATH", p);
    }
}
