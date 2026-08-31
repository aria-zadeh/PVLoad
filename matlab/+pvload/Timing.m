classdef Timing

methods (Static)

function s = settle(state, prevMode, cfg)
    s = settleFor(state, prevMode, cfg);
end

function t = perPoint(cfg, plan)
    t = estimatePointTime(cfg, plan);
end

end
end

function settle = settleFor(state, prevMode, cfg)

    % the conversion is left out on purpose: the reply blocks for it anyway
    T = cfg.Timing;
    if state.Mode == prevMode
        tSwitch = T.WiperSettle;
    else
        tSwitch = T.RelaySettle;
    end

    settle = max(T.RelaySettle, ...
        T.Safety * (tSwitch + T.TauCount * state.Resistance * T.CLoad + ...
                    T.CellSettle));

    settle = min(settle, settleCap(cfg));
end

function cap = settleCap(cfg)

    % the conversion is left out on purpose: the reply blocks for it anyway
    T = cfg.Timing;
    cap = T.Budget - T.Overhead - conversionTime(cfg);
    cap = max(T.RelaySettle, cap);
end

function reading = conversionTime(cfg)

    if ~cfg.Dmm.Enabled
        reading = 0;
    elseif cfg.Dmm.Parallel
        reading = max(cfg.Dmm.V.Conversion, cfg.Dmm.I.Conversion);
    else
        reading = cfg.Dmm.V.Conversion + cfg.Dmm.I.Conversion;
    end
end

function t = estimatePointTime(cfg, plan)

    holds = zeros(numel(plan), 1);
    prev  = "";
    for k = 1:numel(plan)
        holds(k) = settleFor(plan(k), prev, cfg);
        prev = plan(k).Mode;
    end
    t = mean(holds);

    if cfg.Dmm.Enabled
        t = t + conversionTime(cfg) + cfg.Timing.Overhead;
    end
end
