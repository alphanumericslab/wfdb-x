#!/bin/sh
# wfdbx_matlab.sh: command-line driver of wfdb-x for MATLAB.
#
# Usage: wfdbx_matlab.sh TOOL [ARGUMENTS ...]
#
# Runs the wfdb-x tool TOOL (e.g. rdsamp) in MATLAB (`matlab -batch`), as the
# C program of the same name would be run, and exits with its status.
#
# * MATLAB cannot read its standard input, so the standard input is first
#   saved to a temporary file, whose name is passed to MATLAB in the
#   environment variable WFDBX_STDIN (see wfdbx.internal.stdin_bytes).
# * The arguments are passed as hexadecimal strings (decoded by
#   wfdbx.internal.hexargs), so that they arrive byte for byte.
# * MATLAB writes to its standard output as text, through its Command
#   Window (a NUL byte becomes a space, bytes above 127 are re-encoded), so
#   the tool writes the bytes of its standard output and error to temporary
#   files (WFDBX_STDOUT, WFDBX_STDERR; see wfdbx.internal.std_stream), which
#   are copied to the real ones when MATLAB exits.  MATLAB's own console
#   output (e.g. startup messages) is discarded.
# * The MATLAB command is `matlab` (in the PATH), or $WFDBX_MATLAB.
#
# Part of wfdb-x. GNU General Public License, version 2 or later (see
# LICENSE).

here=$(cd "$(dirname "$0")" && pwd) || exit 1
mdir=$(dirname "$here")
matlab=${WFDBX_MATLAB:-matlab}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/wfdbx.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' HUP INT TERM

# Save the standard input (nothing if it is a terminal).
if [ -t 0 ]; then
    : > "$tmp/stdin"
else
    cat > "$tmp/stdin"
fi
WFDBX_STDIN="$tmp/stdin"
export WFDBX_STDIN

# MATLAB char literals: quotes doubled.
quote() {
    printf '%s' "$1" | sed "s/'/''/g"
}

args=""
for a in "$@"; do
    h=$(printf '%s' "$a" | od -An -v -tx1 | tr -d ' \n')
    args="$args,'$h'"
done
args=${args#,}

cmd="cd('$(quote "$(pwd)")'); addpath('$(quote "$mdir")');"
cmd="$cmd exit(wfdbx.internal.cli_main(wfdbx.internal.hexargs({$args})));"

WFDBX_STDOUT="$tmp/stdout"
WFDBX_STDERR="$tmp/stderr"
export WFDBX_STDOUT WFDBX_STDERR
: > "$WFDBX_STDOUT"
: > "$WFDBX_STDERR"

"$matlab" -nosplash -nodesktop -batch "$cmd" > /dev/null
status=$?
cat "$WFDBX_STDOUT"
cat "$WFDBX_STDERR" >&2
exit $status
