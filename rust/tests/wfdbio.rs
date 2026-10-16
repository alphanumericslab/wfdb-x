//! Tests of `WfdbFile` and the WFDB path functions (`wfdbx::wfdbio`).
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

use wfdbx::cstd::{self, EOF, SEEK_CUR, SEEK_END, SEEK_SET};
use wfdbx::{cfprintf, wfdb_fopen, Wfdb, WfdbFile, NULL, WFDB_APPEND, WFDB_READ, WFDB_WRITE};

fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("wfdbx-test-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// `setwfdb` exports `WFDB` to the (shared) process environment: tests
/// that set or read it hold this lock so that they do not race.
static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn env_lock() -> std::sync::MutexGuard<'static, ()> {
    ENV_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn b(p: &std::path::Path) -> Vec<u8> {
    cstd::os_to_bytes(p.as_os_str().to_os_string())
}

#[test]
fn write_read_seek() {
    let d = tmpdir("wrs");
    let name = b(&d.join("f.dat"));
    let mut f = WfdbFile::fopen(&name, b"wb").unwrap();
    for i in 0..100_000u32 {
        f.p16(i);
    }
    f.p32(-2);
    assert_eq!(f.tell(), 200_004);
    let big = vec![7u8; 100_000];
    assert_eq!(f.write(&big), 100_000);
    assert_eq!(f.tell(), 300_004);
    assert_eq!(f.close(), 0);

    let mut f = WfdbFile::fopen(&name, b"rb").unwrap();
    for i in 0..100_000u32 {
        assert_eq!(f.g16(), (i as u16) as i16 as i32);
    }
    assert_eq!(f.g32(), -2);
    assert_eq!(f.tell(), 200_004);
    assert_eq!(f.seek(-10, SEEK_END), 0);
    let mut buf = [0u8; 20];
    assert_eq!(f.read(&mut buf), 10);
    assert!(f.eof());
    assert_eq!(f.getc(), EOF);
    assert_eq!(f.seek(4, SEEK_SET), 0);
    assert_eq!(f.g16(), 2);
    assert_eq!(f.seek(2, SEEK_CUR), 0);
    assert_eq!(f.g16(), 4);
    assert_eq!(f.tell(), 10);
    assert_eq!(f.seek(-1, SEEK_SET), -1);
    assert!(f.write(b"x") == 0 && f.error()); // not open for writing
    drop(f);

    // Read/write mode: writing after reading continues at the logical
    // position.
    let mut f = WfdbFile::fopen(&name, b"r+b").unwrap();
    assert_eq!(f.g16(), 0);
    assert_eq!(f.write(b"\x09\x00"), 2);
    assert_eq!(f.seek(0, SEEK_SET), 0);
    assert_eq!(f.g16(), 0);
    assert_eq!(f.g16(), 9);
    assert_eq!(f.g16(), 2);
    assert_eq!(f.close(), 0);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn append_and_lines() {
    let d = tmpdir("app");
    let name = b(&d.join("t.txt"));
    let mut f = WfdbFile::fopen(&name, b"w").unwrap();
    cfprintf!(f, b"%s %d\n", "line", 1);
    drop(f); // flushed on drop
    let mut f = WfdbFile::fopen(&name, b"ab").unwrap();
    assert_eq!(f.tell(), 7);
    cfprintf!(f, b"%s %d\nlast", "line", 2);
    assert_eq!(f.tell(), 18);
    assert_eq!(f.close(), 0);
    let mut f = WfdbFile::fopen(&name, b"rb").unwrap();
    let mut line = Vec::new();
    assert_eq!(f.getline(&mut line), 7);
    assert_eq!(line, b"line 1\n");
    assert!(f.fgets(&mut line, 4));
    assert_eq!(line, b"lin");
    assert!(f.fgets(&mut line, 100));
    assert_eq!(line, b"e 2\n");
    assert!(f.fgets(&mut line, 100));
    assert_eq!(line, b"last");
    assert!(!f.fgets(&mut line, 100));
    assert_eq!(f.getline(&mut line), 0);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn wfdb_open_modes() {
    let _env = env_lock();
    let d = tmpdir("open");
    let mut w = Wfdb::new();
    w.wfdbquiet();
    let mut path = b(&d);
    path.extend_from_slice(b" .");
    w.setwfdb(&path);
    // Output files go to the current directory or the directory given in
    // the record name.
    let mut rec = b(&d);
    rec.extend_from_slice(b"/sub/r1");
    let mut f = w.wfdb_open("hea", &rec, WFDB_WRITE).unwrap();
    f.write(b"r1 0\n");
    drop(f);
    assert!(w.wfdb_filename().ends_with(b"sub/r1.hea"));
    let mut f = w.wfdb_open("hea", &rec, WFDB_APPEND).unwrap();
    f.write(b"#x\n");
    drop(f);
    assert_eq!(std::fs::read(d.join("sub/r1.hea")).unwrap(), b"r1 0\n#x\n");
    // Input: found in the WFDB path; "foo/bar/" means "foo/bar/bar".
    let mut f = w.wfdb_open("hea", "sub/r1", WFDB_READ).unwrap();
    assert_eq!(f.read_to_end(), b"r1 0\n#x\n");
    std::fs::create_dir_all(d.join("sub/r2")).unwrap();
    std::fs::write(d.join("sub/r2/r2.hea"), b"r2 0\n").unwrap();
    assert!(w
        .wfdbfile("hea", "sub/r2/")
        .unwrap()
        .ends_with(b"sub/r2/r2.hea"));
    // wfdbfile(NULL, NULL): the name of the last file tried.
    assert!(w.wfdbfile(NULL, NULL).unwrap().ends_with(b"r2.hea"));
    // A directory is not a file.
    assert!(w.wfdbfile("sub", NULL).is_none());
    assert!(wfdb_fopen(&b(&d.join("sub")), b"rb").is_none());
    // The type alone as a file name.
    assert!(w.wfdbfile("sub/r1.hea", NULL).is_some());
    assert!(w.wfdbfile("sub/r1.hea", "").is_some());
    assert!(w.wfdbfile(NULL, "sub/r1.hea").is_none()); // ".hea" stripped
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn wfdb_path_functions() {
    let _env = env_lock();
    let mut w = Wfdb::new();
    w.setwfdb("a b");
    assert_eq!(w.getwfdb(), b"a b");
    assert_eq!(cstd::getenv("WFDB").unwrap(), b"a b");
    // resetwfdb restores the path only if getwfdb was called before
    // setwfdb.
    w.resetwfdb();
    assert_eq!(w.getwfdb(), b"a b");
    let mut w2 = Wfdb::new();
    let first = w2.getwfdb();
    w2.setwfdb("x");
    w2.resetwfdb();
    assert_eq!(w2.getwfdb(), first);
    // '@file' indirection.
    let d = tmpdir("at");
    std::fs::write(d.join("p"), b"dir1 dir2\r\n").unwrap();
    let mut at = b"@".to_vec();
    at.extend_from_slice(&b(&d.join("p")));
    w.setwfdb(&at);
    assert_eq!(w.getwfdb(), b"dir1 dir2");
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn errors_and_versions() {
    let mut w = Wfdb::new();
    w.wfdbquiet();
    assert_eq!(
        w.wfdberror(),
        b"WFDB library version 10.7.0 (Jun 10 2022).\n"
    );
    w.wfdb_error(wfdbx::cformat!(b"x %d\n", 5));
    assert_eq!(w.wfdberror(), b"x 5\n");
    assert_eq!(wfdbx::wfdbversion(), b"10.7.0");
    assert_eq!(wfdbx::wfdbldflags(), b"");
    assert_eq!(wfdbx::wfdbcflags(), b"");
    assert_eq!(
        wfdbx::wfdbdefwfdb(),
        b". /usr/local/database http://physionet.org/physiobank/database"
    );
    assert_eq!(wfdbx::wfdbdefwfdbcal(), b"wfdbcal");
    assert_eq!(w.wfdb_me_fatal(), 1);
    w.wfdbmemerr(0);
    assert_eq!(w.wfdb_me_fatal(), 0);
}

#[test]
fn default_instance() {
    let _env = env_lock();
    wfdbx::setwfdb(".");
    assert_eq!(wfdbx::getwfdb(), b".");
    assert_eq!(wfdbx::with_default(wfdbx::Wfdb::getwfdb), b".");
}
