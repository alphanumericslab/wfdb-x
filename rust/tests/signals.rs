//! Tests of the signal functions (signal.rs) and of the high-level API
//! (record.rs): the Rust counterparts of the signal parts of
//! cpp/tests/test_api.cpp and cpp/tests/test_api_c.cpp (expected values
//! produced by the C library), python/tests/test_signals.py and
//! python/tests/test_time.py.
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

use std::path::PathBuf;
use std::sync::Mutex;

use wfdbx::record::{ReadOptions, WriteOptions};
use wfdbx::*;

/// The tests change the current directory: they run one at a time.
static LOCK: Mutex<()> = Mutex::new(());

/// A fresh copy of tests/data as the current directory, and a library
/// instance whose WFDB path is ".".
struct DataDir {
    old: PathBuf,
    dir: PathBuf,
    w: Wfdb,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl DataDir {
    fn new() -> DataDir {
        let guard = LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let data = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests/data");
        let dir = std::env::temp_dir().join(format!("wfdbx-rs-test-{}-{}", std::process::id(), n));
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
        let mut w = Wfdb::new();
        w.setwfdb(".");
        DataDir {
            old,
            dir,
            w,
            _guard: guard,
        }
    }
}

impl Drop for DataDir {
    fn drop(&mut self) {
        self.w.wfdbquit();
        let _ = std::env::set_current_dir(&self.old);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn slurp(name: &str) -> Vec<u8> {
    std::fs::read(name).unwrap()
}

fn unhex(h: &str) -> Vec<u8> {
    let d: Vec<u8> = h.bytes().filter(|&c| c != b' ').collect();
    d.chunks(2)
        .map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap(), 16).unwrap())
        .collect()
}

/// Open all signals of a record (as isigopen(record, NULL, 8) in C).
fn isig(w: &mut Wfdb, record: &str) -> i32 {
    w.isigopen(record, &mut [], 8)
}

/// getvec: the status followed by n samples.
fn vec(w: &mut Wfdb, n: usize) -> Vec<i32> {
    let mut v = vec![0; n + 8];
    let stat = w.getvec(&mut v);
    let mut r = vec![stat];
    r.extend_from_slice(&v[..n]);
    r
}

/// getframe: the status followed by n samples.
fn frame(w: &mut Wfdb, n: usize) -> Vec<i32> {
    let mut v = vec![0; n + 8];
    let stat = w.getframe(&mut v);
    let mut r = vec![stat];
    r.extend_from_slice(&v[..n]);
    r
}

fn segs(w: &mut Wfdb) -> Vec<String> {
    let mut s = None;
    let n = w.getseginfo(&mut s);
    let s = s.unwrap_or_default();
    (0..n.max(0) as usize)
        .map(|i| {
            format!(
                "{} {} {}",
                String::from_utf8_lossy(&s[i].recname),
                s[i].nsamp,
                s[i].samp0
            )
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Time and date conversion

#[test]
fn interval_strings() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    assert_eq!(w.isigopen("100s", &mut [], 0), 2);
    assert_eq!(w.strtim("1:0"), 21600);
    assert_eq!(w.timstr(21600), b"    1:00");
    assert_eq!(w.mstimstr(1234), b"    0:03.428");
    assert_eq!(w.strtim("s7"), 7);
    assert_eq!(w.strtim("e"), 21600);
}

#[test]
fn absolute_times() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.isigopen("fmt16", &mut [], 0);
    assert_eq!(w.timstr(0), b"[12:34:56 31/12/1999]");
    assert_eq!(w.strtim("[12:35:00]"), -803);
    assert_eq!(w.mstimstr(-2500), b"[12:35:06.789 31/12/1999]");
}

#[test]
fn dates() {
    let mut w = Wfdb::new();
    for s in ["01/01/2000", "29/02/2000", "15/10/1582", "31/12/1999"] {
        let d = w.strdat(s);
        assert_eq!(w.datstr(d), format!(" {s}").into_bytes());
    }
    let d = w.strdat("29/02/1900");
    assert_eq!(w.datstr(d), b" 01/03/1900");
    assert_eq!(w.strdat("bogus"), 0);
}

#[test]
fn counter_and_base_time() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "100s");
    assert_eq!(w.getcfreq(), 360.0);
    assert_eq!(w.getbasecount(), 0.0);
    w.setcfreq(1000.0);
    w.setbasecount(500.5);
    assert_eq!(w.getcfreq(), 1000.0);
    assert_eq!(w.getbasecount(), 500.5);
    assert_eq!(w.strtim("c1500.5"), 360);
    assert_eq!(w.strtim("c500.5"), 0);
    w.setcfreq(0.0);
    assert_eq!(w.getcfreq(), 360.0);
    assert_eq!(w.setbasetime("10:20:30 15/6/2001"), 0);
    assert_eq!(w.timstr(0), b"[10:20:30 15/06/2001]");
    assert_eq!(w.timstr(360), b"    0:01");
    assert_eq!(w.timstr(-360), b"[10:20:31 15/06/2001]");
    assert_eq!(w.mstimstr(-1000), b"[10:20:32.778 15/06/2001]");
    assert_eq!(w.setbasetime("8:00"), 0);
    assert_eq!(w.timstr(0), b"[00:08:00]");
    assert_eq!(w.timstr(-720), b"[00:08:02]");
    w.wfdbquiet();
    assert_eq!(w.setbasetime("garbage"), -1);
    w.wfdbverbose();
    w.setcfreq(500.0);
    w.wfdbquit();
    assert_eq!(w.getcfreq(), 500.0);
}

// ---------------------------------------------------------------------------
// The C-style API (expected values from the C library)

#[test]
fn errors() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    assert_eq!(isig(w, "nosuch"), -1);
    assert_eq!(
        w.wfdberror(),
        b"init: can't open header for record nosuch\n"
    );
}

#[test]
fn buffer_sizes() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    assert_eq!(w.setibsize(0), 8192);
    assert_eq!(w.setibsize(1000), 1000);
    assert_eq!(w.setibsize(-1), -2);
    assert_eq!(w.setobsize(0), 8192);
    assert_eq!(w.setobsize(2000), 2000);
    assert_eq!(w.setobsize(-5), -2);
    isig(w, "100s");
    assert_eq!(w.setibsize(512), -1);
}

#[test]
fn getvec_modes_and_frequencies() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    assert_eq!(w.getgvmode(), 0);
    assert_eq!(isig(w, "100s"), 2);
    assert_eq!(w.getifreq(), 360.0);
    assert_eq!(w.getspf(), 1);
    w.wfdbquit();
    isig(w, "fmt16");
    assert_eq!(vec(w, 3), [3, -7, 32, -33]);
    assert_eq!(vec(w, 3), [3, 4, 53, -47]);
    assert_eq!(vec(w, 3), [3, -20, 24, -27]);
    assert_eq!(w.setifreq(100.0), 0);
    assert_eq!(w.getifreq(), 100.0);
    assert_eq!(w.isigsettime(0), 0);
    assert_eq!(vec(w, 3), [3, -7, 32, -33]);
    assert_eq!(vec(w, 3), [3, -21, 23, -35]);
    assert_eq!(vec(w, 3), [3, 7, -14, -44]);
    assert_eq!(w.setifreq(1000.0), 0);
    assert_eq!(w.getifreq(), 1000.0);
    assert_eq!(w.isigsettime(2), 0);
    assert_eq!(vec(w, 3), [3, -7, 32, -33]);
    for _ in 0..4 {
        assert_eq!(vec(w, 3), [3, 4, 53, -47]);
    }
    w.wfdbquiet();
    assert_eq!(w.setifreq(-1.0), -1);
    w.wfdbverbose();
    assert_eq!(w.getifreq(), 250.0);
    w.wfdbquit();
    isig(w, "100s");
    w.setgvmode(WFDB_HIGHRES);
    assert_eq!(w.getgvmode(), 1);
    w.setgvmode(WFDB_GVPAD | WFDB_LOWRES);
    assert_eq!(w.getgvmode(), 2);
    w.setgvmode(WFDB_HIGHRES | WFDB_GVPAD | 4);
    assert_eq!(w.getgvmode(), 3);
    w.setgvmode(0);
}

