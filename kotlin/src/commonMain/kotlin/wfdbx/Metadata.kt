// Header metadata: "Key: value" info strings in the header of a record
// (port of python/src/wfdbx/metadata.py).
//
// The info strings of a header are its comment lines (lines that begin with
// '#') after the record line, as the C function getinfo() reads them. Many
// datasets store facts about the recording in them as "Key: value" pairs,
// for example:
//
//     # Age: 63
//     # Sex: F
//     # Dx: 164889003
//
// | Function | What it does |
// |---|---|
// | readMetadata | all the entries, in file order, as a list of (key, value) pairs |
// | getMetadata | the value of one entry, or null |
// | setMetadata | changes the value of an entry, or adds the entry |
// | removeMetadata | removes an entry; returns the number of lines removed |
// | updateMetadata | several changes in one write (a null value removes the entry) |
//
// readHeader also returns the entries (Header.metadata), and writeRecord
// writes them (its metadata argument).
//
// Rules:
//
// * Reading. An info string is an entry if it contains a colon (':'). The
//   key is the text between the '#' and the first colon, and the value is
//   the rest of the line; spaces, tabs, VT, FF and CR at either end of each
//   are removed. So "#Age:45", "# Age: 45" and "#  Age : 45" all give
//   ("Age", "45"). An info string without a colon, or whose key is empty or
//   contains '#', is a free comment: it is not returned, and it is never
//   changed. Comment lines before the record line are not info strings,
//   and are never read or changed. Only the header file (.hea) is read,
//   not the .info file that getinfo() also reads.
// * Keys are compared without regard to letter case (A-Z and a-z only), so
//   getMetadata(record, "age") finds "Age". If a header holds two entries
//   whose keys differ only in letter case (a file written by other
//   software), reading returns the first of them, with a warning;
//   setMetadata and updateMetadata refuse to change that key, and
//   removeMetadata removes all of them. A key must not be empty, and must
//   not contain ':', '#', a line break or a NUL character; it may contain
//   spaces, as in "Date of birth".
// * Values are text, which may be a whole sentence. Spaces at either end
//   are removed; a value must not contain a line break or a NUL character.
//   The empty string is allowed. Text is one byte per character
//   (ISO-8859-1), as in the rest of the high-level API.
// * Writing. Entries are written as "# Key: value" ("# Key:" if the value
//   is empty), with the caller's spelling of the key. A changed entry
//   replaces its line, at the same position (keeping its line ending); a
//   new entry is added after the last info string (or, if the header has
//   none, after its last line that is not blank), with the line ending of
//   the record line. Every other byte of the header is kept. The new header
//   is written to a temporary file in the directory of the header, which
//   then replaces the header (keeping its permissions), so that an error
//   never leaves a partly written header. All the arguments are checked
//   before anything is written; if nothing changes (and dir is not given),
//   nothing is written.
// * Which file. The header is opened as the library opens a header
//   (wfdb_open): under the input directory, or as given if the name is an
//   absolute path, a ~ path or a URL (with network access). A header read
//   from a URL can be read but not changed. A change is written to the
//   header itself, or, with dir, to a header of the same name in the
//   directory dir, leaving the original unchanged (the signal files are not
//   copied). Only the named header is read or changed: for a multi-segment
//   record, that is the master header, unless the name of a segment is
//   given.
//
// Invalid arguments throw WfdbArgumentException; a header that cannot be
// read or written throws WfdbException. Warnings go to onWarning, or, by
// default, are printed as "WFDB-x: " + the warning on the standard error
// (unless wfdbquiet() was called), as readRecord's checksum warning.
//
// Metadata often holds information about patients. WFDB-x stores it as plain
// text, exactly as given, and does not de-identify it.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.Platform
import wfdbx.cstd.latin1

// ---------------------------------------------------------------------------
// Parsing

/** The line ending of the headers written by WFDB. */
private val DEFAULT_EOL = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte())

private const val LF: Byte = 10
private const val CR: Byte = 13
private const val HASH: Byte = 35
private const val COLON: Byte = 58

