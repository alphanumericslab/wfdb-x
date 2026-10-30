/* bench.c: benchmark driver for the original C WFDB library (10.7.0)
 *
 * Usage: wfdb_c_bench OP DATADIR REPS
 *
 * The same operations as the WFDB-x drivers (see benchmarks/README.md),
 * written with the functions of the C library: isigopen and getvec to read
 * records, aduphys for physical units, osigfopen, putvec and newheader to
 * write them, annopen, getann and putann for annotation files.  The output
 * is the same JSON line, and WFDBX_BENCH_DUMP saves the same files, so that
 * the runner checks that the C library read and wrote exactly what WFDB-x
 * did.  Build it against the unmodified package (benchmarks/c/build.sh).
 *
 * This file is part of WFDB-x, an independent reimplementation of the WFDB
 * Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
 * It has no counterpart in the original package.
 *
 * Copyright (C) 2026 Reza Sameni.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version. See LICENSE.
 */

#include <wfdb/wfdb.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAXSIG 32           /* more than the benchmark records have */

/* The result of one call. */
struct result {
    int nsig;
    long nframes;
    WFDB_Sample *v;         /* nframes * nsig samples, frame by frame */
    double *phys;           /* the same, in physical units (read_long_phys) */
    long nann;
    WFDB_Annotation *ann;   /* annotations, with copies of their aux strings */
    double check;
};

/* The annotations of long.atr, read before the timed calls of write_ann. */
static WFDB_Annotation *src_ann;
static long src_nann;
/* The record long, read before the timed calls of write_long. */
static struct result src_rec;
static WFDB_Siginfo src_si[MAXSIG];
static WFDB_Frequency src_fs;

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void *xmalloc(size_t n)
{
    void *p = malloc(n ? n : 1);
    if (!p) {
        fprintf(stderr, "wfdb_c_bench: out of memory\n");
        exit(1);
    }
    return p;
}

static void free_result(struct result *r)
{
    long i;
    free(r->v);
    free(r->phys);
    for (i = 0; i < r->nann; i++)
        free(r->ann[i].aux);
    free(r->ann);
    memset(r, 0, sizeof *r);
}

/* Read a whole record with getvec (WFDB_LOWRES: one value per signal and
   frame, the default of the C library and of WFDB-x's read_record). */
static void read_rec(const char *name, struct result *r, WFDB_Siginfo *si)
{
    WFDB_Sample frame[MAXSIG];
    long cap;
    int nsig = isigopen((char *)name, si, MAXSIG);

    if (nsig < 1) {
        fprintf(stderr, "wfdb_c_bench: can't open %s\n", name);
        exit(1);
    }
    r->nsig = nsig;
    cap = si[0].nsamp > 0 ? si[0].nsamp : 1024;
    r->v = xmalloc(cap * nsig * sizeof *r->v);
    r->nframes = 0;
    while (getvec(frame) == nsig) {
        if (r->nframes == cap) {
            cap *= 2;
            r->v = realloc(r->v, cap * nsig * sizeof *r->v);
            if (!r->v) {
                fprintf(stderr, "wfdb_c_bench: out of memory\n");
                exit(1);
            }
        }
        memcpy(r->v + r->nframes * nsig, frame, nsig * sizeof *frame);
        r->nframes++;
    }
}

static void op_read(const char *name, struct result *r)
{
    WFDB_Siginfo si[MAXSIG];
    read_rec(name, r, si);
    wfdbquit();
}

static void op_read_phys(struct result *r)
{
    WFDB_Siginfo si[MAXSIG];
    long i, n;
    int s;

    read_rec("long", r, si);
    n = r->nframes;
    r->phys = xmalloc(n * r->nsig * sizeof *r->phys);
    for (i = 0; i < n; i++)
        for (s = 0; s < r->nsig; s++) {
            WFDB_Sample x = r->v[i * r->nsig + s];
            r->phys[i * r->nsig + s] =
                x == WFDB_INVALID_SAMPLE ? NAN : aduphys(s, x);
        }
    wfdbquit();
}

/* Write the samples of long as the record out, in format 16 (the header
   that WFDB-x's write_record writes: gains and units of long, ADC
   resolution 16, no descriptions). */