#[test]
#[allow(clippy::excessive_precision)] // (the values printed by C)
fn amplitude_conversion() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    isig(w, "100s"); // gain 200, baseline 1024
    assert_eq!(w.adumuv(0, 200), 1000);
    assert_eq!(w.adumuv(0, -37), -185);
    assert_eq!(w.adumuv(1, 1), 5);
    assert_eq!(w.adumuv(0, -1), -5);
    assert_eq!(w.adumuv(7, 100), WFDB_INVALID_SAMPLE); // wfdb-x: invalid signal
    assert_eq!(w.muvadu(0, 1000), 200);
    assert_eq!(w.muvadu(0, -333), -67);
    assert_eq!(w.muvadu(1, 2), 0);
    assert_eq!(w.muvadu(9, 1000), WFDB_INVALID_SAMPLE);
    assert_eq!(w.aduphys(0, 1224), 1.0);
    assert_eq!(w.aduphys(1, 900), -0.62);
    assert!(w.aduphys(5, 300).is_nan());
    assert_eq!(w.physadu(0, 1.0), 1224);
    assert_eq!(w.physadu(1, -0.5023), 924);
    assert_eq!(w.physadu(5, 1.5), WFDB_INVALID_SAMPLE);
    w.wfdbquit();
    isig(w, "fmt16"); // 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
    assert_eq!(w.adumuv(0, 100), 1000);
    assert_eq!(w.adumuv(1, 150), 1000);
    assert_eq!(w.adumuv(2, -7), -35);
    assert_eq!(w.muvadu(0, 1000), 100);
    assert_eq!(w.muvadu(1, 1000), 150);
    assert_eq!(w.muvadu(2, -2500), -500);
    assert_eq!(w.aduphys(0, 95), 1.0);
    assert_eq!(w.aduphys(1, 10), 0.033333333333333333);
    assert_eq!(w.aduphys(2, -3), -0.089999999999999997);
    assert_eq!(w.physadu(0, 1.0), 95);
    assert_eq!(w.physadu(1, -2.25), -333);
    assert_eq!(w.physadu(2, 0.4), 95);
    w.wfdbverbose();
}

#[test]
fn sample_random_access() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "100s");
    assert_eq!(w.sample_valid(), 0);
    assert_eq!(w.sample(0, 0), 995);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(1, 1000), 970);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(0, 21599), 975);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(0, 21600), 975);
    assert_eq!(w.sample_valid(), 0);
    assert_eq!(w.sample(0, 5), 995);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(1, -3), 1011);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(2, 0), -32768);
    assert_eq!(w.sample_valid(), -1);
}

#[test]
fn getframe_multifrequency() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "mfreq"); // 1, 2 and 4 samples per frame
    assert_eq!(w.getspf(), 1);
    assert_eq!(w.getifreq(), 100.0);
    assert_eq!(frame(w, 7), [3, 138, 218, 2699, 219, -1316, 1120, 1973]);
    assert_eq!(frame(w, 7), [3, 2677, 1201, 275, -989, 1822, 2762, 1927]);
    assert_eq!(vec(w, 3), [3, -597, -455, 181]);
    w.isigsettime(599);
    assert_eq!(frame(w, 7), [3, -1394, 715, 558, 2215, -1785, 860, -491]);
    assert_eq!(frame(w, 7)[0], -1);
    w.wfdbquit();
    w.setgvmode(WFDB_HIGHRES);
    isig(w, "mfreq");
    assert_eq!(w.getspf(), 4);
    assert_eq!(w.getifreq(), 400.0);
    assert_eq!(frame(w, 7), [3, 138, 218, 2699, 219, -1316, 1120, 1973]);
    assert_eq!(vec(w, 3), [3, 2677, 1201, -989]);
    assert_eq!(vec(w, 3), [3, 2677, 1201, 1822]);
    w.wfdbquit();
    w.setgvmode(0);
}

#[test]
fn isgsettime_groups() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "twog"); // group 0: signal 0; group 1: signals 1 and 2
    assert_eq!(vec(w, 3), [3, 1020, 977, 316]);
    assert_eq!(w.isgsettime(1, 100), 0);
    assert_eq!(vec(w, 3), [3, 1880, -630, 83]);
    assert_eq!(vec(w, 3), [3, 325, 245, 1597]);
    assert_eq!(w.isgsettime(0, 500), 0);
    assert_eq!(vec(w, 3), [3, -1823, 338, -709]);
    assert_eq!(w.isgsettime(1, 1001), 0);
    assert_eq!(vec(w, 3)[0], -1);
}

#[test]
fn tnextvec_getseginfo() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "100s");
    assert!(segs(w).is_empty());
    assert_eq!(w.tnextvec(0, 5), 5);
    assert_eq!(w.tnextvec(1, 0), 0);
    w.wfdbquit();
    isig(w, "multi");
    assert_eq!(
        segs(w),
        ["100s 21600 0", "null 1800 21600", "100s 21600 23400"]
    );
    assert_eq!(w.tnextvec(0, 0), 0);
    assert_eq!(w.tnextvec(0, 21599), 21599);
    assert_eq!(w.tnextvec(1, 21700), 23500);
    assert_eq!(w.tnextvec(0, 44999), 44999);
    assert_eq!(w.tnextvec(0, 45000), -1);
    w.wfdbquit();
    isig(w, "vlay");
    assert_eq!(
        segs(w),
        [
            "vlay_0 0 0",
            "fmt16 1500 0",
            "~ 200 1500",
            "fmt212 1501 1700"
        ]
    );
    w.wfdbquiet();
    assert_eq!(w.tnextvec(0, 0), 0);
    assert_eq!(w.tnextvec(1, 1499), 1700);
    assert_eq!(w.tnextvec(2, 1500), -1);
    assert_eq!(w.tnextvec(0, 1600), -1);
    assert_eq!(w.tnextvec(5, 0), -1);
    w.wfdbverbose();
}

#[test]
fn skew_and_start() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "skew");
    assert_eq!(w.wfdbgetskew(0), 0);
    assert_eq!(w.wfdbgetskew(1), 3);
    assert_eq!(w.wfdbgetskew(2), 7);
    assert_eq!(w.wfdbgetskew(3), 0);
    assert_eq!(vec(w, 3), [3, -7, 21, -32768]);
    w.wfdbsetiskew(1, 2);
    w.wfdbsetiskew(2, 100000); // too large: ignored
    w.wfdbsetiskew(0, -1); // negative: ignored
    assert_eq!(w.wfdbgetskew(0), 0);
    assert_eq!(w.wfdbgetskew(1), 2);
    assert_eq!(w.wfdbgetskew(2), 7);
    w.wfdbquit();
    isig(w, "prolog");
    assert_eq!(w.wfdbgetstart(0), 100);
    assert_eq!(w.wfdbgetstart(2), 100);
    assert_eq!(w.wfdbgetstart(3), 0);
    w.wfdbquit();
    isig(w, "100s");
    assert_eq!(w.wfdbgetstart(0), 0);
}

#[test]
fn getframe_deskew() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "skew");
    assert_eq!(frame(w, 3), [3, -7, 21, -32768]);
    assert_eq!(frame(w, 3), [3, 4, -14, -85]);
    w.isigsettime(1497);
    assert_eq!(frame(w, 3), [-1, -32755, 16705, -32768]);
    assert_eq!(frame(w, 3), [-1, -32751, -14, 16705]);
}