/** Whether [b] is removed from both ends of keys and values: space, tab, VT, FF or CR. */
private fun isTrim(b: Byte): Boolean = b == 32.toByte() || b == 9.toByte() || b == 11.toByte() || b == 12.toByte() || b == CR

/** [b] without the spaces, tabs, VT, FF and CR at either end. */
private fun strip(b: ByteArray): ByteArray {
    var i = 0
    var j = b.size
    while (i < j && isTrim(b[i])) i++
    while (j > i && isTrim(b[j - 1])) j--
    return if (i == 0 && j == b.size) b else b.copyOfRange(i, j)
}

/** One line of a header: its content (without the line ending) and its line ending (CR LF, LF, or empty for a last line without one). */
private class MLine(val content: ByteArray, var eol: ByteArray)

/** The lines of [data], split after each LF. */
private fun splitLines(data: ByteArray): MutableList<MLine> {
    val lines = ArrayList<MLine>()
    var start = 0
    val n = data.size
    while (start < n) {
        var i = start
        while (i < n && data[i] != LF) i++
        if (i == n) {
            lines.add(MLine(data.copyOfRange(start, n), ByteArray(0)))
            break
        }
        if (i > start && data[i - 1] == CR) {
            lines.add(MLine(data.copyOfRange(start, i - 1), DEFAULT_EOL))
        } else {
            lines.add(MLine(data.copyOfRange(start, i), byteArrayOf(LF)))
        }
        start = i + 1
    }
    return lines
}

/** [key] with the letters A-Z changed to a-z (no other byte is changed), as a string, for comparisons. */
private fun fold(key: ByteArray): String {
    val c = CharArray(key.size)
    for (i in key.indices) {
        val b = key[i].toInt() and 0xff
        c[i] = (if (b in 65..90) b + 32 else b).toChar()
    }
    return c.concatToString()
}

/** (key, value) of an info string ([content], beginning with '#'), or null if it is a free comment. */
private fun entryOf(content: ByteArray): Pair<ByteArray, ByteArray>? {
    var i = 1
    while (i < content.size && content[i] != COLON) i++
    if (i >= content.size) return null
    val key = strip(content.copyOfRange(1, i))
    if (key.isEmpty() || key.contains(HASH)) return null
    return Pair(key, strip(content.copyOfRange(i + 1, content.size)))
}

/** An entry of a header: the index of its line, its key and its value. */
private class MEntry(val line: Int, val key: ByteArray, val value: ByteArray)

/**
 * A parsed header: its lines, the index of the record line (-1 if none),
 * the indices of the info strings, and the entries in file order.
 */
private class MHeader(data: ByteArray) {
    val lines: MutableList<MLine> = splitLines(data)
    val rec: Int = lines.indexOfFirst { it.content.isEmpty() || it.content[0] != HASH }
    val info = ArrayList<Int>()
    val entries = ArrayList<MEntry>()

    init {
        if (rec >= 0) {
            for (i in rec + 1 until lines.size) {
                val c = lines[i].content
                if (c.isNotEmpty() && c[0] == HASH) {
                    info.add(i)
                    entryOf(c)?.let { entries.add(MEntry(i, it.first, it.second)) }
                }
            }
        }
    }

    /** The line indices of the entries whose key is [key], ignoring letter case. */
    fun matches(key: ByteArray): List<Int> {
        val f = fold(key)
        return entries.filter { fold(it.key) == f }.map { it.line }
    }

    /** The line ending of new lines: that of the record line, or of the first line that has one, or CR LF. */
    fun eol(): ByteArray {
        if (rec >= 0 && lines[rec].eol.isNotEmpty()) return lines[rec].eol
        for (ln in lines) if (ln.eol.isNotEmpty()) return ln.eol
        return DEFAULT_EOL
    }

    /** The index at which new entries are inserted: after the last info string, or after the last line that is not blank. */
    fun insertionPoint(): Int {
        if (info.isNotEmpty()) return info.last() + 1
        for (i in lines.size - 1 downTo 0) if (strip(lines[i].content).isNotEmpty()) return i + 1
        return lines.size
    }

