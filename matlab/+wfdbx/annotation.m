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

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h, which
% defines the structure; revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin < 1
    n = 1;
end
s = struct('time', 0, 'anntyp', 0, 'subtyp', 0, 'chan', 0, 'num', 0, ...
    'aux', []);
a = repmat(s, 1, n);
end
