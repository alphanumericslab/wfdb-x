/* api_expect.c: print the results of WFDB library functions that are not
   exercised by any of the command-line tools, as computed by the original C
   library.  Its output is the source of the expected values of the library
   API unit tests of wfdb-x:

       python/tests/test_api.py
       cpp/tests/test_api_c.cpp
       matlab/tests/test_api_c.m

   Build it with the C reference library (see build_reference.sh), e.g.

       cc -DWFDB_LARGETIME -o api_expect api_expect.c -I$REF/include \
          -L$REF/lib -lwfdb -lFLAC

   and run it in a scratch copy of tests/data (it writes files there):

       cp -r tests/data /tmp/d && cd /tmp/d && WFDB=. /path/to/api_expect

   Each line of output is "label: value(s)".  Strings are printed between
   quotes with C escapes for non-printing characters; a NULL string is
   printed as (null).  Doubles are printed with %.17g.

   Part of wfdb-x, Reza Sameni, Oct 2026.
   GNU General Public License, version 2 or later (see LICENSE). */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <wfdb/wfdb.h>
#include <wfdb/ecgcodes.h>

/* Print a label and a string (or (null)) with C escapes. */
static void pstr(const char *label, const char *s)
{
    printf("%s: ", label);
    if (s == NULL) {
	printf("(null)\n");
	return;
    }
    putchar('"');
    for (; *s; s++) {
	unsigned char c = (unsigned char)*s;
	if (c == '\n') printf("\\n");
	else if (c == '\r') printf("\\r");
	else if (c == '\t') printf("\\t");
	else if (c == '"' || c == '\\') printf("\\%c", c);
	else if (c < 32 || c >= 127) printf("\\x%02x", c);
	else putchar(c);
    }
    printf("\"\n");
}

/* Print the contents of a file (as a string). */
static void pfile(const char *label, const char *name)
{
    static char buf[65536];
    FILE *f = fopen(name, "rb");
    size_t n = 0;

    if (f) {
	n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
    }
    buf[n] = '\0';
    pstr(label, f ? buf : NULL);
}

/* Print the bytes of a file in hexadecimal. */
static void phex(const char *label, const char *name)
{
    FILE *f = fopen(name, "rb");
    int c;

    printf("%s:", label);
    if (f) {
	while ((c = getc(f)) != EOF)
	    printf(" %02x", c);
	fclose(f);
    }
    printf("\n");
}

static long fsize(const char *name)
{
    struct stat st;
    return stat(name, &st) == 0 ? (long)st.st_size : -1L;
}

/* Print n samples. */
static void pvec(const char *label, int stat, const WFDB_Sample *v, int n)
{
    int i;

    printf("%s: %d", label, stat);
    for (i = 0; i < n; i++)
	printf(" %d", v[i]);
    printf("\n");
}

static void pann(const char *label, int stat, const WFDB_Annotation *a)
{
    printf("%s: %d %lld %d %d %d %d\n", label, stat, (long long)a->time,
	   a->anntyp, a->subtyp, a->chan, a->num);
}

static void pcal(const char *label, int stat, const WFDB_Calinfo *c)
{
    printf("%s: %d", label, stat);
    if (stat == 0)
	printf(" %.17g %.17g %.17g %d \"%s\" \"%s\"", c->low, c->high,
	       c->scale, c->caltype, c->sigtype ? c->sigtype : "(null)",
	       c->units ? c->units : "(null)");
    printf("\n");
}

static WFDB_Siginfo isi[8];	/* for isigopen */

static char *S(const char *s)	/* a writable copy of a string */
{
    static char buf[8][256];
    static int i;
    char *p = buf[i++ & 7];
    strcpy(p, s);
    return p;
}

/* Version, configuration strings, and error messages */
static void t_version(void)
{
    char buf[64];

    pstr("wfdbversion", wfdbversion());
    pstr("wfdbdefwfdb", wfdbdefwfdb());
    pstr("wfdbdefwfdbcal", wfdbdefwfdbcal());
    /* build-specific (not compared by the tests): */
    pstr("wfdbldflags", wfdbldflags());
    pstr("wfdbcflags", wfdbcflags());
    /* before any error: "WFDB library version 10.7.0 (<build date>).\n" */
    strncpy(buf, wfdberror(), 29);
    buf[29] = '\0';
    pstr("wfdberror prefix", buf);
    printf("wfdb_me_fatal: %d\n", wfdb_me_fatal());
    wfdbmemerr(0);
    printf("wfdb_me_fatal after wfdbmemerr(0): %d\n", wfdb_me_fatal());
    wfdbquiet();
    printf("isigopen nosuch: %d\n", isigopen("nosuch", isi, 8));
    pstr("wfdberror", wfdberror());
    printf("annopen nosuch: %d\n",
	   annopen("nosuch", &(WFDB_Anninfo){"atr", WFDB_READ}, 1));
    pstr("wfdberror", wfdberror());
    wfdbverbose();
    wfdbquit();
}

/* WFDB path and file names */
static void t_path(void)
{
    pstr("getwfdb initial", getwfdb());	/* from the environment */
    setwfdb("a b");
    pstr("getwfdb", getwfdb());
    resetwfdb();
    pstr("getwfdb after resetwfdb", getwfdb());
    setwfdb("c");
    wfdbquit();				/* also resets the path */
    pstr("getwfdb after wfdbquit", getwfdb());
    setwfdb(".");
    pstr("wfdbfile hea 100s", wfdbfile("hea", S("100s")));
    pstr("wfdbfile NULL NULL", wfdbfile(NULL, NULL));
    pstr("wfdbfile hea 100s.hea", wfdbfile("hea", S("100s.hea")));
    pstr("wfdbfile atr 100s", wfdbfile("atr", S("100s")));
    pstr("wfdbfile dat nosuch", wfdbfile("dat", S("nosuch")));
    pstr("wfdbfile wfdbcal NULL", wfdbfile("wfdbcal", NULL));
    wfdbquit();
}