#[test]
fn uncalibrated_signals() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    isig(w, "null"); // gain 0: wfdb-x: no default gain
    assert_eq!(w.adumuv(0, 100), WFDB_INVALID_SAMPLE);
    assert_eq!(w.muvadu(1, 100), WFDB_INVALID_SAMPLE);
    assert!(w.aduphys(0, 100).is_nan());
    assert_eq!(w.physadu(1, 0.5), WFDB_INVALID_SAMPLE);
    assert_eq!(vec(w, 2), [2, -32768, -32768]);
    w.wfdbverbose();
}

#[test]
fn multifrequency_resampling() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    isig(w, "mfreq");
    assert_eq!(w.setifreq(200.0), 0);
    assert_eq!(vec(w, 3), [3, 138, 1459, 499]);
    assert_eq!(vec(w, 3), [3, 2677, 738, 1381]);
    assert_eq!(vec(w, 3), [3, 2677, 738, 1381]);
    w.wfdbquit();
    isig(w, "mfreq");
    assert_eq!(w.sample(2, 10), 869);
    assert_eq!(w.sample_valid(), 1);
    assert_eq!(w.sample(1, 599), 637);
    assert_eq!(w.sample_valid(), 1);
    w.wfdbquit();
    isig(w, "multi");
    assert_eq!(w.isigsettime(100), 0);
    assert_eq!(w.tnextvec(0, 21650), 23450);
    assert_eq!(vec(w, 2), [2, 969, 996]);
}

#[test]
fn output_prolog_skew_flush() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.setcfreq(0.0);
    let mut si = vec![Siginfo::default(); 2];
    for (i, s) in si.iter_mut().enumerate() {
        s.fname = Some(b"out.dat".to_vec());
        s.desc = Some(if i == 1 {
            b"second".to_vec()
        } else {
            b"first".to_vec()
        });
        s.units = Some(b"mV".to_vec());
        s.gain = 100.0;
        s.group = 0;
        s.fmt = 16;
        s.adcres = 12;
    }
    w.setsampfreq(100.0);
    assert_eq!(w.osigfopen(&si, 2), 2);
    assert_eq!(w.wfdbputprolog(b"PROLOG!", 7, 0), 0);
    w.wfdbsetskew(1, 4);
    for i in 0..5 {
        w.putvec(&[i, -i]);
    }
    w.wfdbflush();
    assert_eq!(std::fs::metadata("out.dat").unwrap().len(), 27);
    assert_eq!(w.newheader("out"), 0);
    assert_eq!(w.putinfo("info line"), 0);
    w.wfdbquit();
    assert_eq!(
        slurp("out.hea"),
        b"out 2 100 5\r\nout.dat 16+7 100/mV 12 0 0 10 0 first\r\nout.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n#info line\r\n"
    );
    assert_eq!(
        slurp("out.dat"),
        unhex("50524f4c4f4721 0000 0000 0100 ffff 0200 feff 0300 fdff 0400 fcff")
    );

    w.setsampfreq(100.0);
    si[0].fname = Some(b"out2.dat".to_vec());
    si[1].fname = Some(b"out2.dat".to_vec());
    w.osigfopen(&si, 2);
    w.wfdbsetstart(0, 512);
    w.putvec(&[1, 2]);
    w.newheader("out2");
    w.wfdbquit();
    assert_eq!(
        slurp("out2.hea"),
        b"out2 2 100 1\r\nout2.dat 16+512 100/mV 12 0 1 1 0 first\r\nout2.dat 16+512 100/mV 12 0 2 2 0 second\r\n"
    );
    assert_eq!(std::fs::metadata("out2.dat").unwrap().len(), 4);
}

#[test]
fn info_strings() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let xform = b"Produced by xform from record 100, beginning at 0:0".to_vec();
    assert_eq!(w.getinfo("100s"), Some(b" 69 M 1085 1629 x1".to_vec()));
    assert_eq!(w.getinfo(NULL), Some(b" Aldomet, Inderal".to_vec()));
    assert_eq!(w.getinfo(NULL), Some(xform.clone()));
    assert_eq!(w.setinfo("newrec"), 0);
    assert_eq!(w.putinfo("first"), 0);
    assert_eq!(w.putinfo("second"), 0);
    assert_eq!(w.setinfo(NULL), 0);
    w.wfdbquiet();
    assert_eq!(w.putinfo("third"), -1);
    w.wfdbverbose();
    assert_eq!(slurp("newrec.info"), b"#first\r\n#second\r\n");
    assert_eq!(w.getinfo("newrec"), Some(b"first".to_vec()));
    assert_eq!(w.getinfo(NULL), Some(b"second".to_vec()));
    assert_eq!(w.getinfo(NULL), None);
    assert_eq!(w.setinfo("100s"), 0);
    assert_eq!(w.putinfo("extra"), 0);
    w.wfdbquit();
    assert_eq!(w.getinfo("100s"), Some(b" 69 M 1085 1629 x1".to_vec()));
    assert_eq!(w.getinfo(NULL), Some(b" Aldomet, Inderal".to_vec()));
    assert_eq!(w.getinfo(NULL), Some(xform));
    assert_eq!(w.getinfo(NULL), Some(b"extra".to_vec()));
    isig(w, "fmt16");
    assert_eq!(w.getinfo(NULL), None);
}

#[test]
fn freeinfo() {
    // After wfdb_freeinfo, getinfo(NULL) rereads the info strings of the
    // open input record from the first, or fails if there is none.
    let mut d = DataDir::new();
    let w = &mut d.w;
    let first = Some(b" 69 M 1085 1629 x1".to_vec());
    let second = Some(b" Aldomet, Inderal".to_vec());
    assert_eq!(w.getinfo("100s"), first);
    assert_eq!(w.getinfo(NULL), second);
    w.wfdb_freeinfo();
    w.wfdbquiet();
    assert_eq!(w.getinfo(NULL), None);
    assert_eq!(
        w.wfdberror(),
        b"getinfo: caller did not specify record name\n"
    );
    w.wfdbverbose();
    isig(w, "100s");
    assert_eq!(w.getinfo(NULL), first);
    assert_eq!(w.getinfo(NULL), second);
    w.wfdb_freeinfo();
    assert_eq!(w.getinfo(NULL), first);
    w.wfdb_freeinfo();
    w.wfdb_freeinfo();
    assert_eq!(w.getinfo(NULL), first);
    w.wfdbquit();
    // the same on the default instance
    wfdbx::setwfdb(".");
    assert_eq!(wfdbx::getinfo("100s"), first);
    assert_eq!(wfdbx::getinfo(NULL), second);
    wfdbx::wfdb_freeinfo();
    wfdbx::wfdbquiet();
    assert_eq!(wfdbx::getinfo(NULL), None);
    wfdbx::wfdbverbose();
    wfdbx::isigopen("100s", &mut [], 8);
    assert_eq!(wfdbx::getinfo(NULL), first);
    assert_eq!(wfdbx::getinfo(NULL), second);
    wfdbx::wfdb_freeinfo();
    assert_eq!(wfdbx::getinfo(NULL), first);
    wfdbx::wfdbquit();
}

#[test]
fn setmsheader_segments() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let names = ["100s", "null", "100s"];
    assert_eq!(w.setmsheader("msrec", &names, 3), 0);
    w.wfdbquiet();
    assert_eq!(w.setmsheader("msbad", &names, 0), -1);
    assert_eq!(w.setmsheader("msbad", &["100s", "fmt16"], 2), -4);
    w.wfdbverbose();
    w.wfdbquit();
    assert_eq!(
        slurp("msrec.hea"),
        b"msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n100s 21600\r\n"
    );
    assert_eq!(isig(w, "msrec"), 2);
    assert_eq!(
        segs(w),
        ["100s 21600 0", "null 1800 21600", "100s 21600 23400"]
    );
    w.isigsettime(21599);
    assert_eq!(vec(w, 2), [2, 975, 989]);
    assert_eq!(vec(w, 2), [2, -32768, -32768]);
}

// ---------------------------------------------------------------------------
// Round trips through write_record / read_record, in every storage format
// (including FLAC)

