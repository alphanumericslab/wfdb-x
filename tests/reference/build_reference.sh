#!/bin/sh
# build_reference.sh: build the original C WFDB Software Package (10.7.0,
# from third_party/wfdb-main.zip) with FLAC support, to serve as the
# reference implementation for the WFDB-x conformance tests.  The few
# deliberate divergences of WFDB-x (divergences.patch) are applied to it.
#
# Usage: tests/reference/build_reference.sh OUTPUT_DIRECTORY
#
# Requirements: a C compiler, make, unzip, and libFLAC (e.g., the Debian/Ubuntu
# packages libflac-dev, or libflac12 + headers).  If the FLAC headers are not
# installed, set FLAC_PREFIX to a directory containing include/FLAC/*.h and
# lib/libFLAC.so.
#
# Part of WFDB-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 3 or later (see LICENSE).
set -e
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=$OUT/src
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
unzip -q "$ROOT/third_party/wfdb-main.zip"
# configure takes the version number from the directory name
mv wfdb-main wfdb-10.7.0
cd wfdb-10.7.0
# Apply the deliberate divergences of WFDB-x from the C package (see
# docs/DIVERGENCES.md), unless WFDBX_ORIGINAL=1 (the unmodified package).
if [ "$WFDBX_ORIGINAL" != 1 ]; then
    patch -p1 -s <"$HERE/divergences.patch"
fi
if [ -n "$FLAC_PREFIX" ]; then
    FLACOPT="--with-flac=$FLAC_PREFIX"
else
    FLACOPT="--with-flac"
fi
./configure --prefix="$OUT" --without-netfiles $FLACOPT --without-xview \
    --static >"$OUT/configure.log" 2>&1
# Evaluate floating-point expressions as written (one rounding per
# operation): compilers that contract a*b+c into a fused multiply-add by
# default (Clang, e.g. on ARM) would change results such as edf2mit's
# baselines.  (gcc on x86-64, which produced the stored results, does not
# contract without an -march that has FMA, so this changes nothing there.)
for m in */Makefile; do
    sed -i.orig 's/^CFLAGS = /CFLAGS = -ffp-contract=off /' "$m"
done
make install >"$OUT/make.log" 2>&1
cc -O -DFLAC_RECORDS -o "$OUT/bin/gen_records" "$HERE/gen_records.c" \
    -I"$OUT/include" -L"$OUT/lib" -lwfdb \
    ${FLAC_PREFIX:+-L$FLAC_PREFIX/lib} -lFLAC
echo "C reference installed in $OUT/bin"