/* Buffer sizes */
static void t_bufsize(void)
{
    printf("setibsize 0: %d\n", setibsize(0));
    printf("setibsize 1000: %d\n", setibsize(1000));
    printf("setibsize -1: %d\n", setibsize(-1));
    printf("setobsize 0: %d\n", setobsize(0));
    printf("setobsize 2000: %d\n", setobsize(2000));
    printf("setobsize -5: %d\n", setobsize(-5));
    isigopen("100s", isi, 8);
    printf("setibsize after isigopen: %d\n", setibsize(512));
    wfdbquit();
    setibsize(0);
    setobsize(0);
}

/* getvec modes, frequencies, amplitude conversion */
static void t_signals(void)
{
    WFDB_Sample v[8];
    int i, s;

    printf("getgvmode default: %d\n", getgvmode());
    printf("isigopen 100s: %d\n", isigopen("100s", isi, 8));
    printf("getifreq: %.17g\n", getifreq());
    printf("getspf: %d\n", getspf());
    wfdbquit();
    /* resampling (fmt16 is sampled at 250 Hz) */
    isigopen("fmt16", isi, 8);
    for (i = 0; i < 3; i++)
	pvec("getvec", getvec(v), v, 3);
    printf("setifreq 100: %d\n", setifreq(100.0));
    printf("getifreq: %.17g\n", getifreq());
    printf("isigsettime 0: %d\n", isigsettime(0));
    for (i = 0; i < 3; i++)
	pvec("getvec 100", getvec(v), v, 3);
    printf("setifreq 1000: %d\n", setifreq(1000.0));
    printf("getifreq: %.17g\n", getifreq());
    printf("isigsettime 2: %d\n", isigsettime(2));
    for (i = 0; i < 5; i++)
	pvec("getvec 1000", getvec(v), v, 3);
    printf("getafreq after setifreq: %.17g\n", getafreq()); /* set too */
    printf("setifreq -1: %d\n", setifreq(-1.0));
    printf("getifreq: %.17g\n", getifreq());
    setafreq(0.0);
    wfdbquit();
    isigopen("100s", isi, 8);
    setgvmode(WFDB_HIGHRES);
    printf("getgvmode HIGHRES: %d\n", getgvmode());
    setgvmode(WFDB_GVPAD | WFDB_LOWRES);
    printf("getgvmode GVPAD: %d\n", getgvmode());
    setgvmode(WFDB_HIGHRES | WFDB_GVPAD | 4);
    printf("getgvmode 7: %d\n", getgvmode());
    setgvmode(0);

    /* amplitude conversion (gain 200, baseline 1024) */
    printf("adumuv: %d %d %d %d %d\n", adumuv(0, 200), adumuv(0, -37),
	   adumuv(1, 1), adumuv(0, -1), adumuv(7, 100));
    printf("muvadu: %d %d %d %d\n", muvadu(0, 1000), muvadu(0, -333),
	   muvadu(1, 2), muvadu(9, 1000));
    printf("aduphys: %.17g %.17g %.17g\n", aduphys(0, 1224), aduphys(1, 900),
	   aduphys(5, 300));
    printf("physadu: %d %d %d\n", physadu(0, 1.0), physadu(1, -0.5023),
	   physadu(5, 1.5));
    wfdbquit();

    /* random access with sample() */
    isigopen("100s", isi, 8);
    printf("sample_valid initial: %d\n", sample_valid());
    s = sample(0, 0);
    printf("sample 0 0: %d %d\n", s, sample_valid());
    s = sample(1, 1000);
    printf("sample 1 1000: %d %d\n", s, sample_valid());
    s = sample(0, 21599);
    printf("sample 0 21599: %d %d\n", s, sample_valid());
    s = sample(0, 21600);
    printf("sample 0 21600: %d %d\n", s, sample_valid());
    s = sample(0, 5);
    printf("sample 0 5: %d %d\n", s, sample_valid());
    s = sample(1, -3);
    printf("sample 1 -3: %d %d\n", s, sample_valid());
    s = sample(2, 0);
    printf("sample 2 0: %d %d\n", s, sample_valid());
    wfdbquit();

    /* calibrated signals with baselines and other units */
    isigopen("fmt16", isi, 8);
    printf("fmt16 adumuv: %d %d %d\n", adumuv(0, 100), adumuv(1, 150),
	   adumuv(2, -7));
    printf("fmt16 muvadu: %d %d %d\n", muvadu(0, 1000), muvadu(1, 1000),
	   muvadu(2, -2500));
    printf("fmt16 aduphys: %.17g %.17g %.17g\n", aduphys(0, 95),
	   aduphys(1, 10), aduphys(2, -3));
    printf("fmt16 physadu: %d %d %d\n", physadu(0, 1.0), physadu(1, -2.25),
	   physadu(2, 0.4));
    wfdbquit();
}

/* Multi-frequency records: getframe, getspf, high-resolution mode */
static void t_frames(void)
{
    WFDB_Sample v[16];

    isigopen("mfreq", isi, 8);
    printf("mfreq getspf: %d\n", getspf());
    printf("mfreq getifreq: %.17g\n", getifreq());
    pvec("getframe", getframe(v), v, 7);
    pvec("getframe", getframe(v), v, 7);
    pvec("getvec", getvec(v), v, 3);
    isigsettime(599);
    pvec("getframe 599", getframe(v), v, 7);
    printf("getframe end: %d\n", getframe(v));
    wfdbquit();
    setgvmode(WFDB_HIGHRES);
    isigopen("mfreq", isi, 8);
    printf("highres getspf: %d\n", getspf());
    printf("highres getifreq: %.17g\n", getifreq());
    pvec("highres getframe", getframe(v), v, 7);
    pvec("highres getvec", getvec(v), v, 3);
    pvec("highres getvec", getvec(v), v, 3);
    wfdbquit();
    setgvmode(0);
}