    fun toBytes(): ByteArray {
        var n = 0
        for (ln in lines) n += ln.content.size + ln.eol.size
        val out = ByteArray(n)
        var p = 0
        for (ln in lines) {
            ln.content.copyInto(out, p)
            p += ln.content.size
            ln.eol.copyInto(out, p)
            p += ln.eol.size
        }
        return out
    }
}

/** The line numbers (from 1) of the line indices [idx], as "3, 7". */
private fun lineNumbers(idx: List<Int>): String = idx.joinToString(", ") { (it + 1).toString() }

/**
 * The entries of [hdr] as (key, value) byte pairs, with one entry per key
 * (the first); a warning for each key that has more than one.
 */
private fun uniqueEntries(hdr: MHeader, record: String, warn: (String) -> Unit): List<Pair<ByteArray, ByteArray>> {
    val seen = LinkedHashMap<String, Pair<ByteArray, MutableList<Int>>>()
    val out = ArrayList<Pair<ByteArray, ByteArray>>()
    for (e in hdr.entries) {
        val f = fold(e.key)
        val s = seen[f]
        if (s != null) {
            s.second.add(e.line)
            continue
        }
        seen[f] = Pair(e.key, mutableListOf(e.line))
        out.add(Pair(e.key, e.value))
    }
    for ((k, idx) in seen.values) {
        if (idx.size > 1) {
            warn("header of record $record has more than one entry for key ${k.latin1()} (lines ${lineNumbers(idx)}); the first is used")
        }
    }
    return out
}

// ---------------------------------------------------------------------------
// Arguments

private fun argError(msg: String): Nothing = throw WfdbArgumentException(msg)

/**
 * [s] as Python's repr() writes a string (for the messages, as in the
 * Python implementation): in single quotes (double quotes if it contains a
 * single quote and no double quote), with a backslash before the quote and
 * the backslash, and \t, \n, \r and \xNN for the other characters that are
 * not printable.
 */
internal fun pyRepr(s: String): String {
    val q = if (s.contains('\'') && !s.contains('"')) '"' else '\''
    val b = StringBuilder()
    b.append(q)
    for (c in s) {
        when {
            c == q || c == '\\' -> b.append('\\').append(c)
            c == '\t' -> b.append("\\t")
            c == '\n' -> b.append("\\n")
            c == '\r' -> b.append("\\r")
            c.code < 0x20 || c.code in 0x7f..0xa0 || c.code == 0xad -> b.append("\\x").append(c.code.toString(16).padStart(2, '0'))
            else -> b.append(c)
        }
    }
    b.append(q)
    return b.toString()
}

/** [s] as bytes (one byte per character); an argument error if a character is beyond U+00FF. */
private fun asBytes(s: String, what: String): ByteArray {
    if (s.any { it.code > 0xff }) argError("$what ${pyRepr(s)} has a character that is not Latin-1 (one byte per character)")
    return s.latin1()
}

/** The bytes not allowed in a key, in the order they are checked, and their names in the messages. */
private val FORBIDDEN_KEY = listOf(COLON to "':'", HASH to "'#'", CR to "a line break", LF to "a line break", 0.toByte() to "a NUL character")

/** The bytes not allowed in a value. */
private val FORBIDDEN_VALUE = listOf(CR to "a line break", LF to "a line break", 0.toByte() to "a NUL character")

/** [key] as bytes, without spaces at either end, checked. */
private fun checkKey(key: String): ByteArray {
    val k = strip(asBytes(key, "metadata key"))
    if (k.isEmpty()) argError("metadata key must not be empty")
    for ((c, name) in FORBIDDEN_KEY) if (k.contains(c)) argError("metadata key ${pyRepr(key)} must not contain $name")
    return k
}

/** [value] (of the key [key], as given) as bytes, without spaces at either end, checked. */
private fun checkValue(key: String, value: String): ByteArray {
    val v = strip(asBytes(value, "metadata value"))
    for ((c, name) in FORBIDDEN_VALUE) {
        if (v.contains(c)) argError("value of metadata key ${pyRepr(key)} must not contain $name")
    }
    return v
}