#[test]
fn signal_roundtrip() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let ranges: [(i32, i64); 13] = [
        (8, 1000),
        (16, 32767),
        (61, 32767),
        (80, 127),
        (160, 32767),
        (212, 2047),
        (310, 511),
        (311, 511),
        (24, 8388607),
        (32, 2147483647),
        (508, 127),
        (516, 32767),
        (524, 8388607),
    ];
    for &(fmt, hi) in &ranges {
        for nsig in 1..=3usize {
            let mut rng = cstd::GlibcRand::new((fmt as u32) * 10 + nsig as u32);
            let n = if fmt >= 500 { 5003usize } else { 1001 };
            let mut x = vec![0i32; n * nsig];
            if fmt == 8 {
                for s in 0..nsig {
                    let mut v = 0i32;
                    for i in 0..n {
                        v += rng.rand() % 121 - 60;
                        x[i * nsig + s] = v;
                    }
                }
            } else {
                for v in &mut x {
                    let r = ((rng.rand() as i64) << 31) | rng.rand() as i64;
                    *v = (r % (2 * hi) - hi + 1) as i32;
                }
            }
            // the ADC resolution of the samples (required: wfdb-x)
            let bits = if fmt == 8 {
                16
            } else {
                (hi + 1).ilog2() as i32 + 1
            };
            let opt = WriteOptions {
                fmt,
                gains: vec![200.0],
                adcres: vec![bits],
                units: vec![Some("mV".into())],
                ..Default::default()
            };
            w.write_record("rt", &x, nsig, 250.0, &opt).unwrap();
            let r = w.read_record("rt", &ReadOptions::default()).unwrap();
            let mut y = r.samples.clone();
            if (fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2 {
                // A final group of two samples is written in 4 bytes, so the
                // file appears to contain an extra (zero) sample.
                for s in 0..nsig {
                    assert_eq!(y[y.len() - nsig + s], 0);
                }
                y.truncate(y.len() - nsig);
            }
            assert!(y == x, "format {fmt}, {nsig} signals");
            // random access with the per-sample interface
            w.isigopen("rt", &mut [], nsig as i32);
            for t in [n - 1, 0, n / 2, 3, n - 2] {
                for s in 0..nsig {
                    assert_eq!(w.sample(s as u32, t as i64), x[t * nsig + s]);
                }
            }
            w.wfdbquit();
        }
    }
}

/// getvecs (used by read_record) returns exactly what getvec does.
#[test]
fn getvecs_equals_getvec() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    for rec in [
        "fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s", "skew", "mfreq", "multi", "vlay",
        "fmt212b", "fmt310b", "fmt311b", "fmtblk", "prolog", "fms", "null", "flac16", "flacmf",
    ] {
        let n = w.isigopen(rec, &mut [], 0);
        assert!(n > 0, "{}", rec);
        let mut si = vec![Siginfo::default(); n as usize];
        w.isigopen(rec, &mut si, n);
        let mut v = vec![0; n as usize];
        let mut reference = Vec::new();
        while w.getvec(&mut v) >= 0 {
            reference.extend_from_slice(&v);
        }
        w.wfdbquit();
        let r = w.read_record(rec, &ReadOptions::default()).unwrap();
        assert!(r.samples == reference, "{}", rec);
    }
    w.wfdbverbose();
}

#[test]
fn physical_units() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let o = ReadOptions {
        to: Some(3.into()),
        ..Default::default()
    };
    let r = w.read_record("100s", &o).unwrap();
    assert_eq!(r.nsamples(), 3);
    for i in 0..3 {
        assert!((r.physical(i, 0).unwrap() + 0.145).abs() < 1e-12);
        assert!((r.physical(i, 1).unwrap() + 0.065).abs() < 1e-12);
    }
    assert_eq!(r.names()[0], b"MLII");
}

#[test]
fn multifrequency() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let lo = ReadOptions {
        to: Some(10.into()),
        ..Default::default()
    };
    let hi = ReadOptions {
        to: Some(20.into()),
        highres: true,
        ..Default::default()
    };
    let lo = w.read_record("mfreq", &lo).unwrap();
    let hi = w.read_record("mfreq", &hi).unwrap();
    assert!(lo.nsamples() == 10 && lo.nsig == 3);
    assert!(hi.nsamples() == 20 && hi.nsig == 3);
    assert!(hi.fs == 400.0 && lo.fs == 100.0);
}

#[test]
fn variable_layout() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    let o = ReadOptions {
        from: Some(1498.into()),
        to: Some(1502.into()),
        ..Default::default()
    };
    let r = w.read_record("vlay", &o).unwrap();
    w.wfdbverbose();
    assert_eq!(r.nsamples(), 4);
    for s in 0..r.nsig {
        assert_eq!(r.at(2, s), WFDB_INVALID_SAMPLE);
    }
}

#[test]
fn time_strings_in_options() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let o = ReadOptions {
        from: Some("0:1".into()),
        to: Some("0:2".into()),
        channels: vec!["V5".to_string()],
        ..Default::default()
    };
    let r = w.read_record("100s", &o).unwrap();
    assert!(r.nsig == 1 && r.nsamples() == 360 && r.sampfrom == 360);
    assert_eq!(r.siginfo[0].desc.as_deref(), Some(&b"V5"[..]));
    assert_eq!(r.comments[0], b" 69 M 1085 1629 x1");
}

#[test]
fn header_writing() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let x = vec![0i32; 20];
    let o = WriteOptions {
        gains: vec![100.0, 0.0],
        adcres: vec![16],
        units: vec![Some("mV".into()), Some("uV".into())],
        names: vec!["lead I".into(), "pressure".into()],
        base_time: Some("12:00:00 01/02/2003".into()),
        comments: vec!["c1".into()],
        ..Default::default()
    };
    w.write_record("hw", &x, 2, 125.5, &o).unwrap();
    let text = slurp("hw.hea");
    assert!(text.starts_with(b"hw 2 125.5 10 12:00:00 01/02/2003\r\n"));
    let needle = b"hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n";
    assert!(text.windows(needle.len()).any(|w| w == needle));
    assert!(text.ends_with(b"#c1\r\n"));
    let h = w.read_header("hw", false).unwrap();
    assert_eq!(h.len(), 2);
    assert_eq!(h[1].desc.as_deref(), Some(&b"pressure"[..]));
    assert_eq!(h[1].units.as_deref(), Some(&b"uV"[..]));
}

#[test]
fn physical_writing() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let x = [0.0, 1.0, -0.5, 0.0025, f64::NAN, 2.0];
    let o = WriteOptions {
        gains: vec![200.0],
        adcres: vec![16],
        units: vec![Some("mV".into())],
        ..Default::default()
    };
    w.write_record_physical("ph", &x, 2, 100.0, &o).unwrap();
    let r = w.read_record("ph", &ReadOptions::default()).unwrap();
    assert_eq!(r.samples, [0, 200, -100, 1, WFDB_INVALID_SAMPLE, 400]);
    assert!(r.physical(2, 0).unwrap().is_nan());
}

#[test]
fn errors_are_returned() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    let e = w
        .read_record("nosuch", &ReadOptions::default())
        .unwrap_err();
    assert_eq!(e.to_string(), "can't read record nosuch");
    let o = ReadOptions {
        channels: vec!["XX".to_string()],
        ..Default::default()
    };
    assert!(w.read_record("100s", &o).is_err());
    assert!(w.read_header("nosuch", false).is_err());
    w.wfdbverbose();
}

#[test]
fn default_instance_free_functions() {
    let _d = DataDir::new();
    setwfdb(".");
    assert_eq!(isigopen("100s", &mut [], 0), 2);
    assert_eq!(strtim("e"), 21600);
    let mut v = [0i32; 2];
    assert_eq!(isigopen("100s", &mut [], 2), 2);
    assert_eq!(getvec(&mut v), 2);
    assert_eq!(v, [995, 1011]);
    let r = record::read_record("100s", &ReadOptions::default()).unwrap();
    assert_eq!(r.nsamples(), 21600);
    wfdbquit();
}

