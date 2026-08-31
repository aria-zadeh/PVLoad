classdef Sweep

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

    % Ctrl-C is an interrupt, not an exception: catch blocks never run and
    % only onCleanup fires, when the workspace holding it dies. That is why
    % this is a function.
    guard = onCleanup(@() pvload.Sweep.shutdown(board, meas, cfg));

    Board.safeState(board);
    fprintf("Board initialised to the safe state (OPEN).\n");

    if cfg.SelfTest
        Board.selfTest(board);
    else
        fprintf("Self-test skipped. The potentiometers are unverified.\n");
    end

    results = runSweepAdaptive(board, meas, plan, cfg, log);

    Board.safeState(board);
    clear guard;
end

function results = runSweepAdaptive(board, meas, master, cfg, log)

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

    % current can only fall and voltage only rise with rising load, so a
    % step the wrong way is the light moving. Both thresholds sit above it.
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

    % SHORT again at the end. The cell has no memory, so a first and last
    % reading that disagree are the illumination having moved.
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

    len = hypot(x3 - x1, y3 - y1);
    if len < eps
        d = hypot(x2 - x1, y2 - y1);
        return
    end
    d = abs((x3 - x1) * (y1 - y2) - (x1 - x2) * (y3 - y1)) / len;
end

function results = allocateResults(nStates)

    z = nan(nStates, 1);

    results = struct( ...
        'StateIndex',  z, 'Mode', strings(nStates, 1), ...
        'Code1',       z, 'Code2', z, 'RNominal', z, ...
        'VoltageV',    z, 'CurrentA', z, 'ResistanceOhm', z, 'PowerW', z, ...
        'SettleS',     z, 'Timestamp', NaT(nStates, 1));
end

function results = trimResults(results, n)

    for name = string(fieldnames(results))'
        results.(name) = results.(name)(1:n);
    end
end

function results = recordPoint(results, row, state, settle, volts, amps)

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

function safeShutdown(board, meas, cfg)

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
