function a = annotation(n)
%ANNOTATION A WFDB_Annotation structure.
%   A = wfdbx.annotation() returns a structure with the fields of the C
%   WFDB_Annotation structure, all zero:
%
%     time    0    time of the annotation (sample number)
%     anntyp  0    annotation code (wfdbx.NORMAL(), ...)
%     subtyp  0    subtype
%     chan    0    channel number
%     num     0    annotator number
%     aux     []   auxiliary data: [] (NULL), or a uint8 row vector whose
%                  first element is the number of bytes that follow (as in
%                  C, where aux[0] is the length)
%
%   A = wfdbx.annotation(N) returns a 1-by-N array of such structures.
%
%   See also wfdbx.getann, wfdbx.putann.
%
%   Translation of the C structure WFDB_Annotation (lib/wfdb.h, WFDB
%   10.7.0): same fields.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    n = 1;
end
s = struct('time', 0, 'anntyp', 0, 'subtyp', 0, 'chan', 0, 'num', 0, ...
    'aux', []);
a = repmat(s, 1, n);
end