/// After a failed seek (past the end of a FLAC stream), libFLAC aborts the
/// decoding of the next block in the C library: getvec fails, and so do
/// later seeks; a seek to the current time is not performed.
#[test]
fn flac_failed_seek() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    assert_eq!(isig(w, "flac16"), 3);
    assert_eq!(w.isigsettime(99999), -1);
    assert_eq!(vec(w, 3), [-3, 0, 0, 0]);
    assert_eq!(w.isigsettime(0), -1);
    assert_eq!(vec(w, 3), [-3, 0, 0, 0]);
    w.wfdbquit();
    isig(w, "flac16");
    assert_eq!(w.isigsettime(99999), -1);
    assert_eq!(w.isigsettime(5), 0);
    assert_eq!(vec(w, 3), [3, -77, -57, -47]);
    w.wfdbquit();
    isig(w, "flac16");
    assert_eq!(vec(w, 3), [3, -31, -38, -33]);
    assert_eq!(w.isigsettime(9001), -1);
    assert_eq!(w.isigsettime(1), 0);
    assert_eq!(vec(w, 3), [-3, 0, 0, 0]);
}

// ---------------------------------------------------------------------------
// wfdb-x: no default sampling frequency, gain, ADC resolution or units
// (t_nodefaults in
// tests/reference/api_expect.c; see docs/DIVERGENCES.md)

/// A header without a sampling frequency (as written by t_nodefaults).
fn write_nf() {
    std::fs::write(
        "nf.hea",
        "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n\
         100s.dat 212 200 11 1024 1011 -3962 0 V5\n",
    )
    .unwrap();
}

#[test]
fn nodefaults_time_needs_freq() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    // (the counter frequency is defined when the C test runs, since it
    // survives wfdbquit after t_counter)
    w.setcfreq(10.0);
    for (s, x) in [
        ("s10", 0),
        ("e", 0),
        ("i", 0),
        ("o", 0),
        ("c10", 1),
        ("f3", 1),
        ("10", 1),
        ("1:0", 1),
        ("[10:00:00]", 1),
        (" s5", 0),
        ("", 1),
    ] {
        assert_eq!(w.wfdbx_time_needs_freq(s), x, "{s:?}");
    }
    // "c" needs a frequency only while the counter frequency is defined
    w.setcfreq(0.0);
    assert_eq!(w.wfdbx_time_needs_freq("c10"), 0);
    assert_eq!(wfdbx_time_needs_freq("1:0"), 1);
}

#[test]
fn nodefaults_library() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    // no input record: no sampling frequency
    assert_eq!(w.strtim("1:0"), 0);
    assert_eq!(
        w.wfdberror(),
        b"strtim: sampling frequency is not specified\n"
    );
    assert_eq!(w.strtim("s10"), 10);
    assert_eq!(w.timstr(360), b"s360");
    assert_eq!(
        w.wfdberror(),
        b"timstr: sampling frequency is not specified\n"
    );
    assert_eq!(w.mstimstr(-360), b"s360");
    assert_eq!(
        w.wfdberror(),
        b"mstimstr: sampling frequency is not specified\n"
    );
    // a header without a sampling frequency
    write_nf();
    assert_eq!(isig(w, "nf"), 2);
    assert_eq!(w.sampfreq(NULL), 0.0);
    assert_eq!(w.getifreq(), 0.0);
    assert_eq!(w.setifreq(100.0), -1);
    assert_eq!(
        w.wfdberror(),
        b"setifreq: sampling frequency is not specified\n"
    );
    assert_eq!(w.strtim("2"), 0);
    assert_eq!(w.strtim("e"), 0);
    assert_eq!(w.mstimstr(100), b"s100");
    w.wfdbquit();
    // a frequency set by the caller applies
    assert_eq!(w.setsampfreq(500.0), 0);
    assert_eq!(isig(w, "nf"), 2);
    assert_eq!(w.sampfreq(NULL), 500.0);
    assert_eq!(w.strtim("2"), 1000);
    assert_eq!(w.mstimstr(100), b"    0:00.200");
    w.wfdbquit();
    assert_eq!(w.sampfreq("nf"), 0.0);
    w.wfdbquit();
    // uncalibrated signals (record null) and invalid signal numbers
    isig(w, "null");
    assert!(w.aduphys(0, 100).is_nan());
    assert_eq!(w.wfdberror(), b"aduphys: signal 0 is uncalibrated\n");
    assert_eq!(w.physadu(0, 1.0), -32768);
    assert_eq!(w.wfdberror(), b"physadu: signal 0 is uncalibrated\n");
    assert_eq!(w.adumuv(1, 100), -32768);
    assert_eq!(w.muvadu(1, 100), -32768);
    assert_eq!(w.wfdberror(), b"muvadu: signal 1 is uncalibrated\n");
    w.wfdbquit();
    isig(w, "100s");
    assert_eq!(w.aduphys(0, 1124), 0.5);
    assert_eq!(w.physadu(1, -0.5), 924);
    assert_eq!(w.adumuv(0, 100), 500);
    assert_eq!(w.muvadu(0, 1000), 200);
    assert!(w.aduphys(5, 100).is_nan());
    assert_eq!(w.wfdberror(), b"aduphys: invalid signal number 5\n");
    assert_eq!(w.physadu(5, 1.0), -32768);
    assert_eq!(w.adumuv(2, 100), -32768);
    assert_eq!(w.muvadu(2, 100), -32768);
    assert_eq!(w.wfdberror(), b"muvadu: invalid signal number 2\n");
    w.wfdbquit();
    // no default ADC resolution (0) or units (None)
    write_nr();
    let mut si = vec![Siginfo::default(); 8];
    assert_eq!(w.isigopen("nr", &mut si, 8), 2);
    assert_eq!((si[0].adcres, si[1].adcres), (0, 0));
    assert_eq!(si[0].units, None);
    w.wfdbquit();
    w.isigopen("100s", &mut si, 8);
    assert_eq!((si[0].adcres, si[1].adcres), (11, 11));
    w.wfdbquit();
    w.wfdbverbose();
}

/// A header without ADC resolutions or units (as written by t_nodefaults).
fn write_nr() {
    std::fs::write(
        "nr.hea",
        "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n",
    )
    .unwrap();
}

