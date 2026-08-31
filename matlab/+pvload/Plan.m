classdef Plan
% Which load states exist and in what order.
%
% The resistance model orders and labels; it never decides membership.
% Uniqueness is structural: one state per LOW code, one per FULL code-sum,
% one SHORT, one OPEN, 769 in all. To shorten a fixed sweep raise
% CODE_STEP, which skips codes deliberately rather than inferring which are
% redundant. The LOW and FULL ladders overlap and that overlap is kept:
% they are offset by a wiper resistance the datasheet does not characterise
% at a 24 V span, so the duplicates were never confirmed to be duplicates.

methods (Static)

function plan = build(cfg)
    plan = buildSweepPlan(cfg);
end

function p = master(cfg)
    p = buildMasterPlan(cfg);
end

function idx = coarse(master, cfg)
    idx = coarseIndices(master, cfg);
end

function k = stateIndex(plan, mode, code, cfg)
    k = findState(plan, mode, code, cfg);
end

end
end


function plan = buildSweepPlan(cfg)
% Every state the board can produce, ordered by the resistance model.
% That model orders and labels only, it never decides what gets measured.
% Uniqueness is structural: one state per LOW code, one per FULL code-sum,
% one SHORT, one OPEN. 769 total.

    states = enumerateStates(cfg);

    resistances = [states.Resistance];
    [~, order]  = sort(resistances);      % sort is stable, so on a tie the
    plan        = states(order);          % earlier-listed mode wins
end

function master = buildMasterPlan(cfg)
% Every state the board can make, whatever CODE_STEP says. The adaptive
% sweep thins for itself and refines into the gaps, so it needs the full
% 769 to choose from.

    cfg.CodeStep = 1;
    master = buildSweepPlan(cfg);
end

function idx = coarseIndices(master, cfg)
% The states the adaptive coarse pass measures: the thinning CODE_STEP
% does, by wiper code and never by resistance, plus both endpoints.

    step = cfg.Adapt.CoarseStep;
    mode = [master.Mode];
    total = [master.Code1] + [master.Code2];

    keep = mode == "SHORT" | mode == "OPEN" | mod(total, step) == 0;
    idx  = find(keep);
end

function states = enumerateStates(cfg)
% LOW is listed before FULL so a resistance tie visits the LOW state first,
% putting one fewer wiper resistance in the path.

    step   = cfg.RabNominal / cfg.WiperSteps;
    states = makeState("", 0, 0, 0);
    states(:) = [];                       % empty struct array of the right shape

    states(end+1) = makeState("SHORT", 0, 0, cfg.RContact);

    % LOW: U2 bypassed by K3, so only U1 is in the path.
    for n1 = 0:cfg.CodeStep:cfg.WiperSteps
        r = cfg.RWiper + cfg.RContact + n1 * step;
        states(end+1) = makeState("LOW", n1, 0, r);  %#ok<AGROW>
    end

    % FULL: both pots in series. Sweep the combined code and split it.
    for total = 0:cfg.CodeStep:(2 * cfg.WiperSteps)
        [n1, n2] = splitCode(total, cfg.WiperSteps);
        r = 2 * cfg.RWiper + total * step;
        states(end+1) = makeState("FULL", n1, n2, r);  %#ok<AGROW>
    end

    r = cfg.ROpenPath + 2 * cfg.RWiper;
    states(end+1) = makeState("OPEN", 0, 0, r);
end

function [n1, n2] = splitCode(total, maxCode)
% Any split with the right sum is the same circuit, so U1 fills first.
    n1 = min(total, maxCode);
    n2 = total - n1;
end

function state = makeState(mode, code1, code2, resistance)
    state = struct('Mode', mode, 'Code1', code1, 'Code2', code2, ...
                   'Resistance', resistance);
end


%% =====================================================================
%  Validation and planning
%  =====================================================================

function k = findState(plan, mode, code, cfg)
% Pulled out of the plan rather than rebuilt, so this mode cannot drift
% away from the resistance model the sweep uses.

    switch mode
        case "SHORT"
            k = find([plan.Mode] == "SHORT", 1);
        case "LOW"
            k = find([plan.Mode] == "LOW" & [plan.Code1] == code, 1);
        case "FULL"
            k = find([plan.Mode] == "FULL" & ...
                     ([plan.Code1] + [plan.Code2]) == code, 1);
    end

    if isempty(k)
        error("PVLoad:StateNotInPlan", ...
            "%s at code %d is not in the sweep. CODE_STEP is %g and " + ...
            "has to leave that state in.", mode, code, cfg.CodeStep);
    end
end