/** The info string of an entry, as written: "# Key: value" ("# Key:" for an empty value). */
private fun entryLine(key: ByteArray, value: ByteArray): ByteArray {
    val prefix = byteArrayOf(HASH, 32) + key + byteArrayOf(COLON)
    return if (value.isEmpty()) prefix else prefix + byteArrayOf(32) + value
}

/**
 * [changes] as a list of (key bytes, value bytes or null), checked: valid
 * keys and values, and no two keys that differ only in letter case.
 */
private fun checkChanges(changes: List<Pair<String, String?>>): List<Pair<ByteArray, ByteArray?>> {
    val out = ArrayList<Pair<ByteArray, ByteArray?>>()
    val seen = HashSet<String>()
    for ((key, value) in changes) {
        val k = checkKey(key)
        if (!seen.add(fold(k))) {
            argError("metadata key ${pyRepr(key)} is given more than once (keys are compared without regard to letter case)")
        }
        out.add(Pair(k, if (value == null) null else checkValue(key, value)))
    }
    return out
}

/**
 * The info strings (as putinfo takes them: without the '#') of the
 * entries of [metadata], for writeRecord: " Key: value". Throws
 * WfdbArgumentException ("writeRecord: " + the message) if an entry is
 * invalid, if two keys differ only in letter case, if a value is null, or
 * if one of [comments] (the other info strings) is already an entry for
 * one of these keys.
 */
internal fun metadataInfoLines(metadata: List<Pair<String, String?>>, comments: List<String>): List<String> {
    try {
        val entries = checkChanges(metadata)
        val folded = entries.map { fold(it.first) }.toHashSet()
        for ((k, v) in entries) {
            if (v == null) argError("value of metadata key ${pyRepr(k.latin1())} must not be null")
        }
        for (c in comments) {
            val e = entryOf(byteArrayOf(HASH) + asBytes(c, "comment")) ?: continue
            if (fold(e.first) in folded) argError("metadata key ${pyRepr(e.first.latin1())} is also given in comments")
        }
        return entries.map { (k, v) -> entryLine(k, v!!).let { it.copyOfRange(1, it.size) }.latin1() }
    } catch (e: WfdbArgumentException) {
        throw WfdbArgumentException("writeRecord: ${e.message}")
    }
}

// ---------------------------------------------------------------------------
// Files

/** The header as read: its bytes, the name of the file it was read from, and whether that is a URL. */
private class ReadHeader(val data: ByteArray, val path: ByteArray, val isUrl: Boolean)

/** The record name [record] as bytes, without a trailing ".hea", checked. */
private fun recordName(record: String): ByteArray {
    if (record.isEmpty()) argError("record name must not be empty")
    if (record == "-") argError("the metadata of a header read from the standard input cannot be read or changed")
    return wfdb_striphea(fname(record))
}

/** Reads the header of [record] as wfdb_open opens it (with the current settings). Throws WfdbException if it cannot be read. */
private fun Wfdb.readHeaderFile(record: String): ReadHeader {
    val name = recordName(record)
    val f = wfdb_open("hea".latin1(), name, WFDB_READ) ?: throw WfdbException("can't read header for record $record")
    val path = wfdb_filename().copyOf()
    val data = f.readToEnd()
    val failed = f.error()
    f.close()
    if (failed) throw WfdbException("can't read header for record $record")
    return ReadHeader(data, path, isUrl(path))
}

/** The file to which a changed header is written: the file read, or the file of the same name in [dir]. */
private fun destination(record: String, h: ReadHeader, dir: String?): ByteArray {
    if (dir == null) {
        if (h.isUrl) {
            argError("header of record $record was read from a URL, and cannot be changed (give dir to write the changed header to a local directory)")
        }
        return h.path
    }
    val d = expandHome(fname(dir))
    if (!Platform.isDirectory(d)) throw WfdbException("directory $dir does not exist")
    var s = h.path.size
    while (s > 0 && h.path[s - 1] != '/'.code.toByte() && h.path[s - 1] != '\\'.code.toByte()) s--
    val base = h.path.copyOfRange(s, h.path.size)
    if (d.isEmpty()) return base
    return if (d.last() == '/'.code.toByte()) d + base else d + byteArrayOf('/'.code.toByte()) + base
}