#[test]
fn nodefaults_write_record() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    let x = [0i32, 1, 2, 3];
    // gains are required
    let e = w
        .write_record("ng", &x, 2, 100.0, &WriteOptions::default())
        .unwrap_err();
    assert!(e.message().contains("gains must be specified"), "{e}");
    let two = WriteOptions {
        gains: vec![100.0, 50.0],
        adcres: vec![16],
        units: vec![Some("mV".into())],
        ..Default::default()
    };
    let e = w.write_record("ng", &[0; 6], 3, 100.0, &two).unwrap_err();
    assert!(e.message().contains("gains must be specified"), "{e}");
    // the sampling frequency must be > 0
    let g = WriteOptions {
        gains: vec![200.0],
        ..Default::default()
    };
    for fs in [0.0, -1.0, f64::NAN] {
        let e = w.write_record("ng", &x, 2, fs, &g).unwrap_err();
        assert!(e.message().contains("sampling frequency"), "{e}");
        let e = w
            .write_record_physical("ng", &[0.0; 4], 2, fs, &g)
            .unwrap_err();
        assert!(e.message().contains("sampling frequency"), "{e}");
    }
    // ADC resolutions are required (>= 1), one or one per signal
    for r in [vec![], vec![0], vec![16, -1], vec![16, 12, 8]] {
        let o = WriteOptions {
            gains: vec![200.0],
            adcres: r.clone(),
            units: vec![Some("mV".into())],
            ..Default::default()
        };
        let res = w.write_record("nr", &[0; 6], 3, 100.0, &o);
        if r.len() == 3 {
            res.unwrap();
        } else {
            let e = res.unwrap_err();
            assert_eq!(
                e.message(),
                "write_record: ADC resolution(s) must be specified"
            );
        }
    }
    // units are required for calibrated signals only
    for (gains, units, ok) in [
        (vec![200.0], vec![], false),
        (vec![200.0], vec![Some("mV".into()), None], false),
        (
            vec![200.0],
            vec![Some("mV".into()), Some(Vec::new())],
            false,
        ),
        (vec![200.0, 0.0], vec![Some("mV".into())], true),
        (vec![200.0, 0.0], vec![Some("mV".into()), None], true),
        (vec![0.0], vec![], true),
    ] {
        let o = WriteOptions {
            gains,
            adcres: vec![16],
            units,
            ..Default::default()
        };
        let res = w.write_record("nu", &x, 2, 100.0, &o);
        if ok {
            res.unwrap();
        } else {
            let e = res.unwrap_err();
            assert_eq!(e.message(), "write_record: units must be specified");
        }
    }
    let h = w.read_header("nu", false).unwrap();
    assert_eq!((h[0].units.as_deref(), h[0].adcres), (None, 16));
    // gain 0: uncalibrated, allowed for ADC units only
    let u = WriteOptions {
        gains: vec![200.0, 0.0],
        adcres: vec![16],
        units: vec![Some("mV".into())],
        ..Default::default()
    };
    w.write_record("unc", &x, 2, 100.0, &u).unwrap();
    let h = w.read_header("unc", false).unwrap();
    assert_eq!((h[0].gain, h[1].gain), (200.0, 0.0));
    let e = w
        .write_record_physical("unc", &[0.0; 4], 2, 100.0, &u)
        .unwrap_err();
    assert_eq!(e.message(), "write_record: signal 1 is uncalibrated");
    // ... and reading it in physical units fails for that signal only
    let r = w.read_record("unc", &ReadOptions::default()).unwrap();
    assert_eq!(r.physical(1, 0).unwrap(), 2.0 / 200.0);
    let e = r.physical_signal(1).unwrap_err();
    assert_eq!(e.message(), "signal 1 of record unc is uncalibrated");
    let o = ReadOptions {
        channels: vec!["1".into()],
        ..Default::default()
    };
    let r = w.read_record("unc", &o).unwrap();
    assert_eq!(r.signals, [1]);
    let e = r.physical(0, 0).unwrap_err();
    assert_eq!(e.message(), "signal 1 of record unc is uncalibrated");
}

#[test]
fn nodefaults_read_record() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    write_nf();
    w.wfdbquiet();
    let r = w.read_record("nf", &ReadOptions::default()).unwrap();
    assert_eq!(r.fs, 0.0);
    assert_eq!(r.nsamples(), 21600);
    assert_eq!(r.base_time, None);
    // sample numbers and time strings that need no frequency
    let o = ReadOptions {
        from: Some("s10".into()),
        to: Some(20.into()),
        ..Default::default()
    };
    let r = w.read_record("nf", &o).unwrap();
    assert_eq!((r.sampfrom, r.nsamples()), (10, 10));
    for (from, to) in [(Some("0:1"), None), (None, Some("1"))] {
        let o = ReadOptions {
            from: from.map(Into::into),
            to: to.map(Into::into),
            ..Default::default()
        };
        let e = w.read_record("nf", &o).unwrap_err();
        assert_eq!(
            e.message(),
            "sampling frequency of record nf is not specified"
        );
    }
    // no ADC resolution (0) or units (None) in the header
    write_nr();
    let o = ReadOptions {
        to: Some("s10".into()),
        ..Default::default()
    };
    let r = w.read_record("nr", &o).unwrap();
    for s in &r.siginfo {
        assert_eq!((s.adcres, s.units.as_deref()), (0, None));
    }
    let h = w.read_header("nr", false).unwrap();
    assert_eq!((h[1].adcres, h[1].units.as_deref()), (0, None));
    // uncalibrated signals (record null)
    let r = w.read_record("null", &ReadOptions::default()).unwrap();
    let e = r.physical(0, 1).unwrap_err();
    assert_eq!(e.message(), "signal 1 of record null is uncalibrated");
    w.wfdbverbose();
}

#[test]
fn nodefaults_read_annotations() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    // a record without a header
    std::fs::copy("100s.atr", "nohea.atr").unwrap();
    let a = w
        .read_annotations("nohea", "atr", None, None, None, false)
        .unwrap();
    let b = w
        .read_annotations("100s", "atr", None, None, None, false)
        .unwrap();
    assert_eq!(a.samples, b.samples);
    assert_eq!(a.fs, 0.0);
    assert_eq!(b.fs, 360.0);
    let e = w
        .read_annotations("nohea", "atr", None, Some("0:10".into()), None, false)
        .unwrap_err();
    assert_eq!(
        e.message(),
        "sampling frequency of record nohea is not specified"
    );
    let a = w
        .read_annotations("nohea", "atr", None, Some("s3600".into()), None, false)
        .unwrap();
    let n = b.samples.iter().filter(|&&t| t < 3600).count();
    assert_eq!(a.len(), n);
    // with a sampling frequency given by the caller
    let a = w
        .read_annotations(
            "nohea",
            "atr",
            None,
            Some("0:10".into()),
            Some(360.0),
            false,
        )
        .unwrap();
    assert_eq!(a.fs, 360.0);
    assert_eq!(a.len(), n);
    // an explicit frequency must be > 0
    for f in [0.0, -1.0, f64::NAN] {
        let e = w
            .read_annotations("nohea", "atr", None, None, Some(f), false)
            .unwrap_err();
        assert_eq!(e.message(), "fs must be > 0");
    }
    // the header's frequency has precedence
    let c = w
        .read_annotations("100s", "atr", None, Some("0:10".into()), Some(100.0), false)
        .unwrap();
    assert_eq!(c.fs, 360.0);
    assert_eq!(c.len(), n);
    w.wfdbverbose();
}

// ---------------------------------------------------------------------------
// wfdb-x: legacy mode, the behavior of the original package (t_legacy in
// tests/reference/api_expect.c; see docs/DIVERGENCES.md)

fn approx(x: f64, y: f64) -> bool {
    (x - y).abs() < 1e-12
}

