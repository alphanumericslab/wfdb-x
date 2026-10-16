"""Tests of time and date conversion (values checked against WFDB 10.7.0).

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import wfdbx as w


def test_interval_strings(datadir):
    assert w.isigopen("100s", None, 0) == 2
    assert w.strtim("1:0") == 21600
    assert w.timstr(21600) == "    1:00"
    assert w.mstimstr(1234) == "    0:03.428"
    assert w.strtim("s7") == 7
    assert w.strtim("e") == 21600


def test_absolute_times(datadir):
    w.isigopen("fmt16", None, 0)
    assert w.timstr(0) == "[12:34:56 31/12/1999]"
    assert w.strtim("[12:35:00]") == -803
    assert w.mstimstr(-2500) == "[12:35:06.789 31/12/1999]"


def test_dates():
    for d in ["01/01/2000", "29/02/2000", "15/10/1582", "31/12/1999"]:
        assert w.datstr(w.strdat(d)) == " " + d
    # 29 February 1900 does not exist (Gregorian calendar)
    assert w.datstr(w.strdat("29/02/1900")) == " 01/03/1900"
    assert w.strdat("bogus") == 0