static void op_write_long(void)
{
    WFDB_Siginfo so[MAXSIG];
    long i;
    int s, nsig = src_rec.nsig;

    for (s = 0; s < nsig; s++) {
        memset(&so[s], 0, sizeof so[s]);
        so[s].fname = "out.dat";
        so[s].desc = "";
        so[s].units = src_si[s].units;
        so[s].gain = src_si[s].gain;
        so[s].fmt = 16;
        so[s].spf = 1;
        so[s].adcres = 16;
        so[s].group = 0;
    }
    setsampfreq(src_fs);
    if (osigfopen(so, nsig) != nsig) {
        fprintf(stderr, "wfdb_c_bench: can't create out.dat\n");
        exit(1);
    }
    for (i = 0; i < src_rec.nframes; i++)
        putvec(src_rec.v + i * nsig);
    newheader("out");
    wfdbquit();
}

static WFDB_Annotation *read_ann(long *n)
{
    WFDB_Anninfo ai;
    WFDB_Annotation a, *v;
    long cap = 1024;

    ai.name = "atr";
    ai.stat = WFDB_READ;
    if (annopen("long", &ai, 1) < 0) {
        fprintf(stderr, "wfdb_c_bench: can't open long.atr\n");
        exit(1);
    }
    v = xmalloc(cap * sizeof *v);
    *n = 0;
    while (getann(0, &a) == 0) {
        if (*n == cap) {
            cap *= 2;
            v = realloc(v, cap * sizeof *v);
            if (!v) {
                fprintf(stderr, "wfdb_c_bench: out of memory\n");
                exit(1);
            }
        }
        if (a.aux) {
            /* (the aux string of an annotation is valid only until the
               next getann: keep a copy, length byte included) */
            unsigned char *p = xmalloc(a.aux[0] + 2);
            memcpy(p, a.aux, a.aux[0] + 1);
            p[a.aux[0] + 1] = 0;
            a.aux = p;
        }
        v[(*n)++] = a;
    }
    wfdbquit();
    return v;
}

static void op_write_ann(void)
{
    WFDB_Anninfo ai;
    WFDB_Annotation a;
    long i;

    ai.name = "atr";
    ai.stat = WFDB_WRITE;
    if (annopen("out", &ai, 1) < 0) {
        fprintf(stderr, "wfdb_c_bench: can't create out.atr\n");
        exit(1);
    }
    for (i = 0; i < src_nann; i++) {
        memset(&a, 0, sizeof a);
        a.time = src_ann[i].time;
        a.anntyp = src_ann[i].anntyp;
        a.aux = src_ann[i].aux;
        putann(0, &a);
    }
    wfdbquit();
}

static long file_size(const char *path)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return -1;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fclose(f);
    return n;
}

static void run(const char *op, struct result *r)
{
    if (!strcmp(op, "read_long") || !strcmp(op, "read_long_getvec"))
        op_read("long", r);
    else if (!strcmp(op, "read_long_phys"))
        op_read_phys(r);
    else if (!strcmp(op, "read_mimic"))
        op_read("mimic", r);
    else if (!strcmp(op, "read_wide"))
        op_read("wide", r);
    else if (!strcmp(op, "write_long"))
        op_write_long();
    else if (!strcmp(op, "read_ann"))
        r->ann = read_ann(&r->nann);
    else if (!strcmp(op, "write_ann"))
        op_write_ann();
}

static double check(const char *op, const struct result *r)
{
    long i, n = r->nframes * r->nsig;
    if (!strcmp(op, "read_long_phys")) {
        double s = 0;
        for (i = 0; i < n; i++)
            if (!isnan(r->phys[i]))
                s += r->phys[i];
        return round(s * 1000) / 1000;
    }
    if (!strcmp(op, "write_long"))
        return file_size("out.dat");
    if (!strcmp(op, "read_ann"))
        return r->nann;
    if (!strcmp(op, "write_ann"))
        return file_size("out.atr");
    {
        int64_t s = 0;
        for (i = 0; i < n; i++)
            s += r->v[i];
        return (double)s;
    }
}

static void put(FILE *f, const void *x, size_t n)
{
    fwrite(x, 1, n, f);         /* little-endian on the machines we run on */
}

static void copy_file(const char *from, const char *to)
{
    char buf[65536];
    size_t n;
    FILE *in = fopen(from, "rb"), *out = fopen(to, "wb");
    if (!in || !out) {
        fprintf(stderr, "wfdb_c_bench: can't copy %s\n", from);
        exit(1);
    }
    while ((n = fread(buf, 1, sizeof buf, in)) > 0)
        fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
}

/* Save the result of the first call of op as DUMP/op.* (see
   benchmarks/README.md). */