#[test]
fn legacy_library() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    assert_eq!(w.wfdbx_get_legacy(), 0); // off by default
    assert_eq!(w.wfdbx_set_legacy(1), 0);
    assert_eq!(w.wfdbx_get_legacy(), 1);
    // amplitude conversion (gain 200, baseline 1024; invalid signal numbers:
    // gain 200, baseline 0)
    isig(w, "100s");
    assert_eq!(
        [
            w.adumuv(0, 200),
            w.adumuv(0, -37),
            w.adumuv(1, 1),
            w.adumuv(0, -1),
            w.adumuv(7, 100)
        ],
        [1000, -185, 5, -5, 500]
    );
    assert_eq!(
        [
            w.muvadu(0, 1000),
            w.muvadu(0, -333),
            w.muvadu(1, 2),
            w.muvadu(9, 1000)
        ],
        [200, -67, 0, 200]
    );
    assert!(approx(w.aduphys(0, 1224), 1.0));
    assert!(approx(w.aduphys(1, 900), -0.62));
    assert!(approx(w.aduphys(5, 300), 1.5));
    assert_eq!(
        [w.physadu(0, 1.0), w.physadu(1, -0.5023), w.physadu(5, 1.5)],
        [1224, 924, 300]
    );
    assert!(approx(w.aduphys(5, 100), 0.5));
    assert_eq!(w.physadu(5, 1.0), 200);
    assert_eq!(w.adumuv(2, 100), 500);
    assert_eq!(w.muvadu(2, 100), 20);
    w.wfdbquit();
    // uncalibrated signals (record null): gain 200
    isig(w, "null");
    assert_eq!((w.adumuv(0, 100), w.muvadu(1, 100)), (500, 20));
    assert!(approx(w.aduphys(0, 100), 0.5));
    assert_eq!(w.physadu(1, 0.5), 100);
    assert_eq!(w.physadu(0, 1.0), 200);
    w.wfdbquit();
    w.wfdbquiet();
    // no input record: 1 sample per second
    assert_eq!(w.strtim("1:0"), 60);
    assert_eq!(w.strtim("s10"), 10);
    assert_eq!(w.timstr(360), b"    6:00");
    assert_eq!(w.mstimstr(-360), b"    6:00.000");
    // a header without a sampling frequency: 250 Hz
    write_nf();
    assert_eq!(isig(w, "nf"), 2);
    assert_eq!(w.sampfreq(NULL), 250.0);
    assert_eq!(w.getifreq(), 250.0);
    assert_eq!(w.strtim("2"), 500);
    assert_eq!(w.strtim("e"), 0);
    assert_eq!(w.mstimstr(100), b"    0:00.400");
    assert_eq!(w.setifreq(100.0), 0);
    assert_eq!(w.getifreq(), 100.0);
    w.wfdbquit();
    assert_eq!(w.sampfreq("nf"), 250.0);
    w.wfdbquit();
    // setifreq with an input record but no frequency
    isig(w, "100s");
    w.setsampfreq(0.0);
    assert_eq!(w.setifreq(100.0), -1);
    assert_eq!(w.wfdberror(), b"setifreq: no open input record\n");
    w.wfdbquit();
    // ADC resolution inferred from the format, or WFDB_DEFRES
    write_nr();
    let mut si = vec![Siginfo::default(); 8];
    assert_eq!(w.isigopen("nr", &mut si, 8), 2);
    assert_eq!((si[0].adcres, si[1].adcres), (12, 12));
    w.wfdbquit();
    std::fs::write(
        "nr3.hea",
        "nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\nfmt310.dat 310\n\
         fmt160.dat 160\nfmt24.dat 24\n",
    )
    .unwrap();
    assert_eq!(w.isigopen("nr3", &mut si, 8), 5);
    let r: Vec<i32> = si[..5].iter().map(|s| s.adcres).collect();
    assert_eq!(r, [12, 8, 10, 16, 12]);
    w.wfdbquit();
    w.wfdbverbose();
    assert_eq!(w.wfdbx_set_legacy(0), 1);
    assert_eq!(w.wfdbx_get_legacy(), 0);
}

#[test]
fn legacy_args() {
    let mut w = Wfdb::new();
    let args = |v: &[&str]| -> Vec<Vec<u8>> { v.iter().map(|s| s.as_bytes().to_vec()).collect() };
    // only the first argument is recognized
    for v in [
        &["rdsamp"][..],
        &["rdsamp", "-r", "100s"],
        &["rdsamp", "-r", "--legacy"],
        &["rdsamp", "--legacyx"],
    ] {
        let mut a = args(v);
        assert_eq!(w.wfdbx_legacy_args(&mut a), 0);
        assert_eq!(a, args(v));
        assert_eq!(w.wfdbx_get_legacy(), 0);
    }
    let mut a = args(&["rdsamp", "--legacy", "-r", "100s", "--legacy"]);
    assert_eq!(w.wfdbx_legacy_args(&mut a), 1);
    assert_eq!(a, args(&["rdsamp", "-r", "100s", "--legacy"]));
    assert_eq!(w.wfdbx_get_legacy(), 1);
    // per instance: the default instance is not affected
    assert_eq!(wfdbx_get_legacy(), 0);
}

#[test]
fn legacy_high_level() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    let x = [0i32, 1, 2, 3];
    // write_record: gain 200, ADC resolution from the format, no units
    let lo = WriteOptions {
        fmt: 212,
        legacy: true,
        ..Default::default()
    };
    assert!(w
        .write_record("lg", &x, 2, 100.0, &WriteOptions::default())
        .is_err());
    w.write_record("lg", &x, 2, 100.0, &lo).unwrap();
    assert_eq!(w.wfdbx_get_legacy(), 0); // restored
    let h = w.read_header("lg", false).unwrap();
    for s in &h {
        assert_eq!((s.gain, s.adcres, s.units.as_deref()), (200.0, 12, None));
    }
    // write_record_physical: gain 200 for uncalibrated signals
    let po = WriteOptions {
        gains: vec![0.0],
        legacy: true,
        ..Default::default()
    };
    w.write_record_physical("lp", &[0.5, -1.0], 2, 100.0, &po)
        .unwrap();
    let r = w.read_record("lp", &ReadOptions::default()).unwrap();
    assert_eq!(r.samples, [100, -200]);
    // read_record: physical units of uncalibrated signals with gain 200
    let uo = WriteOptions {
        gains: vec![0.0],
        adcres: vec![16],
        ..Default::default()
    };
    w.write_record("uc", &x, 2, 100.0, &uo).unwrap();
    let r = w.read_record("uc", &ReadOptions::default()).unwrap();
    assert!(r.physical(1, 0).is_err());
    let lr = ReadOptions {
        legacy: true,
        ..Default::default()
    };
    let r = w.read_record("uc", &lr).unwrap();
    assert!(r.legacy);
    assert_eq!(r.physical(1, 0).unwrap(), 2.0 / 200.0);
    assert_eq!(r.physical_signal(1).unwrap(), [0.005, 0.015]);
    // read_record: a header without a frequency is read at 250 Hz
    write_nf();
    let o = ReadOptions {
        to: Some("0:1".into()),
        legacy: true,
        ..Default::default()
    };
    let r = w.read_record("nf", &o).unwrap();
    assert_eq!((r.fs, r.nsamples()), (250.0, 250));
    assert_eq!(w.wfdbx_get_legacy(), 0);
    // read_header: ADC resolution from the format
    write_nr();
    let h = w.read_header("nr", true).unwrap();
    assert_eq!((h[0].adcres, h[1].adcres), (12, 12));
    assert_eq!(w.read_header("nr", false).unwrap()[0].adcres, 0);
    // read_annotations: a record without a header is read at 250 Hz, unless
    // fs is given
    std::fs::copy("100s.atr", "nohea.atr").unwrap();
    let a = w
        .read_annotations("nohea", "atr", None, Some("0:10".into()), None, true)
        .unwrap();
    assert_eq!(a.fs, 250.0);
    let all = w
        .read_annotations("nohea", "atr", None, None, None, false)
        .unwrap();
    let n = all.samples.iter().filter(|&&t| t < 2500).count();
    assert_eq!(a.len(), n);
    let a = w
        .read_annotations("nohea", "atr", None, None, Some(360.0), true)
        .unwrap();
    assert_eq!(a.fs, 360.0);
    // the previous setting is restored, also on errors; a global setting is
    // left as it is
    assert!(w.read_record("nosuch", &lr).is_err());
    assert_eq!(w.wfdbx_get_legacy(), 0);
    w.wfdbx_set_legacy(1);
    let r = w.read_record("nf", &ReadOptions::default()).unwrap();
    assert_eq!(r.fs, 250.0);
    assert!(r.legacy);
    assert!(w.read_record("nosuch", &lr).is_err());
    assert_eq!(w.wfdbx_get_legacy(), 1);
    w.wfdbx_set_legacy(0);
    w.wfdbverbose();
}

// ---------------------------------------------------------------------------
// wfdb-x: output directory of the writers, absolute record names