/* Signal groups: isgsettime */
static void t_groups(void)
{
    WFDB_Sample v[4];

    isigopen("twog", isi, 8);
    pvec("twog getvec", getvec(v), v, 3);
    printf("isgsettime 1 100: %d\n", isgsettime(1, 100));
    pvec("twog getvec", getvec(v), v, 3);
    pvec("twog getvec", getvec(v), v, 3);
    printf("isgsettime 0 500: %d\n", isgsettime(0, 500));
    pvec("twog getvec", getvec(v), v, 3);
    printf("isgsettime 1 1001: %d\n", isgsettime(1, 1001));
    printf("twog getvec end: %d\n", getvec(v));
    wfdbquit();
}

/* Multi-segment records: tnextvec, getseginfo */
static void t_segments(void)
{
    WFDB_Seginfo *seg;
    int i, n;

    isigopen("100s", isi, 8);
    printf("getseginfo 100s: %d\n", getseginfo(&seg));
    printf("tnextvec 100s 0 5: %lld\n", (long long)tnextvec(0, 5));
    printf("tnextvec 100s 1 0: %lld\n", (long long)tnextvec(1, 0));
    wfdbquit();

    isigopen("multi", isi, 8);
    n = getseginfo(&seg);
    printf("getseginfo multi: %d\n", n);
    for (i = 0; i < n; i++)
	printf("segment: %s %lld %lld\n", seg[i].recname,
	       (long long)seg[i].nsamp, (long long)seg[i].samp0);
    printf("tnextvec multi 0 0: %lld\n", (long long)tnextvec(0, 0));
    printf("tnextvec multi 0 21599: %lld\n", (long long)tnextvec(0, 21599));
    printf("tnextvec multi 1 21700: %lld\n", (long long)tnextvec(1, 21700));
    printf("tnextvec multi 0 44999: %lld\n", (long long)tnextvec(0, 44999));
    printf("tnextvec multi 0 45000: %lld\n", (long long)tnextvec(0, 45000));
    wfdbquit();

    isigopen("vlay", isi, 8);
    n = getseginfo(&seg);
    printf("getseginfo vlay: %d\n", n);
    for (i = 0; i < n; i++)
	printf("segment: %s %lld %lld\n", seg[i].recname,
	       (long long)seg[i].nsamp, (long long)seg[i].samp0);
    printf("tnextvec vlay 0 0: %lld\n", (long long)tnextvec(0, 0));
    printf("tnextvec vlay 1 1499: %lld\n", (long long)tnextvec(1, 1499));
    printf("tnextvec vlay 2 1500: %lld\n", (long long)tnextvec(2, 1500));
    printf("tnextvec vlay 0 1600: %lld\n", (long long)tnextvec(0, 1600));
    printf("tnextvec vlay 5 0: %lld\n", (long long)tnextvec(5, 0));
    wfdbquit();
}

/* Skew and byte offsets (input) */
static void t_skew(void)
{
    WFDB_Sample v[4];

    isigopen("skew", isi, 8);
    printf("wfdbgetskew: %d %d %d %d\n", wfdbgetskew(0), wfdbgetskew(1),
	   wfdbgetskew(2), wfdbgetskew(3));
    pvec("skew getvec", getvec(v), v, 3);
    wfdbsetiskew(1, 2);
    wfdbsetiskew(2, 100000);	/* too large: ignored */
    wfdbsetiskew(0, -1);	/* negative: ignored */
    printf("wfdbgetskew after wfdbsetiskew: %d %d %d\n", wfdbgetskew(0),
	   wfdbgetskew(1), wfdbgetskew(2));
    wfdbquit();

    isigopen("prolog", isi, 8);
    printf("wfdbgetstart prolog: %ld %ld %ld\n", wfdbgetstart(0),
	   wfdbgetstart(2), wfdbgetstart(3));
    wfdbquit();
    isigopen("100s", isi, 8);
    printf("wfdbgetstart 100s: %ld\n", wfdbgetstart(0));
    wfdbquit();
}

/* Output: skew, byte offsets, prologs, info strings, wfdbflush */
static void t_output(void)
{
    WFDB_Siginfo si[2];
    WFDB_Sample v[2];
    WFDB_Anninfo ai;
    WFDB_Annotation a;
    int i;

    setcfreq(0.0);	/* (the counter frequency survives wfdbquit) */
    memset(si, 0, sizeof(si));
    for (i = 0; i < 2; i++) {
	si[i].fname = "out.dat";
	si[i].desc = i ? "second" : "first";
	si[i].units = "mV";
	si[i].gain = 100;
	si[i].group = 0;
	si[i].fmt = 16;
	si[i].adcres = 12;
    }
    setsampfreq(100.0);
    printf("osigfopen: %d\n", osigfopen(si, 2));
    printf("wfdbputprolog: %d\n", wfdbputprolog("PROLOG!", 7L, 0));
    wfdbsetskew(1, 4);
    for (i = 0; i < 5; i++) {
	v[0] = i;
	v[1] = -i;
	putvec(v);
    }
    ai.name = "tst";
    ai.stat = WFDB_WRITE;
    printf("annopen out tst: %d\n", annopen("out", &ai, 1));
    memset(&a, 0, sizeof(a));
    a.time = 3;
    a.anntyp = NORMAL;
    putann(0, &a);
    a.time = 4;
    a.anntyp = PVC;
    putann(0, &a);
    wfdbflush();
    printf("sizes after wfdbflush: %ld %ld\n", fsize("out.dat"),
	   fsize("out.tst"));
    printf("newheader: %d\n", newheader("out"));
    printf("putinfo: %d\n", putinfo("info line"));
    wfdbquit();
    pfile("out.hea", "out.hea");
    phex("out.dat", "out.dat");
    phex("out.tst", "out.tst");

    /* wfdbsetstart (without a prolog) */
    setsampfreq(100.0);
    si[0].fname = si[1].fname = "out2.dat";
    osigfopen(si, 2);
    wfdbsetstart(0, 512L);
    v[0] = 1; v[1] = 2;
    putvec(v);
    newheader("out2");
    wfdbquit();
    pfile("out2.hea", "out2.hea");
    printf("out2.dat size: %ld\n", fsize("out2.dat"));
}