/**
 * The entries of the header of [record], as [readMetadata] returns them,
 * with the library's current input settings (for readHeader).
 */
internal fun Wfdb.headerMetadata(record: String, onWarning: ((String) -> Unit)?): List<Pair<String, String>> {
    val h = readHeaderFile(record)
    val warn: (String) -> Unit = onWarning ?: { wfdb_error("WFDB-x: $it\n") }
    return uniqueEntries(MHeader(h.data), record, warn).map { Pair(it.first.latin1(), it.second.latin1()) }
}

/**
 * Applies [changes] (a checked list of (key, value or null)) to the header
 * of [record]; returns the number of lines removed.
 */
private fun Wfdb.change(record: String, changes: List<Pair<ByteArray, ByteArray?>>, inputDir: String?, network: Boolean?, dir: String?): Int {
    val h = withInput(inputDir, network) { readHeaderFile(record) }
    val dest = destination(record, h, dir)
    var hdr = MHeader(h.data)
    if (hdr.rec < 0) argError("header of record $record has no record line")
    // (every change is checked before the header is changed)
    for ((k, v) in changes) {
        val idx = hdr.matches(k)
        if (v != null && idx.size > 1) {
            argError("header of record $record has more than one entry for key ${k.latin1()} (lines ${lineNumbers(idx)}); remove them first")
        }
    }
    var removed = 0
    for ((k, v) in changes) {
        val idx = hdr.matches(k)
        if (v == null) {
            for (i in idx.sortedDescending()) {
                hdr.lines.removeAt(i)
                hdr = MHeader(hdr.toBytes())
            }
            removed += idx.size
        } else if (idx.isNotEmpty()) {
            hdr.lines[idx[0]] = MLine(entryLine(k, v), hdr.lines[idx[0]].eol)
            hdr = MHeader(hdr.toBytes())
        } else {
            val eol = hdr.eol()
            val at = hdr.insertionPoint()
            if (at > 0 && hdr.lines[at - 1].eol.isEmpty()) hdr.lines[at - 1].eol = eol
            hdr.lines.add(at, MLine(entryLine(k, v), eol))
            hdr = MHeader(hdr.toBytes())
        }
    }
    val out = hdr.toBytes()
    if (!out.contentEquals(h.data) || dir != null) {
        if (!Platform.replaceFile(dest, out)) throw WfdbException("can't write header for record $record")
    }
    return removed
}

// ---------------------------------------------------------------------------
// The public functions

/**
 * Reads the metadata of a record: the "Key: value" entries of its header.
 *
 * An entry is an info string (a comment line after the record line, as
 * getinfo() reads it) that contains a colon; the key is the text before
 * the first colon and the value the rest of the line, both without spaces
 * at either end, so "#Age:45", "# Age: 45" and "#  Age : 45" all give
 * ("Age", "45"). Info strings without a colon are free comments, which are
 * not returned. Only the .hea file is read, not a .info file. Text is one
 * character per byte (ISO-8859-1).
 *
 * Metadata often holds information about patients; WFDB-x reads it as
 * stored, and does not de-identify it.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name, without the .hea extension (a trailing ".hea"
 *   is also accepted): a full path, absolute ("/data/mitdb/100") or in the
 *   home directory ("~/Documents/100s"), used as given; a relative path
 *   ("100s", "data/100s"), read from the input directory if one is set,
 *   otherwise from the current directory; or a URL
 *   ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
 *   access is on
 * @param onWarning receives the warnings (without the "WFDB-x: " prefix
 *   and the newline); null: the library prints "WFDB-x: " + the warning on
 *   the standard error, unless [wfdbquiet] was called
 * @param inputDir input directory for this call only (optional): a local
 *   directory, a `~` path or a URL, under which relative record names are
 *   read. It does not apply to full paths or URLs. null: the current
 *   setting (see [wfdbxSetInputDir])
 * @param network network access for this call only (null: the current
 *   setting, see [wfdbxSetNetwork])
 * @return the (key, value) pairs, in file order. A key that appears more
 *   than once (ignoring letter case) is returned once, with its first
 *   value, and a warning is issued: "header of record REC has more than
 *   one entry for key KEY (lines 3, 7); the first is used"
 * @throws WfdbException if the header cannot be found or read ("can't read
 *   header for record REC")
 * @throws WfdbArgumentException if [record] is empty or "-" (the standard
 *   input)
 *
 * ```
 * readMetadata("rec")     // [(Age, 63), (Sex, F)]
 * ```
 */
