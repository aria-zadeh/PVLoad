classdef Plan

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

    states = enumerateStates(cfg);

    resistances = [states.Resistance];
    [~, order]  = sort(resistances);      % sort is stable, so on a tie the
    plan        = states(order);          % earlier-listed mode wins
end

function master = buildMasterPlan(cfg)

    cfg.CodeStep = 1;
    master = buildSweepPlan(cfg);
end

function idx = coarseIndices(master, cfg)

    step = cfg.Adapt.CoarseStep;
    mode = [master.Mode];
    total = [master.Code1] + [master.Code2];

    keep = mode == "SHORT" | mode == "OPEN" | mod(total, step) == 0;
    idx  = find(keep);
end

function states = enumerateStates(cfg)

    % LOW before FULL so a resistance tie takes the state with one
    % less wiper in the path
    step   = cfg.RabNominal / cfg.WiperSteps;
    states = makeState("", 0, 0, 0);
    states(:) = [];                       % empty struct array of the right shape

    states(end+1) = makeState("SHORT", 0, 0, cfg.RContact);

    for n1 = 0:cfg.CodeStep:cfg.WiperSteps
        r = cfg.RWiper + cfg.RContact + n1 * step;
        states(end+1) = makeState("LOW", n1, 0, r);  %#ok<AGROW>
    end

    for total = 0:cfg.CodeStep:(2 * cfg.WiperSteps)
        [n1, n2] = splitCode(total, cfg.WiperSteps);
        r = 2 * cfg.RWiper + total * step;
        states(end+1) = makeState("FULL", n1, n2, r);  %#ok<AGROW>
    end

    r = cfg.ROpenPath + 2 * cfg.RWiper;
    states(end+1) = makeState("OPEN", 0, 0, r);
end

function [n1, n2] = splitCode(total, maxCode)
    n1 = min(total, maxCode);
    n2 = total - n1;
end

function state = makeState(mode, code1, code2, resistance)
    state = struct('Mode', mode, 'Code1', code1, 'Code2', code2, ...
                   'Resistance', resistance);
end

function k = findState(plan, mode, code, cfg)

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