/* Info strings */
static void t_info(void)
{
    pstr("getinfo 100s", getinfo(S("100s")));
    pstr("getinfo", getinfo(NULL));
    pstr("getinfo", getinfo(NULL));
    printf("setinfo newrec: %d\n", setinfo(S("newrec")));
    printf("putinfo: %d\n", putinfo("first"));
    printf("putinfo: %d\n", putinfo("second"));
    printf("setinfo NULL: %d\n", setinfo(NULL));
    printf("putinfo without record: %d\n", putinfo("third"));
    pfile("newrec.info", "newrec.info");
    pstr("getinfo newrec", getinfo(S("newrec")));
    pstr("getinfo", getinfo(NULL));
    pstr("getinfo", getinfo(NULL));
    printf("setinfo 100s: %d\n", setinfo(S("100s")));
    printf("putinfo: %d\n", putinfo("extra"));
    wfdbquit();
    pstr("getinfo 100s", getinfo(S("100s")));
    pstr("getinfo", getinfo(NULL));
    pstr("getinfo", getinfo(NULL));
    pstr("getinfo", getinfo(NULL));
    isigopen("fmt16", isi, 8);
    pstr("getinfo open record", getinfo(NULL));
    wfdbquit();
    /* wfdb_freeinfo: getinfo(NULL) restarts from the first info string of
       the current input record (fmt16: its name survives wfdbquit) */
    pstr("getinfo 100s", getinfo(S("100s")));
    pstr("getinfo", getinfo(NULL));
    wfdb_freeinfo();
    pstr("getinfo after wfdb_freeinfo", getinfo(NULL));
    isigopen("100s", isi, 8);
    pstr("getinfo after isigopen", getinfo(NULL));
    wfdb_freeinfo();
    pstr("getinfo after wfdb_freeinfo", getinfo(NULL));
    pstr("getinfo", getinfo(NULL));
    wfdbquit();
}

/* Multi-segment headers */
static void t_msheader(void)
{
    char *segs[3] = {"100s", "null", "100s"};
    char *bad[2] = {"100s", "fmt16"};
    WFDB_Seginfo *seg;
    WFDB_Sample v[2];
    int i, n;

    printf("setmsheader: %d\n", setmsheader(S("msrec"), segs, 3));
    printf("setmsheader 0 segments: %d\n", setmsheader(S("msbad"), segs, 0));
    printf("setmsheader mismatch: %d\n", setmsheader(S("msbad"), bad, 2));
    wfdbquit();
    pfile("msrec.hea", "msrec.hea");
    printf("isigopen msrec: %d\n", isigopen("msrec", isi, 8));
    n = getseginfo(&seg);
    printf("getseginfo msrec: %d\n", n);
    for (i = 0; i < n; i++)
	printf("segment: %s %lld %lld\n", seg[i].recname,
	       (long long)seg[i].nsamp, (long long)seg[i].samp0);
    isigsettime(21599);
    pvec("msrec getvec", getvec(v), v, 2);
    pvec("msrec getvec", getvec(v), v, 2);
    wfdbquit();
}

/* Counter frequency, base counter value, base time */
static void t_counter(void)
{
    isigopen("100s", isi, 8);
    printf("getcfreq: %.17g\n", getcfreq());
    printf("getbasecount: %.17g\n", getbasecount());
    setcfreq(1000.0);
    setbasecount(500.5);
    printf("getcfreq: %.17g\n", getcfreq());
    printf("getbasecount: %.17g\n", getbasecount());
    printf("strtim c1500.5: %lld\n", (long long)strtim("c1500.5"));
    printf("strtim c500.5: %lld\n", (long long)strtim("c500.5"));
    setcfreq(0.0);
    printf("getcfreq after setcfreq 0: %.17g\n", getcfreq());
    printf("setbasetime: %d\n", setbasetime(S("10:20:30 15/6/2001")));
    pstr("timstr 0", timstr(0));
    pstr("timstr 360", timstr(360));
    pstr("timstr -360", timstr(-360));
    pstr("mstimstr -1000", mstimstr(-1000));
    printf("setbasetime time only: %d\n", setbasetime(S("8:00")));
    pstr("timstr 0", timstr(0));
    pstr("timstr -720", timstr(-720));
    printf("setbasetime bad: %d\n", setbasetime(S("garbage")));
    setcfreq(500.0);
    wfdbquit();
    printf("getcfreq after wfdbquit: %.17g\n", getcfreq());
    setcfreq(0.0);
}

