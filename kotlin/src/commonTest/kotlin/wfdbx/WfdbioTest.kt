// Tests of WfdbFile, finding files (normal and legacy mode), the input and
// output directories, network settings and error reporting (ports of
// rust/tests/wfdbio.rs, rust/tests/files.rs and the unit tests of
// rust/src/wfdbio.rs, without the parts that need signals).
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

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.EOF
import wfdbx.cstd.SEEK_CUR
import wfdbx.cstd.SEEK_END
import wfdbx.cstd.SEEK_SET
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.unsetenv
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WfdbioTest {
    private fun b(s: String) = s.latin1()
    private fun str(b: ByteArray?) = b?.latin1()

    private fun quiet(): Wfdb {
        val w = Wfdb()
        w.wfdbquiet()
        return w
    }

    /** Runs [f] with the environment variables that locate files unset (restored afterwards). */
    private fun withCleanEnv(f: () -> Unit) {
        val names = listOf("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK")
        val saved = names.map { it to getenv(it) }
        for (n in names) unsetenv(n)
        try {
            f()
        } finally {
            for ((n, v) in saved) if (v == null) unsetenv(n) else setenv(n, v)
        }
    }

    @Test
    fun writeReadSeek() {
        val d = makeTempDir("wrs")
        val name = b("$d/f.dat")
        val f = WfdbFile.fopen(name, "wb")!!
        for (i in 0 until 100_000) f.p16(i)
        f.p32(-2)
        assertEquals(200_004L, f.tell())
        val big = ByteArray(100_000) { 7 }
        assertEquals(100_000, f.write(big))
        assertEquals(300_004L, f.tell())
        assertEquals(0, f.close())

        val g = WfdbFile.fopen(name, "rb")!!
        for (i in 0 until 100_000) assertEquals(i.toShort().toInt(), g.g16())
        assertEquals(-2L, g.g32())
        assertEquals(200_004L, g.tell())
        assertEquals(0, g.seek(-10, SEEK_END))
        val buf = ByteArray(20)
        assertEquals(10, g.read(buf))
        assertTrue(g.eof())
        assertEquals(EOF, g.getc())
        assertEquals(0, g.seek(4, SEEK_SET))
        assertEquals(2, g.g16())
        assertEquals(0, g.seek(2, SEEK_CUR))
        assertEquals(4, g.g16())
        assertEquals(10L, g.tell())
        assertEquals(-1, g.seek(-1, SEEK_SET))
        assertTrue(g.write(b("x")) == 0 && g.error()) // not open for writing
        g.close()

        // Read/write mode: writing after reading continues at the logical position.
        val h = WfdbFile.fopen(name, "r+b")!!
        assertEquals(0, h.g16())
        assertEquals(2, h.write(byteArrayOf(9, 0)))
        assertEquals(0, h.seek(0, SEEK_SET))
        assertEquals(0, h.g16())
        assertEquals(9, h.g16())
        assertEquals(2, h.g16())
        assertEquals(0, h.close())
        assertNull(WfdbFile.fopen(b("$d/nosuch"), "r+b"))
        removeTree(d)
    }

    @Test
    fun appendAndLines() {
        val d = makeTempDir("app")
        val name = b("$d/t.txt")
        val f = WfdbFile.fopen(name, "w")!!
        f.printf("%s %d\n", "line", 1)
        f.close()
        val g = WfdbFile.fopen(name, "ab")!!
        assertEquals(7L, g.tell())
        g.printf("%s %d\nlast", "line", 2)
        assertEquals(18L, g.tell())
        assertEquals(0, g.close())
        val h = WfdbFile.fopen(name, "rb")!!
        val line = ByteVec()
        assertEquals(7, h.getline(line))
        assertEquals("line 1\n", line.toString())
        assertTrue(h.fgets(line, 4))
        assertEquals("lin", line.toString())
        assertTrue(h.fgets(line, 100))
        assertEquals("e 2\n", line.toString())
        assertTrue(h.fgets(line, 100))
        assertEquals("last", line.toString())
        assertFalse(h.fgets(line, 100))
        assertEquals(0, h.getline(line))
        h.close()
        removeTree(d)
    }

    @Test
    fun memFile() {
        val f = WfdbFile.fromBytes(byteArrayOf('a'.code.toByte(), 'b'.code.toByte(), '\n'.code.toByte(), 'c'.code.toByte(), 'd'.code.toByte(), 1, 0x80.toByte(), -1, -1))
        val line = ByteVec()
        assertEquals(3, f.getline(line))
        assertEquals("ab\n", line.toString())
        assertEquals(3L, f.tell())
        assertEquals('c'.code, f.getc())
        assertTrue(f.fgets(line, 2))
        assertEquals("d", line.toString())
        assertEquals(-32767, f.g16())
        assertEquals(0, f.seek(-2, SEEK_END))
        assertEquals(-1, f.g16())
        assertEquals(EOF, f.getc())
        assertTrue(f.eof())
        assertEquals(EOF, f.getc())
        assertEquals(0, f.seek(0, SEEK_SET))
        assertFalse(f.eof())
        assertEquals('a'.code, f.getc())
        assertEquals('z'.code, f.ungetc('z'.code))
        assertEquals('z'.code, f.getc())
    }

    @Test
    fun parsePath() {
        val w = Wfdb()
        w.wfdb_parse_path(b(". /usr/local/database http://physionet.org/physiobank/database"))
        assertEquals(listOf(".", "/usr/local/database", "http://physionet.org/physiobank/database"), w.pathPrefixes().map { it.latin1() })
        assertEquals(WFDB_NET, w.io.pathList[2].ptype)
        w.wfdb_parse_path(b("a:b;c\td"))
        assertEquals(listOf("a", "b", "c", "d"), w.pathPrefixes().map { it.latin1() })
        w.wfdb_parse_path(b(""))
        assertTrue(w.pathPrefixes().isEmpty())
    }

    @Test
    fun addToPath() {
        val w = Wfdb()
        w.io.wfdbpath = b(". a b")
        w.wfdb_parse_path(b(". a b"))
        w.wfdb_addtopath(b("b/100s.hea"))
        assertEquals(listOf(".", "b", "a"), w.pathPrefixes().map { it.latin1() })
        w.wfdb_addtopath(b("x/y/100s.hea"))
        assertEquals(listOf(".", "x/y", "b", "a"), w.pathPrefixes().map { it.latin1() })
        w.wfdb_addtopath(b("100s.hea"))
        assertEquals(4, w.pathPrefixes().size)
        w.wfdb_addtopath(b("./100s.hea"))
        assertEquals(4, w.pathPrefixes().size)
    }

    @Test
    fun stripheaSetirec() {
        assertEquals("100s", wfdb_striphea(b("100s.hea")).latin1())
        assertEquals(".hea", wfdb_striphea(b(".hea")).latin1())
        val w = Wfdb()
        assertNull(w.wfdb_getirec())
        w.wfdb_setirec(b("a/b/rec"))
        assertEquals("rec", str(w.wfdb_getirec()))
        w.wfdb_setirec(b("-"))
        assertEquals("rec", str(w.wfdb_getirec()))
    }

    @Test
    fun checkname() {
        val w = quiet()
        assertEquals(0, w.wfdb_checkname(b("a-b_c~/9"), "record"))
        assertEquals(-1, w.wfdb_checkname(b("a.b"), "record"))
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        assertEquals(-1, w.wfdb_checkname(b(""), "record"))
        // WFDB-x: only the last component of a record name is checked (outside legacy mode)
        assertEquals(0, w.wfdb_checkname(b("my.data/rec"), "record"))
        assertEquals(0, w.wfdb_checkname(b("/a.b/c d/rec"), "record"))
        assertEquals(-1, w.wfdb_checkname(b("my.data/"), "record"))
        assertEquals("init: illegal character 0 in record name\n", str(w.wfdberror()))
        assertEquals(-1, w.wfdb_checkname(b("a:b/rec.1"), "record"))
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        assertEquals(-1, w.wfdb_checkname(b("my.data/a"), "annotator"))
        assertEquals(-1, w.wfdb_checkname(b("é"), "annotator"))
        assertEquals("init: illegal character -23 in annotator name\n", str(w.wfdberror()))
        w.wfdbx_set_legacy(1)
        assertEquals(-1, w.wfdb_checkname(b("my.data/rec"), "record"))
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        assertEquals(0, w.wfdb_checkname(b("dir/rec"), "record"))
    }

    @Test
    fun errorsAndVersions() {
        val w = quiet()
        assertEquals("WFDB library version 10.7.0 (Jun 10 2022).\n", str(w.wfdberror()))
        w.wfdb_error_fmt("x %d\n", 5)
        assertEquals("x 5\n", str(w.wfdberror()))
        assertEquals("10.7.0", str(wfdbversion()))
        assertEquals("", str(wfdbldflags()))
        assertEquals("", str(wfdbcflags()))
        assertEquals(". /usr/local/database http://physionet.org/physiobank/database", str(wfdbdefwfdb()))
        assertEquals("wfdbcal", str(wfdbdefwfdbcal()))
        assertEquals(1, w.wfdb_me_fatal())
        w.wfdbmemerr(0)
        assertEquals(0, w.wfdb_me_fatal())
    }

    @Test
    fun independentInstances() {
        val a = Wfdb()
        val b2 = Wfdb()
        a.wfdb_setirec(b("rec_a"))
        assertNull(b2.wfdb_getirec())
        b2.wfdbquiet()
        b2.wfdb_error("x\n")
        assertEquals("x\n", str(b2.wfdberror()))
        assertTrue(str(a.wfdberror()) != "x\n")
        // the default instance is one per thread, and the same each time
        assertTrue(wfdbDefault() === wfdbDefault())
    }

    @Test
    fun legacyArgs() {
        val w = Wfdb()
        val argv = mutableListOf(b("rdsamp"), b("-r"), b("--legacy"))
        assertEquals(0, w.wfdbx_legacy_args(argv))
        assertEquals(0, w.wfdbx_get_legacy())
        val argv2 = mutableListOf(b("rdsamp"), b("--legacy"), b("-r"))
        assertEquals(1, w.wfdbx_legacy_args(argv2))
        assertEquals(listOf("rdsamp", "-r"), argv2.map { it.latin1() })
        assertEquals(1, w.wfdbx_get_legacy())
        assertEquals(1, w.wfdbx_set_legacy(0))
    }

    /** The WFDB path of legacy mode: %r, the 8.3 form, "..", missing output directories. */
    @Test
    fun percentRAndFiles() = withCleanEnv {
        val dir = makeTempDir("io")
        writeFile("$dir/rec1/rec1.hea", "rec1 0\n")
        writeFile("$dir/rec1/rec1.abc", "x")
        val w = quiet()
        w.wfdbx_set_legacy(1)
        w.setwfdb(b("$dir/%r"))
        w.wfdb_setirec(b("rec1"))
        assertTrue(str(w.wfdbfile("hea", "rec1"))!!.endsWith("rec1/rec1.hea"))
        // Type truncated to 3 characters.
        assertTrue(str(w.wfdbfile("abcdef", "rec1"))!!.endsWith("rec1/rec1.abc"))
        assertNull(w.wfdbfile("hea", "nosuch"))
        // ".." is rejected (legacy mode).
        writeFile("$dir/x", "")
        assertNull(w.wfdb_fopen(b("$dir/rec1/../x"), "rb"))
        // Output: missing directories are created.
        val out = "$dir/new/dir/file.txt"
        val f = w.wfdb_fopen(b(out), "wb")!!
        f.printf("x=%d\n", 42)
        f.putc(1)
        assertEquals(6L, f.tell())
        assertEquals(0, f.close())
        assertEquals("x=42\n\u0001", readFile(out)!!.latin1())
        removeTree(dir)
    }

    @Test
    fun wfdbOpenModesLegacy() = withCleanEnv {
        val d = makeTempDir("open")
        val w = quiet()
        w.wfdbx_set_legacy(1)
        w.setwfdb("$d .")
        // Output files go to the current directory or the directory given in the record name.
        val f = w.wfdb_open("hea", "$d/sub/r1", WFDB_WRITE)!!
        f.write("r1 0\n")
        f.close()
        assertTrue(str(w.wfdb_filename())!!.endsWith("sub/r1.hea"))
        val g = w.wfdb_open("hea", "$d/sub/r1", WFDB_APPEND)!!
        g.write("#x\n")
        g.close()
        assertEquals("r1 0\n#x\n", readFile("$d/sub/r1.hea")!!.latin1())
        // Input: found in the WFDB path; "foo/bar/" means "foo/bar/bar".
        val h = w.wfdb_open("hea", "sub/r1", WFDB_READ)!!
        assertEquals("r1 0\n#x\n", h.readToEnd().latin1())
        h.close()
        writeFile("$d/sub/r2/r2.hea", "r2 0\n")
        assertTrue(str(w.wfdbfile("hea", "sub/r2/"))!!.endsWith("sub/r2/r2.hea"))
        // wfdbfile(NULL, NULL): the name of the last file tried.
        assertTrue(str(w.wfdbfile(null as String?, null))!!.endsWith("r2.hea"))
        // A directory is not a file.
        assertNull(w.wfdbfile("sub", null))
        assertNull(w.wfdb_fopen(b("$d/sub"), "rb"))
        // The type alone as a file name.
        assertNotNull(w.wfdbfile("sub/r1.hea", null))
        assertNotNull(w.wfdbfile("sub/r1.hea", ""))
        assertNull(w.wfdbfile(null, "sub/r1.hea")) // ".hea" stripped
        removeTree(d)
    }

    @Test
    fun wfdbPathFunctionsLegacy() = withCleanEnv {
        val w = Wfdb()
        w.wfdbx_set_legacy(1)
        w.setwfdb("a b")
        assertEquals("a b", str(w.getwfdb()))
        assertEquals("a b", str(getenv("WFDB")))
        // resetwfdb restores the path only if getwfdb was called before setwfdb.
        w.resetwfdb()
        assertEquals("a b", str(w.getwfdb()))
        unsetenv("WFDB")
        val w2 = Wfdb()
        w2.wfdbx_set_legacy(1)
        val first = w2.getwfdb()
        assertEquals(DEFWFDB, first.latin1())
        w2.setwfdb("x")
        w2.resetwfdb()
        assertContentEquals(first, w2.getwfdb())
        // '@file' indirection.
        val d = makeTempDir("at")
        writeFile("$d/p", "dir1 dir2\r\n")
        w.setwfdb("@$d/p")
        assertEquals("dir1 dir2", str(w.getwfdb()))
        removeTree(d)
    }

    /** WFDB-x: the output directory (wfdbx_set_output_dir). */
    @Test
    fun outputDir() = withCleanEnv {
        val d = makeTempDir("outdir")
        val w = quiet()
        assertNull(w.wfdbx_get_output_dir())
        val od = "$d/od"
        assertNull(w.wfdbx_set_output_dir(od))
        assertEquals(od, str(w.wfdbx_get_output_dir()))
        // WFDB_WRITE and WFDB_APPEND create DIR/NAME (missing directories are
        // created); the name may contain a directory.
        val f = w.wfdb_open("hea", "sub/r", WFDB_WRITE)!!
        f.write("sub/r 0\n")
        f.close()
        assertEquals("$od/sub/r.hea", str(w.wfdb_filename()))
        val g = w.wfdb_open("hea", "sub/r", WFDB_APPEND)!!
        g.write("#x\n")
        g.close()
        assertEquals("sub/r 0\n#x\n", readFile("$d/od/sub/r.hea")!!.latin1())
        // Reading is unchanged; wfdbquit keeps the setting.
        w.setwfdb(d)
        assertNull(w.wfdb_open("hea", "sub/r", WFDB_READ))
        w.wfdbquit()
        assertEquals(od, str(w.wfdbx_get_output_dir()))
        // null or "" resets it; the previous value is returned.
        assertEquals(od, str(w.wfdbx_set_output_dir("")))
        assertNull(w.wfdbx_set_output_dir(null as ByteArray?))
        assertNull(w.wfdbx_get_output_dir())
        // legacy mode: a plain prefix of every output name
        w.wfdbx_set_legacy(1)
        w.wfdbx_set_output_dir(od)
        w.wfdb_open("hea", "lg", WFDB_WRITE)!!.close()
        assertEquals("$od/lg.hea", str(w.wfdb_filename()))
        removeTree(d)
    }

    @Test
    fun outputDirSetting() = withCleanEnv {
        setenv("WFDBX_OUTPUT_DIR", "envout")
        val w = quiet()
        assertEquals("envout", str(w.wfdbx_get_output_dir()))
        assertEquals("envout", str(w.wfdbx_set_output_dir("o")))
        // a URL is refused: the setting is unchanged, its value returned
        assertEquals("o", str(w.wfdbx_set_output_dir("http://127.0.0.1/x")))
        assertEquals("wfdbx_set_output_dir: the output directory must be a local directory\n", str(w.wfdberror()))
        assertEquals("o", str(w.wfdbx_get_output_dir()))
        assertEquals("o", str(w.wfdbx_set_output_dir(null as ByteArray?)))
        assertEquals("envout", str(w.wfdbx_get_output_dir()))
        // a URL in WFDBX_OUTPUT_DIR is refused too
        setenv("WFDBX_OUTPUT_DIR", "https://127.0.0.1/x")
        val w2 = quiet()
        assertNull(w2.wfdbx_get_output_dir())
        assertEquals("wfdbx_set_output_dir: the output directory must be a local directory\n", str(w2.wfdberror()))
    }

    @Test
    fun inputDirSetting() = withCleanEnv {
        val w = quiet()
        assertNull(w.wfdbx_get_input_dir())
        assertEquals(".", str(w.getwfdb()))
        assertNull(w.wfdbx_set_input_dir("a"))
        assertEquals("a", str(w.wfdbx_set_input_dir("b")))
        assertEquals("b", str(w.getwfdb()))
        assertEquals("b", str(w.wfdbx_set_input_dir("")))
        assertNull(w.wfdbx_get_input_dir())
        w.wfdbx_set_input_dir("c")
        w.wfdbquit() // the setting is kept
        assertEquals("c", str(w.wfdbx_get_input_dir()))
        // WFDBX_INPUT_DIR: read when first needed, then kept; the default
        val w2 = quiet()
        setenv("WFDBX_INPUT_DIR", "envdir")
        assertEquals("envdir", str(w2.wfdbx_get_input_dir()))
        setenv("WFDBX_INPUT_DIR", "changed")
        assertEquals("envdir", str(w2.wfdbx_set_input_dir("x")))
        assertEquals("x", str(w2.wfdbx_set_input_dir(null as ByteArray?)))
        assertEquals("envdir", str(w2.wfdbx_get_input_dir()))
    }

    @Test
    fun networkSetting() = withCleanEnv {
        val w = quiet()
        assertEquals(0, w.wfdbx_get_network())
        assertEquals(0, w.wfdbx_set_network(1))
        assertEquals(1, w.wfdbx_set_network(0))
        assertEquals(0, w.wfdbx_get_network())
        for ((value, on) in listOf("1" to 1, " 2" to 1, "-1" to 1, "1abc" to 1, "0x1" to 0, "x" to 0, "" to 0, "0" to 0)) {
            setenv("WFDBX_NETWORK", value)
            val w2 = quiet()
            assertEquals(on, w2.wfdbx_get_network(), "WFDBX_NETWORK=$value")
            w2.wfdbx_set_network(1 - on)
            assertEquals(1 - on, w2.wfdbx_set_network(-1)) // the default
            assertEquals(on, w2.wfdbx_get_network())
        }
        // network access off: a URL is not opened
        val w3 = quiet()
        w3.wfdbx_set_network(0)
        assertNull(w3.wfdb_open("hea", "http://127.0.0.1:9/rec", WFDB_READ))
    }

    @Test
    fun setwfdbNormalMode() = withCleanEnv {
        val w = quiet()
        w.setwfdb("one")
        assertEquals("one", str(w.getwfdb()))
        assertEquals("one", str(w.wfdbx_get_input_dir()))
        assertNull(getenv("WFDB")) // nothing is exported
        for (p in listOf("a b", "a;b", "a:b", ". http://127.0.0.1/x")) {
            w.setwfdb(p)
            assertEquals(
                "setwfdb: WFDB-x reads from a single input directory; use wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n",
                str(w.wfdberror()),
            )
            assertEquals("one", str(w.getwfdb()), p)
        }
        w.setwfdb(" http://127.0.0.1:8080/db ")
        assertEquals("http://127.0.0.1:8080/db", str(w.getwfdb()))
        w.setwfdb("two")
        w.wfdbx_set_input_dir("three")
        w.resetwfdb() // the value of the last setwfdb
        assertEquals("two", str(w.getwfdb()))
        for (p in listOf("", ";", "  ")) {
            w.setwfdb(p)
            assertEquals(".", str(w.getwfdb()))
        }
        w.setwfdb(null as ByteArray?)
        assertNull(w.wfdbx_get_input_dir())
        // without a setwfdb, resetwfdb changes nothing
        val w2 = quiet()
        w2.wfdbx_set_input_dir("x")
        w2.resetwfdb()
        assertEquals("x", str(w2.getwfdb()))
    }

    @Test
    fun names() = withCleanEnv {
        val d = makeTempDir("names")
        writeFile("$d/r.hea", "")
        writeFile("$d/sub/s.hea", "")
        writeFile("$d/in/x.hea", "")
        val w = quiet()
        // relative: under the input directory (one separator)
        w.wfdbx_set_input_dir(d)
        assertEquals("$d/r.hea", str(w.wfdbfile("hea", "r")))
        assertEquals("$d/sub/s.hea", str(w.wfdbfile("hea", "sub/s")))
        w.wfdbx_set_input_dir("$d/sub/")
        assertEquals("$d/sub/s.hea", str(w.wfdbfile("hea", "s")))
        assertEquals("$d/sub/../r.hea", str(w.wfdbfile("hea", "../r"))) // ".." allowed
        w.wfdbx_set_input_dir("$d/in")
        assertEquals("$d/in/x.hea", str(w.wfdbfile("hea", "x")))
        assertNull(w.wfdbfile("hea", "r")) // nothing is searched
        // absolute: as given
        assertEquals("$d/r.hea", str(w.wfdbfile("hea", "$d/r")))
        // ~: the home directory (HOME)
        val home = getenv("HOME")
        setenv("HOME", "$d/sub")
        assertEquals("$d/sub/s.hea", str(w.wfdbfile("hea", "~/s")))
        assertNull(w.wfdbfile("hea", "~nosuchuser-wfdbx/h"))
        assertEquals("~nosuchuser-wfdbx/h.hea", str(w.wfdb_filename()))
        w.wfdbx_set_input_dir("~")
        assertEquals("$d/sub/s.hea", str(w.wfdbfile("hea", "s")))
        setenv("HOME", "")
        assertNull(w.wfdbfile("hea", "~/nosuch"))
        assertEquals("/nosuch.hea", str(w.wfdb_filename()))
        if (home == null) unsetenv("HOME") else setenv("HOME", home)
        // the 8.3 form, at the same location
        writeFile("$d/in/y.abc", "")
        w.wfdbx_set_input_dir("$d/in")
        assertEquals("$d/in/y.abc", str(w.wfdbfile("abcdef", "y")))
        // output: under the output directory (relative names only)
        w.wfdbx_set_output_dir("$d/out")
        w.wfdb_open("hea", "o", WFDB_WRITE)!!.close()
        assertEquals("$d/out/o.hea", str(w.wfdb_filename()))
        assertTrue(fileExists("$d/out/o.hea"))
        w.wfdb_open("hea", "$d/o3", WFDB_WRITE)!!.close()
        assertTrue(fileExists("$d/o3.hea"))
        assertEquals("$d/o3.hea", str(w.wfdb_filename()))
        assertNull(w.wfdb_open("hea", "http://127.0.0.1:9/o", WFDB_WRITE))
        removeTree(d)
    }

    /** WFDB-x: an absolute path is used as given; in legacy mode only the WFDB path is searched. */
    @Test
    fun absolutePaths() = withCleanEnv {
        val d = makeTempDir("abs")
        writeFile("$d/r.hea", "r 0\n")
        val rec = "$d/r"
        val name = "$rec.hea"
        val w = quiet()
        w.wfdbx_set_input_dir("/nonexistent-wfdbx-dir")
        w.wfdb_open("hea", rec, WFDB_READ)!!.close()
        assertEquals(name, str(w.wfdb_filename()))
        // nothing is searched: the directory is not added to a path
        assertNull(w.wfdb_open("hea", "r", WFDB_READ))
        assertEquals("/nonexistent-wfdbx-dir/r.hea", str(w.wfdb_filename()))
        // legacy mode: the WFDB path only
        val w2 = quiet()
        w2.wfdbx_set_legacy(1)
        w2.setwfdb("/nonexistent-wfdbx-dir")
        assertNull(w2.wfdb_open("hea", rec, WFDB_READ))
        assertNull(w2.wfdbfile("hea", rec))
        // the setwfdb(";") idiom works in both modes
        for (legacy in listOf(1, 0)) {
            w2.wfdbx_set_legacy(legacy)
            w2.setwfdb(";")
            assertEquals(name, str(w2.wfdbfile("hea", rec)))
        }
        removeTree(d)
    }

    @Test
    fun headerDirectoryContainment() {
        assertTrue(inHeaderDir(b("data/a.dat")))
        assertTrue(inHeaderDir(b("./data/a.dat")))
        assertTrue(inHeaderDir(b("data//a.dat")))
        assertTrue(inHeaderDir(b("a..b")))
        for (n in listOf("../a.dat", "data/../data/a.dat", "/abs/a.dat", "~/a.dat", "http://127.0.0.1:9/a.dat", "..")) {
            assertFalse(inHeaderDir(b(n)), n)
        }
        assertEquals("a/b/", wfdbx_dirname(b("a/b/c.hea")).latin1())
        assertEquals("", wfdbx_dirname(b("c.hea")).latin1())
        val d = makeTempDir("hdr")
        writeFile("$d/db/data/a.dat", "x")
        val w = quiet()
        val f = w.wfdbx_open_in(b("$d/db/"), null, b("data/a.dat"), b("db/rec"))
        assertNotNull(f)
        f.close()
        assertNull(w.wfdbx_open_in(b("$d/db/"), null, b("../a.dat"), b("db/bad")))
        assertEquals(
            "init: file ../a.dat named in the header of record db/bad is not in the header's directory\n",
            str(w.wfdberror()),
        )
        removeTree(d)
    }

    @Test
    fun defaultInstance() = withCleanEnv {
        val prev = wfdbx_set_input_dir(".")
        assertEquals(".", str(getwfdb()))
        assertEquals(".", str(withDefault { it.getwfdb() }))
        assertEquals(".", str(wfdbx_set_input_dir(prev)))
        assertNull(wfdbx_set_output_dir("x"))
        assertEquals("x", str(wfdbx_set_output_dir(null as ByteArray?)))
    }
}
