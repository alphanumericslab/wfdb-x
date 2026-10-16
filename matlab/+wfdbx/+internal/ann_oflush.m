function oa = ann_oflush(oa)
%ANN_OFLUSH Write the buffered bytes of an output annotator to its file.
%   OA = wfdbx.internal.ann_oflush(OA) writes the bytes buffered by
%   wfdbx.putann for the output annotator structure OA (fields obuf,
%   olen) with OA.file.write, and empties the buffer.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if oa.olen > 0
    oa.file.write(oa.obuf(1:oa.olen));
    oa.olen = 0;
end
end
