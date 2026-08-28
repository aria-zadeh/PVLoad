classdef Ranging
% Sizing the meters from the cell in front of them, before the run.
%
% OPEN is the largest voltage of the sweep and SHORT the largest current,
% and every other state is one of those two with resistance added, so two
% readings on autorange bound the whole run. ISC_FULL and VOC_FULL remain
% for pinning a range across a family of runs at different light; zero, the
% default, means measure it. The sweep itself runs on a settled range,
% because a range hunt inside a point spends conversions on the wrong one.

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
% Measures the two numbers the meters have to be sized from, instead of
% being told them.
%
% Both are endpoints the sweep visits anyway. The largest voltage of the
% run is the OPEN state, where the cell sits behind 470 kohm, and the
% largest current is the SHORT state, where it sits behind a reed contact.
% Nothing else in the sweep exceeds either, because every other state is
% one of those two with resistance added. So two readings on autorange
% bound the whole run, and the fixed ranges that follow are sized from the
% cell in front of the meters rather than from a number typed in weeks
% earlier at an illumination nobody recorded.
%
% This is what ISC_FULL and VOC_FULL used to be for. They remain, pinning
% the range when a family of runs at different light should share one, and
% a pinned range skips its half of the probe.
%
% Cost is two states and two reconfigurations, a few seconds against a
% run of minutes. Autorange is what makes it possible and is also why it
% is not used for the sweep itself: the hunt costs conversions at every
% state that changes decade, which is the whole point of settling the
% range once.

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

    % Back to OPEN before anything else happens, which is the same rule the
    % sweep runs under: a closed K2 across a lit cell is not a state to
    % leave the board in while the meters are being reconfigured.
    Board.safeState(board);

    vRange = pickVoltageRange(cfg, voc);
    iRange = pickCurrentRange(isc, cfg);

    meas = Meter.setRanges(meas, vRange, iRange);

    fprintf("  ranges %g V and %g mA, 20%% above what the cell showed.\n", ...
        vRange, 1e3 * iRange);

    % The 470 kohm path draws a current fixed by Voc while Isc scales with
    % the light, so under weak illumination the OPEN state stops being an
    % open circuit. Now measured rather than estimated, and worth saying
    % before an hour of sweeping rather than after.
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
% Watches the cell settle and sets its capacitance from what that takes,
% instead of leaving C_LOAD to stand for a junction nobody characterised.
%
% Done at the slowest state there is, the top of the ladder, because
% settling is RC and R is largest there. Reading as fast as the ammeter
% will go and finding when the readings stop moving gives a time; dividing
% it by the tau count and that resistance gives a capacitance, which the
% existing settle formula then scales correctly for every other state. One
% measurement at the worst case, not a number repeated blindly at all of
% them.
%
% This matters because guessing low does not add noise, it tilts the
% curve. An under-settled point reads a current still falling toward its
% value, the error grows with R, and R is what the sweep is ordered by, so
% the whole plateau leans. That is exactly the shape the first cell run
% showed: current climbing 5.7% from the bottom of the ladder to the top,
% which was read as the cell doing something interesting.

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

    % The value it ends at, taken from the last quarter so a slow tail
    % cannot be mistaken for the answer, then the last moment the reading
    % was still outside tolerance of it.
    final = median(reading(good & times >= 0.75 * times(n)));
    moved = find(good & abs(reading - final) > tol * abs(final), 1, "last");

    if isempty(moved)
        % Within tolerance by the first reading, which cannot resolve
        % anything faster than one conversion plus the bus. Reporting that
        % latency as a settling time would turn the meter's own speed into
        % a cell capacitance, so it reports nothing and the configured
        % allowance stands.
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

    % Settling and drift look identical over one window and mean opposite
    % things. A capacitance charges and stops; illumination that is still
    % moving never does, and reading it as capacitance is the worst
    % possible response: it holds every state for longer, which gives the
    % drift more time to move, which bends the curve further.
    %
    % Told apart by where the change sits. Settling puts it at the front
    % of the window and leaves the tail flat; drift leaves the tail moving
    % as much as the middle. Run 20260828_163338 was the second of those,
    % and it was recorded as 35 uF.
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
% Says whether the knee is inside the ladder before the sweep spends
% minutes finding out.
%
% The load sets the operating point: the cell sits where its curve crosses
% a line of slope 1/R, so the resistance that lands on the maximum power
% point is Vmp over Imp. Taking the usual 0.8 of Voc and 0.9 of Isc is
% rough, and rough is enough for the only question here, which is whether
% that resistance is inside the range of a board whose ladder spans two
% decades.
%
% This prints and warns and does nothing else. It cannot skip a state or
% choose one, which is the same rule the resistance model has always run
% under: R_AB is plus or minus 20%, the wiper is measured on one board,
% and neither is allowed to decide what gets measured. It is allowed to
% decide what the operator is told before the run.

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
% The settle a state of this mode gets, without going through the plan.
    state = struct('Mode', string(mode), 'Code1', 0, 'Code2', 0, ...
                   'Resistance', 0);
end

function value = probeRead(m, role, mode)
% One reading, and it has to arrive. A probe that quietly returned NaN
% would size the range from nothing and the whole run would inherit it.

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
% Settled once per run, before the first state, and never touched again.
% A range change costs a fresh configuration, and 769 of those would be
% absurd.
%
% Autorange exists and is not used. A range hunt inside a settled point
% spends conversions on the wrong range, and the answer it would arrive at
% is already known from ISC_FULL. That number is the operator's estimate at
% the illumination they set by hand; nothing here can see the lamp.

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
% Sizing the range from a voltage rather than naming a number keeps one
% configuration working on either meter, whose ranges do not line up: a
% 9 V Voc lands on 30 V on a 196 and 10 V on a 34401A.
%
% The voltage is whatever the caller knows. VOC_FULL when someone pinned
% it, what the OPEN state actually read when the probe measured it, and
% nothing at all before either, which asks for autorange.

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

    % No headroom, unlike the ammeter. The OPEN state is the highest
    % voltage the sweep reaches, so the measurement is already the maximum,
    % and rounding a 9 V cell up past the 10 V range would cost the
    % 34401A's high impedance input, which exists only below that.
    fits = V.Ranges(V.Ranges >= vocSeen);
    if isempty(fits)
        range = max(V.Ranges);
    else
        range = min(fits);
    end
end