#[test]
fn write_record_dir() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    std::fs::create_dir("od").unwrap();
    let x = [1i32, -2, 3, 4, 5, -6];
    let mut o = WriteOptions {
        gains: vec![200.0],
        adcres: vec![12],
        units: vec![Some("mV".into())],
        fmt: 212,
        dir: Some("od".into()),
        ..Default::default()
    };
    w.wfdbx_set_output_dir("prev");
    w.write_record("rec", &x, 2, 360.0, &o).unwrap();
    assert_eq!(w.wfdbx_get_output_dir(), Some(b"prev".to_vec())); // restored
    assert!(!std::path::Path::new("rec.hea").exists());
    assert!(!std::path::Path::new("prev").exists());
    // the header names the record and its signal file without the directory
    let text = slurp("od/rec.hea");
    assert!(text.starts_with(b"rec 2 360 3\r\nrec.dat 212 200/mV 12 "));
    // the record opens from that directory under its plain name
    w.setwfdb("od");
    let r = w.read_record("rec", &ReadOptions::default()).unwrap();
    assert_eq!(r.samples, x);
    w.setwfdb(".");
    // the same in legacy mode, and with write_record_physical
    o.legacy = true;
    w.write_record("lrec", &x, 2, 360.0, &o).unwrap();
    assert!(slurp("od/lrec.hea").starts_with(b"lrec 2 360 3\r\n"));
    o.legacy = false;
    w.write_record_physical("ph", &[0.5, 1.0], 2, 100.0, &o)
        .unwrap();
    assert!(slurp("od/ph.hea").starts_with(b"ph 2 100 1\r\nph.dat "));
    // errors (before anything is written); the output dir is restored
    let e = w.write_record("od/rec2", &x, 2, 360.0, &o).unwrap_err();
    assert_eq!(
        e.message(),
        "record name must not contain a directory when dir is given"
    );
    o.dir = Some("nosuch".into());
    let e = w.write_record("rec2", &x, 2, 360.0, &o).unwrap_err();
    assert_eq!(e.message(), "directory nosuch does not exist");
    assert!(!std::path::Path::new("nosuch").exists());
    o.dir = Some("od".into());
    o.gains.clear();
    assert!(w.write_record("rec2", &x, 2, 360.0, &o).is_err());
    assert_eq!(w.wfdbx_get_output_dir(), Some(b"prev".to_vec()));
    w.wfdbx_set_output_dir(NULL);
    // without dir: as before (the header records the name as given)
    o.gains = vec![200.0];
    o.dir = None;
    w.write_record("od/rec3", &x, 2, 360.0, &o).unwrap();
    assert!(slurp("od/rec3.hea").starts_with(b"od/rec3 2 360 3\r\nod/rec3.dat "));
}

#[test]
fn write_annotations_dir() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    std::fs::create_dir("od").unwrap();
    let ann = Annotations {
        samples: vec![30, 10, 20, 10],
        symbols: vec!["N".into(), "V".into(), "N".into(), "A".into()],
        ..Default::default()
    };
    // out of order: sorted in place, in the directory
    let dir = std::path::Path::new("od");
    w.write_annotations("rec", "srt", &ann, 0.0, Some(dir))
        .unwrap();
    assert_eq!(w.wfdbx_get_output_dir(), None);
    assert!(!std::path::Path::new("rec.srt").exists());
    w.write_annotations("rec", "srt", &ann, 0.0, None).unwrap();
    assert_eq!(slurp("od/rec.srt"), slurp("rec.srt"));
    w.setwfdb("od");
    let r = w
        .read_annotations("rec", "srt", None, None, Some(100.0), false)
        .unwrap();
    assert_eq!(r.samples, [10, 20, 30]);
    assert_eq!(r.symbols, [b"A".to_vec(), b"N".to_vec(), b"N".to_vec()]);
    w.setwfdb(".");
    // errors
    let e = w
        .write_annotations("od/rec", "srt", &ann, 0.0, Some(dir))
        .unwrap_err();
    assert_eq!(
        e.message(),
        "record name must not contain a directory when dir is given"
    );
    let e = w
        .write_annotations(
            "rec",
            "srt",
            &ann,
            0.0,
            Some(std::path::Path::new("nosuch")),
        )
        .unwrap_err();
    assert_eq!(e.message(), "directory nosuch does not exist");
}

#[test]
fn absolute_record_names() {
    let mut d = DataDir::new();
    let abs = d.dir.join("100s");
    let abs = abs.to_str().unwrap();
    let w = &mut d.w;
    w.wfdbquiet();
    w.setwfdb("/nonexistent-wfdbx-dir");
    let opt = ReadOptions {
        to: Some("10".into()),
        ..Default::default()
    };
    // modern: the header is opened directly, the signal file found next to it
    let r = w.read_record(abs, &opt).unwrap();
    assert_eq!(r.samples.len(), 2 * 3600);
    let a = w
        .read_annotations(abs, "atr", None, None, None, false)
        .unwrap();
    assert_eq!(a.len(), 75);
    // legacy: as in C, only the WFDB path is searched
    let lo = ReadOptions {
        legacy: true,
        ..opt.clone()
    };
    assert!(w.read_record(abs, &lo).is_err());
    w.setwfdb(";");
    assert_eq!(w.read_record(abs, &lo).unwrap().samples, r.samples);
}

/// wfdb-x: in legacy mode, the sortann program is run in the output
/// directory, and sorts the file in place there, with the modern result.
#[test]
fn legacy_sort_in_output_dir() {
    let mut d = DataDir::new();
    let sortann = PathBuf::from(env!("CARGO_BIN_EXE_sortann"));
    let path = std::env::var_os("PATH");
    std::env::set_var("PATH", sortann.parent().unwrap());
    let w = &mut d.w;
    w.wfdbquiet();
    std::fs::create_dir("m").unwrap();
    std::fs::create_dir("l").unwrap();
    let ann = Annotations {
        samples: vec![30, 10, 20, 10, 40, 35],
        symbols: vec![
            "N".into(),
            "V".into(),
            "N".into(),
            "A".into(),
            "N".into(),
            "V".into(),
        ],
        aux: vec![
            None,
            Some(b"x".to_vec()),
            None,
            None,
            Some(b"(VT".to_vec()),
            None,
        ],
        ..Default::default()
    };
    let m = std::path::Path::new("m");
    let l = std::path::Path::new("l");
    w.write_annotations("rec", "srt", &ann, 0.0, Some(m))
        .unwrap();
    w.wfdbx_set_legacy(1);
    w.write_annotations("rec", "srt", &ann, 0.0, Some(l))
        .unwrap();
    assert_eq!(w.wfdberror(), b"done!\n");
    w.wfdbx_set_legacy(0);
    assert!(!std::path::Path::new("rec.srt").exists());
    assert_eq!(slurp("l/rec.srt"), slurp("m/rec.srt"));
    w.setwfdb("l");
    let r = w
        .read_annotations("rec", "srt", None, None, Some(100.0), false)
        .unwrap();
    assert_eq!(r.samples, [10, 20, 30, 35, 40]);
    if let Some(p) = path {
        std::env::set_var("PATH", p);
    }
}

/// wfdb-x: with dir, the dir checks come before any other check.
#[test]
fn dir_checks_first() {
    let mut d = DataDir::new();
    let w = &mut d.w;
    w.wfdbquiet();
    let sub = "record name must not contain a directory when dir is given";
    let missing = "directory nosuch does not exist";
    let bad = WriteOptions {
        dir: Some("nosuch".into()),
        ..Default::default() // no gains, ADC resolutions or units
    };
    for (rec, msg) in [("a/rec", sub), ("rec", missing)] {
        let e = w.write_record(rec, &[0; 3], 2, -1.0, &bad).unwrap_err();
        assert_eq!(e.message(), msg);
        let e = w.write_record(rec, &[], 0, 0.0, &bad).unwrap_err();
        assert_eq!(e.message(), msg);
        let e = w
            .write_record_physical(rec, &[0.0; 3], 2, -1.0, &bad)
            .unwrap_err();
        assert_eq!(e.message(), msg);
        let dir = Some(std::path::Path::new("nosuch"));
        let e = w
            .write_annotations(rec, "bad name", &Annotations::default(), 0.0, dir)
            .unwrap_err();
        assert_eq!(e.message(), msg);
    }
    assert!(!std::path::Path::new("nosuch").exists());
}
