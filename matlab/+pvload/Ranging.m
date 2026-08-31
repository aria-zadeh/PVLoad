classdef Ranging

methods (Static)

function [cfg, meas] = probe(board, meas, cfg, plan)
    [cfg, meas] = probeRanges(board, meas, cfg, plan);
end

function range = pickVoltage(cfg, vocSeen)
    if nargin < 2
        range = pickVoltageRange(cfg);
    else
        range = pickVoltageRange(cfg, vocSeen);
    end
end

function range = pickCurrent(iscExpected, cfg)
    range = pickCurrentRange(iscExpected, cfg);
end

end
end

function [cfg, meas] = probeRanges(board, meas, cfg, plan)

    if ~meas.Enabled
        return
    end

    wantV = cfg.Dmm.V.Range <= 0 && cfg.Cell.VocFull <= 0;
    wantI = cfg.Dmm.I.Range <= 0 && cfg.Cell.IscFull <= 0;

    if ~wantV && ~wantI && ~cfg.Timing.Measure
        return
    end

    fprintf("\nSizing the meters from the cell:\n");

    voc = cfg.Cell.VocFull;
    isc = cfg.Cell.IscFull;

    if wantV
        Board.safeState(board);
        pause(Timing.settle(probeState("OPEN"), "", cfg));
        voc = probeRead(meas.V, "voltage", "OPEN");
        fprintf("  OPEN  %9.4f V\n", voc);
    end

    if wantI
        Board.mode(board, "SHORT");
        Board.wipers(board, 0, 0);
        pause(Timing.settle(probeState("SHORT"), "OPEN", cfg));
        isc = probeRead(meas.I, "current", "SHORT");
        fprintf("  SHORT %9.4f mA\n", 1e3 * isc);
    end

    Board.safeState(board);

    vRange = pickVoltageRange(cfg, voc);
    iRange = pickCurrentRange(isc, cfg);

    meas = Meter.setRanges(meas, vRange, iRange);

    fprintf("  ranges %g V and %g mA, 20%% above what the cell showed.\n", ...
        vRange, 1e3 * iRange);

    fraction = (voc / cfg.ROpenPath) / isc;
    if fraction > 0.05
        warning("PVLoad:OpenPointWeak", ...
            "The 470 kohm path draws %.1f%% of the short-circuit current " + ...
            "at this illumination, so the OPEN state is a floor under Voc " + ...
            "rather than Voc.", 100 * fraction);
    end

    reportKnee(plan, voc, isc);

    if cfg.Timing.Measure
        cfg = measureSettle(board, meas, cfg, plan);
    end
end

function cfg = measureSettle(board, meas, cfg, plan)

    % measured at the top of the ladder, settling being RC and R largest
    % there. Guessing low tilts the curve rather than adding noise.
    ladder = [plan.Mode] ~= "SHORT" & [plan.Mode] ~= "OPEN";
    [rTop, at] = max([plan.Resistance] .* ladder);
    tol   = 0.002;                  % 0.2%, a few counts at 6.5 digits
    limit = 5;                      % s, past which it is not settling

    Board.apply(board, plan(at), 0);

    times   = zeros(1, 256);
    reading = nan(1, 256);
    n       = 0;
    clock   = tic;

    while n < numel(times) && toc(clock) < limit
        n = n + 1;
        try
            reading(n) = Meter.readOnce(meas.I);
        catch
            reading(n) = NaN;
        end
        times(n) = toc(clock);
    end

    Board.safeState(board);

    reading = reading(1:n);
    times   = times(1:n);
    good    = ~isnan(reading);

    if sum(good) < 4
        fprintf("  settling: the ammeter would not read, keeping " + ...
            "C_LOAD at %g F.\n", cfg.Timing.CLoad);
        return
    end

    final = median(reading(good & times >= 0.75 * times(n)));
    moved = find(good & abs(reading - final) > tol * abs(final), 1, "last");

    if isempty(moved)
        fprintf("  settling: already inside %.1f%% at the first reading " + ...
            "(%.0f ms), so it\n  is faster than this can measure. " + ...
            "CELL_SETTLE stands at %g s.\n", ...
            100 * tol, 1e3 * times(1), cfg.Timing.CellSettle);
        return
    end

    settled  = times(moved);
    measured = settled / (cfg.Timing.TauCount * rTop);

    fprintf("  settling: %.0f ms to %.1f%% at %.0f ohm, %d readings.\n", ...
        1e3 * settled, 100 * tol, rTop, n);

    % settling puts its change at the front of the window and leaves the
    % tail flat; drift does not. Run 20260828_163338 read drift as 35 uF.
    third  = max(2, floor(sum(good) / 3));
    values = reading(good);
    middle = median(values(end - 2*third + 1 : end - third));
    tail   = median(values(end - third + 1 : end));

    if abs(tail - middle) > tol * abs(final)
        warning("PVLoad:CellNotSettling", ...
            "The reading at %.0f ohm was still moving %.2f%% per window " + ...
            "at the end of %.1f s, so this is drift rather than settling " + ...
            "and no capacitance is taken from it. Something is changing " + ...
            "on its own: illumination warming up is the usual one, and a " + ...
            "sweep run through it tilts, because every state is measured " + ...
            "at a different moment. CELL_SETTLE stays at %g s.", ...
            rTop, 100 * abs(tail - middle) / abs(final), times(n), ...
            cfg.Timing.CellSettle);
        return
    end

    if measured > cfg.Timing.CLoad
        fprintf("  cell capacitance %.3g F, up from the %.3g F of leads " + ...
            "and meter.\n", measured, cfg.Timing.CLoad);
        cfg.Timing.CLoad = measured;
    else
        fprintf("  settled inside the existing %.3g F allowance.\n", ...
            cfg.Timing.CLoad);
    end

    if settled >= limit - times(1)
        warning("PVLoad:SettleUnfinished", ...
            "The cell was still moving after %g s at %.0f ohm. The sweep " + ...
            "will hold every state for what that implies, which is slow, " + ...
            "and the reading may still be early.", limit, rTop);
    end