/* Calibration */
static void t_calib(void)
{
    WFDB_Calinfo c;
    int st;

    printf("calopen: %d\n", calopen("wfdbcal"));
    st = getcal("ECG lead II", "mV", &c);
    pcal("getcal ECG mV", st, &c);
    st = getcal("ECG", "uV", &c);
    pcal("getcal ECG uV", st, &c);
    st = getcal("ABP", "mmHg", &c);
    pcal("getcal ABP", st, &c);
    st = getcal("BP", NULL, &c);
    pcal("getcal BP NULL", st, &c);
    st = getcal(NULL, NULL, &c);
    pcal("getcal NULL NULL", st, &c);
    st = getcal("nosuch", "x", &c);
    pcal("getcal nosuch", st, &c);
    c.low = -1.5;
    c.high = 2.5;
    c.scale = 3;
    c.sigtype = "TEST";
    c.units = "xu";
    c.caltype = WFDB_DC_COUPLED | WFDB_CAL_SINE;
    printf("putcal: %d\n", putcal(&c));
    c.low = 0;
    c.high = 0;
    c.scale = 7;
    c.sigtype = "AC";
    c.units = "yu";
    c.caltype = WFDB_AC_COUPLED | WFDB_CAL_UNDEF;
    printf("putcal: %d\n", putcal(&c));
    st = getcal("TEST signal", "xu", &c);
    pcal("getcal TEST", st, &c);
    flushcal();
    st = getcal("ECG", "mV", &c);
    pcal("getcal after flushcal", st, &c);
    c.low = -1.5;
    c.high = 2.5;
    c.scale = 3;
    c.sigtype = "TEST";
    c.units = "xu";
    c.caltype = WFDB_DC_COUPLED | WFDB_CAL_SINE;
    putcal(&c);
    c.low = 0;
    c.high = 0;
    c.scale = 7;
    c.sigtype = "AC";
    c.units = "yu";
    c.caltype = WFDB_AC_COUPLED | WFDB_CAL_UNDEF;
    putcal(&c);
    c.low = 1;
    c.high = 2;
    c.scale = 0.25;
    c.sigtype = "SQ";
    c.units = "zu";
    c.caltype = WFDB_DC_COUPLED | WFDB_CAL_SQUARE;
    putcal(&c);
    c.caltype = WFDB_AC_COUPLED | WFDB_CAL_SAWTOOTH;
    c.sigtype = "SAW";
    putcal(&c);
    printf("newcal bad name: %d\n", newcal("my.cal"));
    printf("newcal: %d\n", newcal("mycal"));
    pfile("mycal", "mycal");
    printf("calopen mycal: %d\n", calopen("mycal"));
    st = getcal("AC", "yu", &c);
    pcal("getcal AC", st, &c);
    st = getcal("ECG", "mV", &c);
    pcal("getcal ECG", st, &c);
    printf("calopen +wfdbcal: %d\n", calopen("+wfdbcal"));
    st = getcal("ECG", "mV", &c);
    pcal("getcal ECG", st, &c);
    st = getcal("SAW", NULL, &c);
    pcal("getcal SAW", st, &c);
    printf("calopen nosuch: %d\n", calopen("nosuch.cal"));
    flushcal();
}

/* Input annotators */
static void t_annot(void)
{
    WFDB_Anninfo ai[2];
    WFDB_Annotation a, b;
    int st;

    printf("getafreq default: %.17g\n", getafreq());
    isigopen("100s", isi, 8);
    ai[0].name = "atr";
    ai[0].stat = WFDB_READ;
    ai[1].name = "ooo";
    ai[1].stat = WFDB_READ;
    printf("annopen: %d\n", annopen("100s", ai, 2));
    printf("getiafreq: %.17g %.17g %.17g\n", getiafreq(0), getiafreq(1),
	   getiafreq(2));
    printf("getiaorigfreq: %.17g %.17g %.17g\n", getiaorigfreq(0),
	   getiaorigfreq(1), getiaorigfreq(2));
    st = getann(0, &a);
    pann("getann", st, &a);
    st = getann(0, &a);
    pann("getann", st, &a);
    setiafreq(0, 1000.0);
    printf("getiafreq after setiafreq: %.17g\n", getiafreq(0));
    printf("getiaorigfreq after setiafreq: %.17g\n", getiaorigfreq(0));
    st = getann(0, &a);
    pann("getann 1000", st, &a);
    printf("ungetann: %d\n", ungetann(0, &a));
    printf("ungetann full: %d\n", ungetann(0, &a));
    printf("ungetann 5: %d\n", ungetann(5, &a));
    st = getann(0, &b);
    pann("getann after ungetann", st, &b);
    st = getann(0, &b);
    pann("getann", st, &b);
    a.time = 5;
    a.anntyp = PVC;
    printf("ungetann other: %d\n", ungetann(0, &a));
    st = getann(0, &b);
    pann("getann after ungetann other", st, &b);
    setiafreq(0, 0.0);
    printf("getiafreq after setiafreq 0: %.17g\n", getiafreq(0));
    st = getann(0, &b);
    pann("getann", st, &b);
    iannclose(0);
    printf("getiafreq after iannclose: %.17g %.17g\n", getiafreq(0),
	   getiafreq(1));
    st = getann(0, &b);
    pann("getann ooo", st, &b);
    st = getann(1, &b);
    printf("getann 1 after iannclose: %d\n", st);
    iannclose(0);
    st = getann(0, &b);
    printf("getann 0 after iannclose: %d\n", st);
    iannclose(3);
    wfdbquit();

    /* an annotation file with its own time resolution */
    setafreq(1000.0);
    printf("getafreq: %.17g\n", getafreq());
    ai[0].name = "hf";
    ai[0].stat = WFDB_WRITE;
    annopen("100s", ai, 1);
    memset(&a, 0, sizeof(a));
    a.anntyp = NORMAL;
    a.time = 1000;
    putann(0, &a);
    a.time = 2500;
    putann(0, &a);
    wfdbquit();
    printf("getafreq after wfdbquit: %.17g\n", getafreq());
    setafreq(0.0);
    ai[0].stat = WFDB_READ;
    annopen("100s", ai, 1);
    printf("hf getiafreq: %.17g\n", getiafreq(0));
    printf("hf getiaorigfreq: %.17g\n", getiaorigfreq(0));
    st = getann(0, &a);
    pann("hf getann", st, &a);
    setiafreq(0, 360.0);
    printf("hf getiafreq 360: %.17g\n", getiafreq(0));
    st = getann(0, &a);
    pann("hf getann 360", st, &a);
    wfdbquit();
}