fun Wfdb.readMetadata(
    record: String,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
): List<Pair<String, String>> = withInput(inputDir, network) { headerMetadata(record, onWarning) }

/**
 * Returns the value of one metadata entry of a record, or null.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name (see [readMetadata])
 * @param key the key, such as "Age". Letter case is ignored (A-Z and a-z
 *   only), and spaces at either end are removed.
 * @param onWarning as for [readMetadata]
 * @param inputDir as for [readMetadata]
 * @param network as for [readMetadata]
 * @return the value ("" for an entry with an empty value), or null if the
 *   header has no entry for [key]. If it has more than one, the first is
 *   returned, with a warning.
 * @throws WfdbException if the header cannot be found or read
 * @throws WfdbArgumentException if [record] is empty or "-", or if [key]
 *   is not a valid key (see [setMetadata]); the key is checked before the
 *   header is read
 *
 * ```
 * val age = getMetadata("rec", "age")     // "63"
 * ```
 */
fun Wfdb.getMetadata(
    record: String,
    key: String,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
): String? {
    val f = fold(checkKey(key))
    for ((k, v) in readMetadata(record, onWarning, inputDir, network)) {
        if (fold(k.latin1()) == f) return v
    }
    return null
}

/**
 * Sets the value of a metadata entry in the header of a record.
 *
 * If the header has an entry for [key] (ignoring letter case), its line is
 * replaced by "# Key: value" ("# Key:" for an empty value), at the same
 * position and with the same line ending, with the spelling of [key] given
 * here (even if the value is the same). Otherwise the entry is added after
 * the last info string of the header (or, if it has none, after its last
 * line that is not blank), ending as the record line ends. Every other
 * byte of the header is kept.
 *
 * The header is replaced in one step: the new header is written to a
 * temporary file in the same directory, which then replaces it (keeping
 * its permissions), so that an error leaves it unchanged. All the
 * arguments are checked before anything is written.
 *
 * Metadata often holds information about patients; WFDB-x writes it as
 * given, and does not de-identify it.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record record name (see [readMetadata]). The header is changed
 *   where it was read, unless [dir] is given; a header read from a URL can
 *   only be written elsewhere, with [dir].
 * @param key the key, such as "Age" or "Date of birth". Spaces, tabs, VT,
 *   FF and CR at either end are removed. It must not be empty, and must
 *   not contain ':', '#', a line break or a NUL character.
 * @param value the value, which may be a sentence. Spaces at either end
 *   are removed. It must not contain a line break or a NUL character; it
 *   may be empty.
 * @param inputDir input directory for reading the header, for this call
 *   only (see [readMetadata])
 * @param network network access for reading the header, for this call
 *   only (see [readMetadata])
 * @param dir directory (which must exist) in which to write the changed
 *   header, under the same file name, instead of changing the header
 *   itself (the header is then written even if nothing changes). The
 *   signal files are not copied.
 * @throws WfdbArgumentException if [key] or [value] is not valid ("metadata
 *   key 'a:b' must not contain ':'", "value of metadata key 'Age' must not
 *   contain a line break", ...), if the header has more than one entry for
 *   [key] ("header of record REC has more than one entry for key KEY
 *   (lines 3, 7); remove them first"), if it has no record line, if it was
 *   read from a URL and [dir] is not given, or if [record] is empty or "-"
 * @throws WfdbException if the header cannot be read ("can't read header
 *   for record REC"), if [dir] does not exist ("directory DIR does not
 *   exist"), or if the changed header cannot be written ("can't write
 *   header for record REC")
 *
 * ```
 * setMetadata("rec", "Age", "63")     // writes "# Age: 63"
 * ```
 */
fun Wfdb.setMetadata(
    record: String,
    key: String,
    value: String,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) {
    val k = checkKey(key)
    change(record, listOf(Pair(k, checkValue(key, value))), inputDir, network, dir)
}

