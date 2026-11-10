function hl_sample_number(t, name, fname)
%HL_SAMPLE_NUMBER Check a sample number given to a high-level reader.
%   wfdbx.internal.hl_sample_number(T, NAME, FNAME) throws an error
%   (identifier 'wfdbx:FNAME', message "FNAME: NAME ...") unless T is a
%   time string, [] (none), or a sample number: a real numeric (or
%   logical) scalar with a whole value within the range of a 64-bit
%   integer.  The messages: "NAME must be a sample number or a time
%   string" (a cell array, a structure, a vector, ...), "NAME must be a
%   whole number" (a fraction, NaN, an infinite or complex value), "NAME
%   is beyond the range of a 64-bit integer".  Used by wfdbx.read_record
%   and wfdbx.read_annotations, before anything is opened.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

id = ['wfdbx:' fname];
if ischar(t) || isa(t, 'string') || (isnumeric(t) && isempty(t))
    return;     % (a time string, or none)
end
if ~(isnumeric(t) || islogical(t)) || ~isscalar(t)
    error(id, '%s: %s must be a sample number or a time string', fname, name);
end
if ~isreal(t) || ~isfinite(double(t)) || double(t) ~= fix(double(t))
    error(id, '%s: %s must be a whole number', fname, name);
end
% (an int64 value is always within the range; a double is from -2^63 to
% 2^63 - 2^10, the largest double below 2^63)
if (isa(t, 'uint64') && t > uint64(intmax('int64'))) || ...
        (~isinteger(t) && (double(t) >= 2^63 || double(t) < -2^63))
    error(id, '%s: %s is beyond the range of a 64-bit integer', fname, name);
end
end