end

function reportKnee(plan, voc, isc)

    ladder = [plan.Mode] ~= "SHORT" & [plan.Mode] ~= "OPEN";
    lo     = min([plan(ladder).Resistance]);
    hi     = max([plan(ladder).Resistance]);
    rMpp   = (0.8 * voc) / (0.9 * isc);

    fprintf("  knee near %.0f ohm; the ladder covers %.0f to %.0f.\n", ...
        rMpp, lo, hi);

    if rMpp > hi
        warning("PVLoad:KneeAboveLadder", ...
            "The maximum power point of this cell wants about %.0f ohm " + ...
            "and the ladder stops at %.0f. The sweep will measure the " + ...
            "current-source plateau and stop short of the knee, and Pmax " + ...
            "will be a lower bound. About %.0f uA of short-circuit " + ...
            "current would bring the knee to the top of the ladder, " + ...
            "which is %.1fx this illumination.", ...
            rMpp, hi, 1e6 * (0.8 * voc) / (0.9 * hi), rMpp / hi);
    elseif rMpp < lo
        warning("PVLoad:KneeBelowLadder", ...
            "The maximum power point of this cell wants about %.0f ohm " + ...
            "and the ladder starts at %.0f, which is the wiper " + ...
            "resistance. Only the SHORT state sits below the knee, so the " + ...
            "sweep will start past it. Less light would bring it back.", ...
            rMpp, lo);
    end
end

function state = probeState(mode)
    state = struct('Mode', string(mode), 'Code1', 0, 'Code2', 0, ...
                   'Resistance', 0);
end

function value = probeRead(m, role, mode)

    try
        value = Meter.readOnce(m);
    catch readError
        error("PVLoad:ProbeFailed", ...
            "The %s meter (%s) could not be read at the %s state while " + ...
            "sizing its range: %s", role, m.Label, mode, readError.message);
    end

    value = abs(value);

    if isnan(value) || value <= 0
        error("PVLoad:ProbeFailed", ...
            "The %s meter (%s) returned %g at the %s state while sizing " + ...
            "its range. On autorange that is an open lead, a dark cell, " + ...
            "or a meter on the wrong function.", role, m.Label, value, mode);
    end
end

function range = pickCurrentRange(iscExpected, cfg)

    I = cfg.Dmm.I;

    if I.Range > 0
        range = I.Range;
        return
    end
    if isnan(iscExpected) || iscExpected <= 0
        range = 0;              % autorange, nothing is known yet
        return
    end

    fits = I.Ranges(I.Ranges >= 1.2 * iscExpected);
    if isempty(fits)
        range = max(I.Ranges);
    else
        range = min(fits);
    end
end

function range = pickVoltageRange(cfg, vocSeen)

    V = cfg.Dmm.V;

    if V.Range > 0
        range = V.Range;
        return
    end

    if nargin < 2
        vocSeen = cfg.Cell.VocFull;
    end
    if isnan(vocSeen) || vocSeen <= 0
        range = 0;              % autorange, nothing is known yet
        return
    end

    fits = V.Ranges(V.Ranges >= vocSeen);
    if isempty(fits)
        range = max(V.Ranges);
    else
        range = min(fits);
    end
end