/**
 * Removes a metadata entry from the header of a record.
 *
 * Every entry for [key] (ignoring letter case) is removed, with its line
 * ending, so this also repairs a header that has more than one. Other
 * lines are kept, byte for byte. Nothing is written if the header has no
 * entry for key (unless [dir] is given).
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record as for [setMetadata]
 * @param key the key (see [setMetadata])
 * @param inputDir as for [setMetadata]
 * @param network as for [setMetadata]
 * @param dir as for [setMetadata]
 * @return the number of lines removed (0 if the header has no entry for
 *   key)
 * @throws WfdbArgumentException as [setMetadata]
 * @throws WfdbException as [setMetadata]
 *
 * ```
 * removeMetadata("rec", "Age")     // 1
 * ```
 */
fun Wfdb.removeMetadata(
    record: String,
    key: String,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
): Int = change(record, listOf(Pair(checkKey(key), null)), inputDir, network, dir)

/**
 * Makes several changes to the metadata of a record in one write.
 *
 * Each change is applied in the order given, as [setMetadata] does, or, if
 * its value is null, as [removeMetadata] does. All the changes are checked
 * first: if one is not valid, none is made.
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * @param record as for [setMetadata]
 * @param changes (key, value) pairs; a null value removes the entry. No two
 *   keys may differ only in letter case ("metadata key 'AGE' is given more
 *   than once (keys are compared without regard to letter case)").
 * @param inputDir as for [setMetadata]
 * @param network as for [setMetadata]
 * @param dir as for [setMetadata]
 * @throws WfdbArgumentException as [setMetadata]
 * @throws WfdbException as [setMetadata]
 *
 * ```
 * updateMetadata("rec", listOf("Age" to "64", "Dx" to null))
 * ```
 */
fun Wfdb.updateMetadata(
    record: String,
    changes: List<Pair<String, String?>>,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) {
    change(record, checkChanges(changes), inputDir, network, dir)
}

/**
 * [updateMetadata] with the changes as a map from key to value (null
 * removes the entry), applied in the iteration order of the map (the
 * order of insertion for the maps of `mapOf` and `linkedMapOf`).
 *
 * Part of WFDB-x; not in the original WFDB package.
 *
 * ```
 * updateMetadata("rec", mapOf("Age" to "64", "Dx" to null))
 * ```
 */
fun Wfdb.updateMetadata(
    record: String,
    changes: Map<String, String?>,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) = updateMetadata(record, changes.toList(), inputDir, network, dir)

// ---------------------------------------------------------------------------
// On the default instance

/** [Wfdb.readMetadata] on the default instance of the thread. */
fun readMetadata(
    record: String,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
): List<Pair<String, String>> = wfdbDefault().readMetadata(record, onWarning, inputDir, network)

/** [Wfdb.getMetadata] on the default instance of the thread. */
fun getMetadata(
    record: String,
    key: String,
    onWarning: ((String) -> Unit)? = null,
    inputDir: String? = null,
    network: Boolean? = null,
): String? = wfdbDefault().getMetadata(record, key, onWarning, inputDir, network)

/** [Wfdb.setMetadata] on the default instance of the thread. */
fun setMetadata(
    record: String,
    key: String,
    value: String,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) = wfdbDefault().setMetadata(record, key, value, inputDir, network, dir)

/** [Wfdb.removeMetadata] on the default instance of the thread. */
fun removeMetadata(
    record: String,
    key: String,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
): Int = wfdbDefault().removeMetadata(record, key, inputDir, network, dir)

/** [Wfdb.updateMetadata] (a list of pairs) on the default instance of the thread. */
fun updateMetadata(
    record: String,
    changes: List<Pair<String, String?>>,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) = wfdbDefault().updateMetadata(record, changes, inputDir, network, dir)

/** [Wfdb.updateMetadata] (a map) on the default instance of the thread. */
fun updateMetadata(
    record: String,
    changes: Map<String, String?>,
    inputDir: String? = null,
    network: Boolean? = null,
    dir: String? = null,
) = wfdbDefault().updateMetadata(record, changes, inputDir, network, dir)
