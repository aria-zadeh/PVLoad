classdef Sweep
% Running the plan and recording what came back, fixed or adaptive.
%
% Sweep.execute must stay a function with its own workspace. Ctrl-C in
% MATLAB is an interrupt, not an exception: it does not run catch blocks,
% and onCleanup fires only when the workspace holding it is destroyed,
% which never happens to a script's base workspace. That guard is what
% returns the board to OPEN on an abort, so it is written fully qualified
% and nothing else may own it.
%
% The fixed and adaptive loops are kept apart rather than folded together.
% They share the shape of a state -- settle, apply, read, account, record,
% print, append -- but the adaptive one indexes a master plan, counts
% against a point cap and requeues between rounds, so a shared helper would
% need most of the loop state passed in and back out again.

methods (Static)

function results = execute(board, meas, plan, cfg, log)
    results = runExperiment(board, meas, plan, cfg, log);
end

function shutdown(board, meas, cfg)
    safeShutdown(board, meas, cfg);
end

end
end


function results = runExperiment(board, meas, plan, cfg, log)
% Has to be a function, not script-level code. Ctrl-C in MATLAB is an
% interrupt, not an exception: it does not run catch blocks. onCleanup is
% the only thing that fires, and only when the workspace holding it is
% destroyed, which never happens to a script's base workspace. This
% function exists to give the guard a workspace to die with.

    guard = onCleanup(@() pvload.Sweep.shutdown(board, meas, cfg));

    Board.safeState(board);
    fprintf("Board initialised to the safe state (OPEN).\n");

    if cfg.SelfTest
        Board.selfTest(board);
    else
        fprintf("Self-test skipped. The potentiometers are unverified.\n");
    end

    if cfg.Adapt.Enabled
        results = runSweepAdaptive(board, meas, plan, cfg, log);
    else
        results = runSweep(board, meas, plan, cfg, log);
    end

    Board.safeState(board);
    clear guard;
end

function results = runSweep(board, meas, plan, cfg, log)
% A failure on the very first point is misconfiguration rather than a
% glitch, so it aborts instead of NaNing its way through 769 states.

    total   = numel(plan);
    results = allocateResults(total);
    prev    = "";
    run     = 0;               % consecutive faults
    faults  = 0;
    written = 0;               % states already on disk
    started = tic;             % what the point actually costs, not the estimate

    for k = 1:total
        settle = Timing.settle(plan(k), prev, cfg);
        Board.apply(board, plan(k), settle);
        prev = plan(k).Mode;

        [volts, amps, fault, meas] = Meter.readPoint(meas, cfg.Dmm.Parallel);

        if fault
            faults = faults + 1;
            run    = run + 1;
            if k == 1 || run > cfg.Dmm.MaxFaults
                error("PVLoad:MeterUnresponsive", ...
                    "The meters failed %d reading(s) in a row at state " + ...
                    "%d of %d. Check the cabling and the addresses.", ...
                    run, k, total);
            end
        else
            run = 0;
        end

        results = recordPoint(results, k, plan(k), settle, volts, amps);

        if cfg.PrintStatus
            printState(k, total, plan(k), volts, amps);
        end

        % Flushed in blocks rather than at the end, so an abort keeps
        % everything up to the last block boundary. Per row would be
        % correct and far too slow: writetable reopens the file each call.
        if k - written >= cfg.Out.Chunk || k == total
            Output.append(log, results, (written + 1):k, written == 0);
            written = k;
        end
    end

    fprintf("\n%d read fault(s).\n", faults);
    fprintf("%.0f ms per state in the end, against the %.0f ms " + ...
        "estimated.\n", 1e3 * toc(started) / total, ...
        1e3 * Timing.perPoint(cfg, plan));
    Meter.reportRangeChanges(meas);
end