/* Annotation mnemonics and descriptions */
static void t_strings(void)
{
    WFDB_Anninfo ai;
    WFDB_Annotation a;
    int c;

    pstr("ecgstr 1", ecgstr(1));
    pstr("ecgstr 0", ecgstr(0));
    pstr("ecgstr 15", ecgstr(15));
    pstr("ecgstr 22", ecgstr(22));
    pstr("ecgstr 50", ecgstr(50));
    pstr("ecgstr -1", ecgstr(-1));
    printf("strecg: %d %d %d %d\n", strecg("V"), strecg("xx"), strecg(""),
	   strecg("[15]"));
    printf("setecgstr 5: %d\n", setecgstr(5, "PVC"));
    pstr("ecgstr 5", ecgstr(5));
    pstr("annstr 5", annstr(5));
    printf("strecg: %d %d\n", strecg("PVC"), strecg("V"));
    printf("setecgstr 50: %d\n", setecgstr(50, "x"));
    printf("setecgstr -1: %d\n", setecgstr(-1, "x"));
    printf("setecgstr 0: %d\n", setecgstr(0, "Z"));
    pstr("ecgstr 0", ecgstr(0));
    setecgstr(5, "V");
    setecgstr(0, " ");

    printf("setannstr 5: %d\n", setannstr(5, "pvc"));
    pstr("annstr 5", annstr(5));
    pstr("ecgstr 5", ecgstr(5));
    printf("strann: %d %d\n", strann("pvc"), strann("V"));
    printf("setannstr -6: %d\n", setannstr(-6, "fus"));
    pstr("annstr 6", annstr(6));
    printf("setannstr 60: %d\n", setannstr(60, "x"));
    printf("setannstr -60: %d\n", setannstr(-60, "x"));
    printf("setannstr 0: %d\n", setannstr(0, "zero"));
    pstr("annstr 0", annstr(0));
    pstr("annstr 60", annstr(60));
    printf("setannstr 42: %d\n", setannstr(42, "new"));
    printf("strann new: %d\n", strann("new"));

    pstr("anndesc 1", anndesc(1));
    pstr("anndesc 15", anndesc(15));
    pstr("anndesc 60", anndesc(60));
    pstr("anndesc -1", anndesc(-1));
    printf("setanndesc 15: %d\n", setanndesc(15, "my description"));
    pstr("anndesc 15", anndesc(15));
    printf("setanndesc -43: %d\n", setanndesc(-43, "negative"));
    pstr("anndesc 43", anndesc(43));
    printf("setanndesc 50: %d\n", setanndesc(50, "x"));

    /* Modified mnemonics are written into output annotation files. */
    ai.name = "mod";
    ai.stat = WFDB_WRITE;
    annopen("100s", &ai, 1);
    memset(&a, 0, sizeof(a));
    a.time = 10;
    a.anntyp = PVC;
    putann(0, &a);
    wfdbquit();
    phex("100s.mod", "100s.mod");
    setannstr(5, "V");
    setannstr(-6, "F");
    setannstr(0, " ");
    setannstr(-42, "[42]");
    setanndesc(-15, "");
    setanndesc(-43, "");

    /* Reading the file defines the mnemonics again. */
    ai.stat = WFDB_READ;
    annopen("100s", &ai, 1);
    c = getann(0, &a);
    pann("getann mod", c, &a);
    pstr("annstr 5 after reading", annstr(5));
    pstr("anndesc 15 after reading", anndesc(15));
    pstr("anndesc 42 after reading", anndesc(42));
    wfdbquit();
    setannstr(-5, "V");
}

/* Annotation code maps (ecgmap.h, as functions) */
static void t_maps(void)
{
    int c;

    printf("code isann isqrs map1 map2 annpos mamap0 mamap-1\n");
    for (c = -1; c <= 50; c++)
	printf("map %d: %d %d %d %d %d %d %d\n", c, wfdb_isann(c),
	       wfdb_isqrs(c), wfdb_map1(c), wfdb_map2(c), wfdb_annpos(c),
	       wfdb_mamap(c, 0), wfdb_mamap(c, -1));
    printf("ammap:");
    for (c = 'C'; c <= '_'; c++)
	printf(" %d", wfdb_ammap(c));
    printf("\n");
    printf("setisqrs 1 0: %d\n", wfdb_setisqrs(1, 0));
    printf("isqrs 1: %d\n", wfdb_isqrs(1));
    printf("setisqrs 60 1: %d\n", wfdb_setisqrs(60, 1));
    printf("setisqrs 2 300: %d\n", wfdb_setisqrs(2, 300));
    printf("isqrs 2: %d\n", wfdb_isqrs(2));
    printf("setmap1 14 PVC: %d\n", wfdb_setmap1(14, PVC));
    printf("map1 14: %d\n", wfdb_map1(14));
    printf("setmap1 0 PVC: %d\n", wfdb_setmap1(0, PVC));
    printf("setmap2 14 SVPB: %d\n", wfdb_setmap2(14, SVPB));
    printf("map2 14: %d\n", wfdb_map2(14));
    printf("setmap2 -3 PVC: %d\n", wfdb_setmap2(-3, PVC));
    printf("setannpos 14 6: %d\n", wfdb_setannpos(14, 6));
    printf("annpos 14: %d\n", wfdb_annpos(14));
    printf("setannpos 50 2: %d\n", wfdb_setannpos(50, 2));
    wfdb_setisqrs(1, 1);
    wfdb_setisqrs(2, 1);
    wfdb_setmap1(14, NOTQRS);
    wfdb_setmap2(14, NOTQRS);
    wfdb_setannpos(14, 2);
}

/* Miscellaneous cases: default calibration file, uncalibrated signals,
   deskewing by getframe, resampling and sample() of multi-frequency
   records */
static void t_extra(void)
{
    WFDB_Calinfo c;
    WFDB_Sample v[16];
    int i, st;

    printf("calopen NULL: %d\n", calopen(NULL));	/* $WFDBCAL (wfdbcal) */
    st = getcal("Resp", NULL, &c);
    pcal("getcal Resp", st, &c);
    flushcal();

    isigopen("null", isi, 8);			/* gain 0 (uncalibrated) */
    printf("null adumuv: %d %d\n", adumuv(0, 100), muvadu(1, 100));
    printf("null aduphys: %.17g %d\n", aduphys(0, 100), physadu(1, 0.5));
    pvec("null getvec", getvec(v), v, 2);
    wfdbquit();

    isigopen("skew", isi, 8);
    pvec("skew getframe", getframe(v), v, 3);
    pvec("skew getframe", getframe(v), v, 3);
    isigsettime(1497);
    pvec("skew getframe 1497", getframe(v), v, 3);
    pvec("skew getframe 1498", getframe(v), v, 3);
    wfdbquit();

    isigopen("mfreq", isi, 8);
    printf("mfreq setifreq 200: %d\n", setifreq(200.0));
    for (i = 0; i < 3; i++)
	pvec("mfreq getvec 200", getvec(v), v, 3);
    printf("mfreq getafreq: %.17g\n", getafreq());
    setafreq(0.0);
    wfdbquit();
    isigopen("mfreq", isi, 8);
    st = sample(2, 10);
    printf("mfreq sample 2 10: %d %d\n", st, sample_valid());
    st = sample(1, 599);
    printf("mfreq sample 1 599: %d %d\n", st, sample_valid());
    wfdbquit();

    isigopen("multi", isi, 8);
    printf("isigsettime multi 100: %d\n", isigsettime(100));
    printf("tnextvec multi 0 21650: %lld\n", (long long)tnextvec(0, 21650));
    pvec("multi getvec", getvec(v), v, 2);
    wfdbquit();
}

