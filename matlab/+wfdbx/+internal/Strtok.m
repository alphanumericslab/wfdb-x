classdef Strtok < handle
%STRTOK Emulation of the stateful C function strtok() over one string.
%   T = wfdbx.internal.Strtok(S) prepares to split the char vector S.
%   TOK = T.next(DELIMS) corresponds to the first call strtok(S, DELIMS);
%   each further call of T.next(DELIMS) corresponds to strtok(NULL, DELIMS).
%   TOK is a char vector, or [] (C NULL) when no token remains.  As in C,
%   leading delimiters are skipped, and the single delimiter that ends a
%   token is consumed, so that the next call with other delimiters starts
%   just after it.  T.rest() returns the unparsed remainder of S (or []).
%
%   Delimiters are given as a char vector of the actual characters, e.g.
%   sprintf(' \t\n\r') or char([32 9 10 13]) -- not ' \t\n\r', which in
%   MATLAB is a string of backslashes and letters.
%
%   Example:
%       t = wfdbx.internal.Strtok(sprintf('x 0 MLII lead\r\n'));
%       t.next(' '); t.next(' ');
%       desc = t.next(sprintf('\r\n'))      % 'MLII lead'

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        s       % the string being split
        pos     % index of the next character to scan; 0 when exhausted
    end

    methods
        function obj = Strtok(s)
            obj.s = s;
            obj.pos = 1;
        end

        function tok = next(obj, delims)
            %NEXT Return the next token (strtok(NULL, DELIMS)), or [].
            i = obj.pos;
            if i == 0
                tok = [];
                return;
            end
            s = obj.s;
            n = numel(s);
            if i > n
                obj.pos = 0;
                tok = [];
                return;
            end
            isd = false(1, 256);
            isd(double(delims) + 1) = true;
            m = isd(double(s(i:n)) + 1);
            k = find(~m, 1);
            if isempty(k)
                obj.pos = 0;
                tok = [];
                return;
            end
            i = i + k - 1;
            k = find(m(k:end), 1);
            if isempty(k)
                tok = s(i:n);
                obj.pos = 0;
            else
                j = i + k - 1;          % index of the ending delimiter
                tok = s(i:j-1);
                obj.pos = j + 1;
            end
        end

        function r = rest(obj)
            %REST The part of the string not yet parsed, or [].
            if obj.pos == 0
                r = [];
            else
                r = obj.s(obj.pos:end);
            end
        end
    end
end