function results = runSweepAdaptive(board, meas, master, cfg, log)
% The coarse pass, then rounds of states added wherever refineIntervals
% asks, until it stops asking or the cap lands. Every round runs in master
% plan order, so the settles see the same ascending walk the fixed sweep
% makes. Faults follow runSweep's rule: first point failing aborts, and so
% does MaxFaults in a row.

    cap      = min(cfg.Adapt.MaxPoints, numel(master));
    results  = allocateResults(cap);
    measured = false(numel(master), 1);
    V        = nan(numel(master), 1);
    I        = nan(numel(master), 1);

    row     = 0;
    written = 0;
    faults  = 0;
    run     = 0;
    noise   = 0;
    prev    = "";
    started = tic;
    queue   = Plan.coarse(master, cfg);

    for round = 1:cfg.Adapt.MaxRounds
        for k = queue(:)'
            if row >= cap
                break
            end

            settle = Timing.settle(master(k), prev, cfg);
            Board.apply(board, master(k), settle);
            prev = master(k).Mode;

            [volts, amps, fault, meas] = Meter.readPoint(meas, cfg.Dmm.Parallel);

            row = row + 1;
            if fault
                faults = faults + 1;
                run    = run + 1;
                if row == 1 || run > cfg.Dmm.MaxFaults
                    error("PVLoad:MeterUnresponsive", ...
                        "The meters failed %d reading(s) in a row at " + ...
                        "state %d. Check the cabling and the addresses.", ...
                        run, row);
                end
            else
                run = 0;
            end

            measured(k) = true;
            V(k) = volts;
            I(k) = amps;
            results = recordPoint(results, row, master(k), settle, ...
                volts, amps);

            if cfg.PrintStatus
                printState(row, cap, master(k), volts, amps);
            end

            if row - written >= cfg.Out.Chunk
                Output.append(log, results, (written + 1):row, written == 0);
                written = row;
            end
        end

        if row >= cap
            fprintf("The %d point cap landed, so refinement stopped " + ...
                "there. Raising ADAPT_MAX_POINTS\nwould let it " + ...
                "continue.\n", cap);
            break
        end

        [queue, seen] = refineIntervals(measured, V, I, cfg);
        noise = max(noise, seen);
        queue = queue(~measured(queue));
        if isempty(queue)
            break
        end
        if cfg.PrintStatus
            fprintf("-- round %d adds %d state(s) where the measured " + ...
                "curve bends --\n", round + 1, numel(queue));
        end
    end

    results = trimResults(results, row);
    if row > written
        Output.append(log, results, (written + 1):row, written == 0);
    end

    checkDrift(board, meas, master, results, prev, cfg);

    if 3 * noise > cfg.Adapt.Bend
        warning("PVLoad:RefinementAtNoiseFloor", ...
            "The measured curve stepped the wrong way, current up or " + ...
            "voltage down with rising load, by about %.1f%% of its span. " + ...
            "That is the illumination wobbling between readings, and " + ...
            "refinement held itself above that floor instead of chasing " + ...
            "it. The states are honest; the wobble is in every one of " + ...
            "them.", 100 * noise);
    end

    fprintf("\n%d of %d states measured, %d read fault(s).\n", ...
        row, numel(master), faults);
    fprintf("%.0f ms per state in the end, against the %.0f ms " + ...
        "estimated.\n", 1e3 * toc(started) / max(row, 1), ...
        1e3 * Timing.perPoint(cfg, master));
    Meter.reportRangeChanges(meas);
end

function [next, noise] = refineIntervals(measured, V, I, cfg)
% Where the measured curve says another state is needed. Three rules, all
% off the measured V and I and normalised to the measured span so one
% setting serves any cell:
%
%   - a segment longer than Gap splits whatever its shape, because a knee
%     can sit between two coarse states that both read flat.
%   - a point further than Bend off the chord of its neighbours is a bend,
%     and both segments at it split.
%   - the two segments at the largest measured power always split.
%
% Splitting is by position in the master plan: the model orders, the
% measurements decide. A segment between plan neighbours cannot split
% further and drops out, which is what ends the refinement. A NaN takes no
% part in the geometry, so a dropped reading widens a segment rather than
% poisoning it.

    next  = [];
    noise = 0;
    idx   = find(measured(:) & ~isnan(V(:)) & ~isnan(I(:)));
    if numel(idx) < 2
        return
    end

    v = abs(V(idx));
    i = abs(I(idx));
    vSpan = max(v);
    iSpan = max(i);
    if vSpan <= 0 || iSpan <= 0
        return
    end
    x = v / vSpan;
    y = i / iSpan;

    n    = numel(idx);
    flag = false(n - 1, 1);

    % The noise floor, read off the curve itself. Points run in order of
    % increasing load, so current can only fall and voltage only rise; a
    % step the wrong way is the illumination having moved between two
    % readings, and the size of those steps is the size of the wobble.
    % Both thresholds sit on top of it, so a light that will not hold
    % still widens what counts as a bend instead of feeding an endless
    % split of segments whose shape is noise -- the 0.55 A laser run
    % wobbled ~10% and spent a hundred states chasing it. A clean curve
    % has no wrong-way steps, so the floor is zero and both settings
    % stand untouched.
    dx = diff(x);
    dy = diff(y);
    up   = mean(dy(dy > 0));
    down = mean(-dx(dx < 0));
    if isnan(up),   up = 0;   end
    if isnan(down), down = 0; end
    noise = 2 * hypot(up, down);
    bend  = max(cfg.Adapt.Bend, 3 * noise);
    gap   = max(cfg.Adapt.Gap,  4 * noise);

    flag(hypot(dx, dy) > gap) = true;

    for j = 2:n - 1
        d = chordDistance(x(j-1), y(j-1), x(j), y(j), x(j+1), y(j+1));
        if d > bend
            flag(j - 1) = true;
            flag(j)     = true;
        end
    end

    [~, at] = max(v .* i);
    flag(max(at - 1, 1))     = true;
    flag(min(at, n - 1))     = true;

    for j = find(flag)'
        mid = floor((idx(j) + idx(j + 1)) / 2);
        if mid > idx(j) && mid < idx(j + 1)
            next(end + 1) = mid;  %#ok<AGROW>
        end
    end
    next = unique(next);