/* FLAC signals: after a failed seek (past the end of the stream), the next
   block decoded by libFLAC is refused by the library's callback (the
   decoder is aborted): getvec fails, and so do later seeks.  A seek to the
   current time is not performed (isgsetframe returns at once). */
static void t_flacseek(void)
{
    WFDB_Sample v[4];

    isigopen("flac16", isi, 8);
    printf("flac isigsettime 99999: %d\n", isigsettime(99999));
    pvec("flac getvec after failed seek", getvec(v), v, 3);
    printf("flac isigsettime 0 after abort: %d\n", isigsettime(0));
    pvec("flac getvec after abort", getvec(v), v, 3);
    wfdbquit();
    isigopen("flac16", isi, 8);
    printf("flac isigsettime 99999: %d\n", isigsettime(99999));
    printf("flac isigsettime 5 after failed seek: %d\n", isigsettime(5));
    pvec("flac getvec 5", getvec(v), v, 3);
    wfdbquit();
    isigopen("flac16", isi, 8);
    pvec("flac getvec 0", getvec(v), v, 3);
    printf("flac isigsettime 9001: %d\n", isigsettime(9001));
    printf("flac isigsettime 1 (current time): %d\n", isigsettime(1));
    pvec("flac getvec after failed seek", getvec(v), v, 3);
    wfdbquit();
}

/* wfdb-x divergences (docs/DIVERGENCES.md): the library has no default
   sampling frequency or gain. */
static void pphys(const char *label, double x)
{
    if (isnan(x)) printf("%s: NaN\n", label);
    else printf("%s: %.17g\n", label, x);
}

static void t_nodefaults(void)
{
    static const char *ts[] = { "s10", "e", "i", "o", "c10", "f3", "10",
				"1:0", "[10:00:00]", " s5", "", NULL };
    FILE *f;
    int i;

    for (i = 0; ts[i]; i++)
	printf("wfdbx_time_needs_freq \"%s\": %d\n", ts[i],
	       wfdbx_time_needs_freq(ts[i]));
    wfdbquiet();
    /* no input record: no sampling frequency */
    printf("strtim 1:0 (no frequency): %ld\n", (long)strtim("1:0"));
    pstr("error", wfdberror());
    printf("strtim s10 (no frequency): %ld\n", (long)strtim("s10"));
    pstr("timstr 360 (no frequency)", timstr(360));
    pstr("error", wfdberror());
    pstr("mstimstr -360 (no frequency)", mstimstr(-360));
    pstr("error", wfdberror());
    /* a header without a sampling frequency */
    f = fopen("nf.hea", "w");
    fputs("nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
	  "100s.dat 212 200 11 1024 1011 -3962 0 V5\n", f);
    fclose(f);
    printf("isigopen nf: %d\n", isigopen("nf", isi, 8));
    printf("sampfreq nf: %g\n", sampfreq(NULL));
    printf("getifreq nf: %g\n", getifreq());
    printf("setifreq 100 (nf): %d\n", setifreq(100.));
    pstr("error", wfdberror());
    printf("strtim 2 (nf): %ld\n", (long)strtim("2"));
    printf("strtim e (nf): %ld\n", (long)strtim("e"));
    pstr("mstimstr 100 (nf)", mstimstr(100));
    wfdbquit();
    /* a frequency set by the caller applies */
    printf("setsampfreq 500: %d\n", setsampfreq(500.));
    printf("isigopen nf after setsampfreq: %d\n", isigopen("nf", isi, 8));
    printf("sampfreq: %g\n", sampfreq(NULL));
    printf("strtim 2: %ld\n", (long)strtim("2"));
    pstr("mstimstr 100", mstimstr(100));
    wfdbquit();
    printf("sampfreq nf (record): %g\n", sampfreq("nf"));
    wfdbquit();
    /* uncalibrated signals (record null) and invalid signal numbers */
    isigopen("null", isi, 8);
    pphys("aduphys 0 100 (uncalibrated)", aduphys(0, 100));
    pstr("error", wfdberror());
    printf("physadu 0 1.0 (uncalibrated): %d\n", physadu(0, 1.0));
    pstr("error", wfdberror());
    printf("adumuv 1 100 (uncalibrated): %d\n", adumuv(1, 100));
    printf("muvadu 1 100 (uncalibrated): %d\n", muvadu(1, 100));
    pstr("error", wfdberror());
    wfdbquit();
    isigopen("100s", isi, 8);
    pphys("aduphys 0 1124", aduphys(0, 1124));
    printf("physadu 1 -0.5: %d\n", physadu(1, -0.5));
    printf("adumuv 0 100: %d\n", adumuv(0, 100));
    printf("muvadu 0 1000: %d\n", muvadu(0, 1000));
    pphys("aduphys 5 100 (invalid signal)", aduphys(5, 100));
    pstr("error", wfdberror());
    printf("physadu 5 1.0 (invalid signal): %d\n", physadu(5, 1.0));
    printf("adumuv 2 100 (invalid signal): %d\n", adumuv(2, 100));
    printf("muvadu 2 100 (invalid signal): %d\n", muvadu(2, 100));
    pstr("error", wfdberror());
    wfdbquit();
    /* no default ADC resolution: 0 if the header does not give it */
    f = fopen("nr.hea", "w");
    fputs("nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n", f);
    fclose(f);
    printf("isigopen nr: %d\n", isigopen("nr", isi, 8));
    printf("nr adcres: %d %d\n", isi[0].adcres, isi[1].adcres);
    pstr("nr units", isi[0].units);
    wfdbquit();
    isigopen("100s", isi, 8);
    printf("100s adcres: %d %d\n", isi[0].adcres, isi[1].adcres);
    wfdbquit();
    wfdbverbose();
}