static void save(const char *op, const struct result *r, const char *dump)
{
    char p[4096];
    FILE *f;
    long i, n = r->nframes * r->nsig;

    if (!strcmp(op, "write_long")) {
        snprintf(p, sizeof p, "%s/%s.hea", dump, op);
        copy_file("out.hea", p);
        snprintf(p, sizeof p, "%s/%s.dat", dump, op);
        copy_file("out.dat", p);
        return;
    }
    if (!strcmp(op, "write_ann")) {
        snprintf(p, sizeof p, "%s/%s.atr", dump, op);
        copy_file("out.atr", p);
        return;
    }
    snprintf(p, sizeof p, "%s/%s.%s", dump, op,
             strcmp(op, "read_ann") ? "bin" : "ann");
    if (!(f = fopen(p, "wb"))) {
        fprintf(stderr, "wfdb_c_bench: can't write %s\n", p);
        exit(1);
    }
    if (!strcmp(op, "read_long_phys")) {
        put(f, r->phys, n * sizeof *r->phys);
    } else if (!strcmp(op, "read_ann")) {
        for (i = 0; i < r->nann; i++) {
            const WFDB_Annotation *a = &r->ann[i];
            int64_t t = a->time;
            int32_t x[5];
            x[0] = a->anntyp;
            x[1] = a->subtyp;
            x[2] = a->chan;
            x[3] = a->num;
            x[4] = a->aux ? a->aux[0] : -1;
            put(f, &t, sizeof t);
            put(f, x, sizeof x);
            if (a->aux)
                put(f, a->aux + 1, a->aux[0]);
        }
    } else {
        for (i = 0; i < n; i++) {
            int32_t x = r->v[i];
            put(f, &x, sizeof x);
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    static const char *ops[] = {"read_long", "read_long_getvec",
                                "read_long_phys", "read_mimic",
                                "read_wide", "write_long", "read_ann",
                                "write_ann"};
    const char *op, *dump;
    char data[4096], tmpl[] = "/tmp/wfdb-c-bench-XXXXXX";
    struct result r;
    double t, first, best = 0, value, *times;
    int i, reps, known = 0;

    if (argc != 4) {
        fprintf(stderr, "usage: %s OP DATADIR REPS\n", argv[0]);
        return 2;
    }
    op = argv[1];
    reps = atoi(argv[3]);
    for (i = 0; i < (int)(sizeof ops / sizeof *ops); i++)
        known |= !strcmp(op, ops[i]);
    if (!known || reps < 1) {
        fprintf(stderr, "%s: unknown operation %s, or REPS < 1\n", argv[0], op);
        return 2;
    }
    if (!realpath(argv[2], data) || !mkdtemp(tmpl) || chdir(tmpl)) {
        fprintf(stderr, "%s: can't use %s\n", argv[0], argv[2]);
        return 1;
    }
    /* Records are read from DATADIR only; files are written in the
       (temporary) current directory. */
    setwfdb(data);
    if (!strcmp(op, "write_long")) {
        read_rec("long", &src_rec, src_si);
        src_fs = sampfreq(NULL);
        /* (keep the units: wfdbquit frees the strings of the siginfo) */
        for (i = 0; i < src_rec.nsig; i++)
            src_si[i].units = strdup(src_si[i].units ? src_si[i].units : "mV");
        wfdbquit();
    } else if (!strcmp(op, "write_ann")) {
        src_ann = read_ann(&src_nann);
    }

    memset(&r, 0, sizeof r);
    t = now();
    run(op, &r);
    first = now() - t;
    value = check(op, &r);
    dump = getenv("WFDBX_BENCH_DUMP");
    if (dump && *dump)
        save(op, &r, dump);
    free_result(&r);

    times = xmalloc(reps * sizeof *times);
    for (i = 0; i < reps; i++) {
        memset(&r, 0, sizeof r);
        t = now();
        run(op, &r);
        times[i] = now() - t;
        free_result(&r);
        if (i == 0 || times[i] < best)
            best = times[i];
    }
    printf("{\"op\": \"%s\", \"first\": %.9g, \"best\": %.9g, \"times\": [",
           op, first, best);
    for (i = 0; i < reps; i++)
        printf("%s%.9g", i ? ", " : "", times[i]);
    printf("], \"check\": %.17g}\n", value);

    unlink("out.hea");
    unlink("out.dat");
    unlink("out.atr");
    if (chdir("/") == 0)
        rmdir(tmpl);
    return 0;
}