end

function checkDrift(board, meas, master, results, prev, cfg)
% SHORT measured again after the last point brackets the run. The cell has
% no memory, so a first and last reading that disagree are the illumination
% having moved, and every point between was taken along that slide -- the
% 174402 run wobbled 1-2% in seconds. Reported, never corrected, and no CSV
% row, so the sweep's own SHORT stays the Isc.

    at = find([master.Mode] == "SHORT", 1);
    first = find(results.Mode == "SHORT", 1);
    if ~meas.Enabled || isempty(at) || isempty(first) || ...
       isnan(results.CurrentA(first))
        return
    end

    Board.apply(board, master(at), Timing.settle(master(at), prev, cfg));
    try
        last = abs(Meter.readOnce(meas.I));
    catch
        return
    end
    if isnan(last)
        return
    end

    moved = (last - abs(results.CurrentA(first))) / ...
            abs(results.CurrentA(first));
    fprintf("Drift check: SHORT read %.4f mA first and %.4f mA last, " + ...
        "%+.2f%% across the run.\n", ...
        1e3 * abs(results.CurrentA(first)), 1e3 * last, 100 * moved);

    if abs(moved) > 0.01
        warning("PVLoad:IlluminationDrifted", ...
            "The illumination moved %.1f%% while the sweep ran, and the " + ...
            "scatter that puts on the curve is larger than anything the " + ...
            "meters add. Nothing in software corrects it; a source that " + ...
            "has warmed up does.", 100 * abs(moved));
    end
end

function d = chordDistance(x1, y1, x2, y2, x3, y3)
% Perpendicular distance from the middle point to the chord of its
% neighbours, in whatever units the caller normalised to. A degenerate
% chord makes the plain distance to the first point the answer.

    len = hypot(x3 - x1, y3 - y1);
    if len < eps
        d = hypot(x2 - x1, y2 - y1);
        return
    end
    d = abs((x3 - x1) * (y1 - y2) - (x1 - x2) * (y3 - y1)) / len;
end

function results = allocateResults(nStates)
% Filled by index rather than grown, which keeps this linear.

    z = nan(nStates, 1);

    results = struct( ...
        'StateIndex',  z, 'Mode', strings(nStates, 1), ...
        'Code1',       z, 'Code2', z, 'RNominal', z, ...
        'VoltageV',    z, 'CurrentA', z, 'ResistanceOhm', z, 'PowerW', z, ...
        'SettleS',     z, 'Timestamp', NaT(nStates, 1));
end

function results = trimResults(results, n)
% Cut the preallocated rows an adaptive run did not use.

    for name = string(fieldnames(results))'
        results.(name) = results.(name)(1:n);
    end
end

function results = recordPoint(results, row, state, settle, volts, amps)
% One row.
%
% Resistance and power are computed from the measured values, never from
% the wiper code. That is the whole reason the board carries no sensing:
% the tap code is a repeatable setting, not a known resistance.

    results.StateIndex(row)    = row;
    results.Mode(row)          = state.Mode;
    results.Code1(row)         = state.Code1;
    results.Code2(row)         = state.Code2;
    results.RNominal(row)      = state.Resistance;
    results.VoltageV(row)      = volts;
    results.CurrentA(row)      = amps;
    results.ResistanceOhm(row) = volts / amps;
    results.PowerW(row)        = volts * amps;
    results.SettleS(row)       = settle;
    results.Timestamp(row)     = datetime("now");
end

function printState(index, total, state, volts, amps)
    if isnan(volts) && isnan(amps)
        reading = "";
    else
        reading = sprintf("   V=%9.5f  I=%9.4f mA", volts, 1e3 * amps);
    end

    fprintf("[%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm%s\n", ...
        index, total, state.Mode, state.Code1, state.Code2, ...
        state.Resistance, reading);
end


%% =====================================================================
%  Logging
%  =====================================================================

function safeShutdown(board, meas, cfg)
% Every step guarded separately and none rethrow: this runs during an
% interrupt, and an error here would mask whatever caused the abort.
% Returning the board to OPEN is the whole job; darkening the cell is the
% operator's, the same as lighting it was.

    try
        Board.safeState(board);
    catch
        warning("PVLoad:SafeStateFailed", ...
            "Could not return the board to OPEN. Power down the Arduino, " + ...
            "which releases every relay.");
    end

    Meter.closeBoth(meas);

    if cfg.Dmm.Enabled
        fprintf("Board returned to OPEN and the meters are closed.\n");
    end
end
