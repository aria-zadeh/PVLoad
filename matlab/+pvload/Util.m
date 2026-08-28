classdef Util
% Two helpers with no home of their own.

methods (Static)

function out = ternary(condition, a, b)
    if condition
        out = a;
    else
        out = b;
    end
end

function quietly(fn)
% Swallows whatever a teardown step throws, so a second failure cannot hide
% the first.
    try
        fn();
    catch
    end
end

end
end
