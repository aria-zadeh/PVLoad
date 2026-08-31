classdef Util

methods (Static)

function out = ternary(condition, a, b)
    if condition
        out = a;
    else
        out = b;
    end
end

function quietly(fn)
    try
        fn();
    catch
    end
end

end
end
