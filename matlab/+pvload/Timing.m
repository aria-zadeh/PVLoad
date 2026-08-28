classdef Timing
% How long a state is held, and what a point is expected to cost.
%
% The meter's integration window is deliberately absent from the hold:
% the trigger goes out after the pause and the reply blocks for it, so
% counting it here would only slow the sweep. POINT_BUDGET caps the hold
% and never the conversion, so a point that overruns because a meter
% re-ranged still finishes and still lands in the CSV.

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
% The meter's integration window is deliberately absent: READ? blocks for
% it after this pause, so counting it here would only slow the sweep.

    if ~cfg.Dmm.Enabled
        settle = cfg.SettleTime;
        return
    end

    T = cfg.Timing;
    if state.Mode == prevMode
        tSwitch = T.WiperSettle;
    else
        tSwitch = T.RelaySettle;
    end

    settle = max(T.RelaySettle, ...
        T.Safety * (tSwitch + T.TauCount * state.Resistance * T.CLoad + ...
                    T.CellSettle));

    % Capped by what is left of the budget once the conversion and the
    % board have taken their share, so the ceiling is on the state and not
    % merely on the pause inside it. Run time is a decision; the settle
    % formula is only an estimate, and the longer the sweep the further
    % anything drifting has moved by the end of it.
    settle = min(settle, settleCap(cfg));
end

function cap = settleCap(cfg)
% What the hold may be if the state is to fit the budget. Never below the
% relay settle, which is a hardware minimum.
%
% This shortens waiting and nothing else: no state is skipped and no
% reading cut short. A point that overruns because a meter re-ranged still
% finishes and still lands in the CSV.

    T = cfg.Timing;
    cap = T.Budget - T.Overhead - conversionTime(cfg);
    cap = max(T.RelaySettle, cap);
end

function reading = conversionTime(cfg)
% Overlapped, the pair costs the slower of the two; one at a time it costs
% both. Two different instruments make that a real difference rather than
% a doubling.

    if ~cfg.Dmm.Enabled
        reading = 0;
    elseif cfg.Dmm.Parallel
        reading = max(cfg.Dmm.V.Conversion, cfg.Dmm.I.Conversion);
    else
        reading = cfg.Dmm.V.Conversion + cfg.Dmm.I.Conversion;
    end
end


%% =====================================================================
%  Execution
%  =====================================================================

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

%% =====================================================================
%  Board control
%  =====================================================================