/* wfdb-x legacy mode (wfdbx_set_legacy, docs/DIVERGENCES.md): the library
   behaves as the original WFDB library, with its built-in defaults.  These
   checks repeat earlier ones (t_signals, t_extra, t_nodefaults) whose results
   differ in legacy mode; the values printed are those of the original
   library. */
static void t_legacy(void)
{
    FILE *f;

    printf("wfdbx_set_legacy 1: %d\n", wfdbx_set_legacy(1));
    printf("wfdbx_get_legacy: %d\n", wfdbx_get_legacy());
    /* amplitude conversion (gain 200, baseline 1024; invalid signal numbers:
       gain 200, baseline 0) */
    isigopen("100s", isi, 8);
    printf("legacy adumuv: %d %d %d %d %d\n", adumuv(0, 200), adumuv(0, -37),
	   adumuv(1, 1), adumuv(0, -1), adumuv(7, 100));
    printf("legacy muvadu: %d %d %d %d\n", muvadu(0, 1000), muvadu(0, -333),
	   muvadu(1, 2), muvadu(9, 1000));
    pphys("legacy aduphys 0 1224", aduphys(0, 1224));
    pphys("legacy aduphys 1 900", aduphys(1, 900));
    pphys("legacy aduphys 5 300 (invalid signal)", aduphys(5, 300));
    printf("legacy physadu: %d %d %d\n", physadu(0, 1.0), physadu(1, -0.5023),
	   physadu(5, 1.5));
    pphys("legacy aduphys 5 100 (invalid signal)", aduphys(5, 100));
    printf("legacy physadu 5 1.0 (invalid signal): %d\n", physadu(5, 1.0));
    printf("legacy adumuv 2 100 (invalid signal): %d\n", adumuv(2, 100));
    printf("legacy muvadu 2 100 (invalid signal): %d\n", muvadu(2, 100));
    wfdbquit();
    /* uncalibrated signals (record null): gain 200 */
    isigopen("null", isi, 8);
    printf("legacy null adumuv: %d %d\n", adumuv(0, 100), muvadu(1, 100));
    pphys("legacy null aduphys 0 100", aduphys(0, 100));
    printf("legacy null physadu 1 0.5: %d\n", physadu(1, 0.5));
    printf("legacy null physadu 0 1.0: %d\n", physadu(0, 1.0));
    wfdbquit();
    wfdbquiet();
    /* no input record: 1 sample per second */
    printf("legacy strtim 1:0 (no frequency): %ld\n", (long)strtim("1:0"));
    printf("legacy strtim s10 (no frequency): %ld\n", (long)strtim("s10"));
    pstr("legacy timstr 360 (no frequency)", timstr(360));
    pstr("legacy mstimstr -360 (no frequency)", mstimstr(-360));
    /* a header without a sampling frequency (nf.hea, see t_nodefaults):
       250 Hz */
    printf("legacy isigopen nf: %d\n", isigopen("nf", isi, 8));
    printf("legacy sampfreq nf: %g\n", sampfreq(NULL));
    printf("legacy getifreq nf: %g\n", getifreq());
    printf("legacy strtim 2 (nf): %ld\n", (long)strtim("2"));
    printf("legacy strtim e (nf): %ld\n", (long)strtim("e"));
    pstr("legacy mstimstr 100 (nf)", mstimstr(100));
    printf("legacy setifreq 100 (nf): %d\n", setifreq(100.));
    printf("legacy getifreq nf: %g\n", getifreq());
    wfdbquit();
    printf("legacy sampfreq nf (record): %g\n", sampfreq("nf"));
    wfdbquit();
    /* setifreq with an input record but no frequency */
    isigopen("100s", isi, 8);
    setsampfreq(0.);
    printf("legacy setifreq 100 (frequency 0): %d\n", setifreq(100.));
    pstr("error", wfdberror());
    wfdbquit();
    /* ADC resolution inferred from the format, or WFDB_DEFRES (nr.hea, see
       t_nodefaults) */
    printf("legacy isigopen nr: %d\n", isigopen("nr", isi, 8));
    printf("legacy nr adcres: %d %d\n", isi[0].adcres, isi[1].adcres);
    wfdbquit();
    f = fopen("nr3.hea", "w");
    fputs("nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\nfmt310.dat 310\n"
	  "fmt160.dat 160\nfmt24.dat 24\n", f);
    fclose(f);
    printf("legacy isigopen nr3: %d\n", isigopen("nr3", isi, 8));
    printf("legacy nr3 adcres: %d %d %d %d %d\n", isi[0].adcres,
	   isi[1].adcres, isi[2].adcres, isi[3].adcres, isi[4].adcres);
    wfdbquit();
    wfdbverbose();
    printf("wfdbx_set_legacy 0: %d\n", wfdbx_set_legacy(0));
    printf("wfdbx_get_legacy: %d\n", wfdbx_get_legacy());
}

int main(void)
{
    printf("# expected values for the wfdb-x API unit tests (from the C "
	   "WFDB library %s)\n", wfdbversion());
    t_version();
    t_path();
    t_bufsize();
    t_signals();
    t_frames();
    t_groups();
    t_segments();
    t_skew();
    t_output();
    t_info();
    t_msheader();
    t_counter();
    t_calib();
    t_annot();
    t_strings();
    t_maps();
    t_extra();
    t_flacseek();
    t_nodefaults();
    t_legacy();
    return 0;
}
