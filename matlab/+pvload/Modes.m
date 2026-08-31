classdef Modes

methods (Static)

    function runPlan(cfg)

        plan = Plan.master(cfg);
        reportPlan(cfg, plan);
        fprintf("\nNothing was opened. Set RUN to board, meters or sweep to " + ...
            "use hardware.\n");
    end

    function runBoard(cfg)

        plan  = Plan.build(cfg);
        board = Board.connect(cfg);
        guard = onCleanup(@() pvload.Util.quietly(@() pvload.Board.safeState(board)));

        fprintf("Board connected on %s.\n", cfg.SerialPort);
        Board.safeState(board);
        fprintf("Safe state (OPEN) entered.\n");

        if cfg.SelfTest
            Board.selfTest(board);
        end

        probes = unique(round(linspace(1, numel(plan), 8)));
        fprintf("\nWalking %d states spread across the sweep:\n", numel(probes));
        prev = "";
        for k = probes
            Board.apply(board, plan(k), Timing.settle(plan(k), prev, cfg));
            prev = plan(k).Mode;
            fprintf("  [%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm\n", ...
                k, numel(plan), plan(k).Mode, plan(k).Code1, plan(k).Code2, ...
                plan(k).Resistance);
        end

        Board.safeState(board);
        clear guard;
        fprintf("\nBoard OK. Returned to OPEN.\n");
    end

    function runRamp(cfg)

        plan  = Plan.build(cfg);
        board = Board.connect(cfg);
        guard = onCleanup(@() pvload.Util.quietly(@() pvload.Board.safeState(board)));

        fprintf("Board connected on %s.\n", cfg.SerialPort);
        Board.safeState(board);
        fprintf("Safe state (OPEN) entered.\n");

        if cfg.SelfTest
            Board.selfTest(board);
        end

        steps = unique(round(linspace(1, numel(plan), cfg.RampSteps)));
        jumps = [NaN, diff([plan(steps).Resistance])];

        fprintf("\n%d states, %g s each, about %.0f s in total.\n", ...
            numel(steps), cfg.RampDwell, numel(steps) * cfg.RampDwell);
        fprintf("Meter goes on J1 and J3, set to ohms, with no cell connected.\n");
        fprintf("Compare the step column, not the total: a series offset lands " + ...
                "in\nevery reading and cancels out of a difference.\n\n");

        for n = 1:numel(steps)
            k = steps(n);
            if isnan(jumps(n))
                gap = "";
            else
                gap = sprintf("   step +%8.1f", jumps(n));
            end
            fprintf("  [%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm%s\n", ...
                k, numel(plan), plan(k).Mode, plan(k).Code1, plan(k).Code2, ...
                plan(k).Resistance, gap);
            drawnow;
            Board.apply(board, plan(k), cfg.RampDwell);
        end

        Board.safeState(board);
        clear guard;
        fprintf("\nRamp done. Returned to OPEN.\n");
    end

    function runWiper(cfg)

        plan  = Plan.build(cfg);
        board = Board.connect(cfg);
        guard = onCleanup(@() pvload.Util.quietly(@() pvload.Board.safeState(board)));

        fprintf("Board connected on %s.\n", cfg.SerialPort);
        Board.safeState(board);

        if cfg.SelfTest
            Board.selfTest(board);
        end

        % Writing s for the ladder step:
        %   SHORT   = K2
        %   LOW(n)  = K1 + Rw1 + n*s + K3
        %   FULL(n) = K1 + Rw1 + n*s + Rw2
        % so LOW(0) - SHORT is Rw1 and FULL(n) - LOW(n) is Rw2. Every
        % reading shares the same probes, so the difference cancels them.
        idx = Plan.stateIndex(plan, "SHORT", 0, cfg);
        for k = 1:numel(cfg.WiperCodes)
            n = cfg.WiperCodes(k);
            if n <= cfg.WiperSteps
                idx(end + 1) = Plan.stateIndex(plan, "LOW", n, cfg);   %#ok<AGROW>
            end
            idx(end + 1) = Plan.stateIndex(plan, "FULL", n, cfg);      %#ok<AGROW>
        end

        fprintf("\n%d states, %g s each, about %.0f s in total.\n", ...
            numel(idx), cfg.RampDwell, numel(idx) * cfg.RampDwell);
        fprintf("Write down the meter at every hold.\n\n");

        for k = 1:numel(idx)
            state = plan(idx(k));
            fprintf("  %2d  %-5s  U1=%3d  U2=%3d   model ~%9.1f ohm\n", ...
                k, state.Mode, state.Code1, state.Code2, state.Resistance);
            drawnow;
            Board.apply(board, state, cfg.RampDwell);
        end

        Board.safeState(board);
        clear guard;

        fprintf("\nU1 wiper is row 2 minus row 1.\n");
        fprintf("U2 wiper is each FULL row minus the LOW row above it, and " + ...
                "should be\nthe same number every time.\n");
        fprintf("Returned to OPEN.\n");
    end

    function runVerify(cfg)

        board = Board.connect(cfg);
        guard = onCleanup(@() pvload.Util.quietly(@() pvload.Board.safeState(board)));

        fprintf("Board connected on %s.\n", cfg.SerialPort);
        Board.safeState(board);
        Board.selfTest(board);

        holds = [ ...
            verifyHold("OPEN",  0,   0,   "R1, and K1 releasing")
            verifyHold("SHORT", 0,   0,   "K2 closing")
            verifyHold("FULL",  0,   0,   "K1 closing, and both wipers")
            verifyHold("FULL",  255, 0,   "U1 ladder")
            verifyHold("FULL",  255, 255, "U2 ladder")
            verifyHold("LOW",   0,   0,   "K3 closing")
            verifyHold("LOW",   0,   255, "K3 closing, proved")];

        fprintf("\n%d holds, %g s each. Meter in ohms on J1 and J3, no cell.\n", ...
            numel(holds), cfg.RampDwell);
        fprintf("Write all seven down.\n\n");

        for k = 1:numel(holds)
            h = holds(k);
            fprintf("  %d  %-5s  U1=%3d  U2=%3d    %s\n", ...
                k, h.Mode, h.Code1, h.Code2, h.Proves);
            drawnow;
            Board.mode(board, h.Mode);
            Board.wipers(board, h.Code1, h.Code2);
            pause(cfg.RampDwell);
        end

        Board.safeState(board);
        clear guard;

        fprintf("\nPass conditions:\n");
        fprintf("  1        about 470 kohm.\n");
        fprintf("  2        the lowest reading of the seven, and by far.\n");
        fprintf("  4 - 3    about 5 kohm. That is U1's ladder.\n");
        fprintf("  5 - 4    about 5 kohm. That is U2's ladder.\n");
        fprintf("  6        below 3, because K3 takes U2 out of the path.\n");
        fprintf("  7 = 6    to the ohm. A 5 kohm jump means K3 never closes.\n");
        fprintf("\nThe self-test above covers SPI and both chips.\n");
    end

    function runOhms(cfg)

        plan  = Plan.build(cfg);

        board      = Board.connect(cfg);
        boardGuard = onCleanup(@() pvload.Util.quietly(@() pvload.Board.safeState(board)));
        meter      = Meter.openPort(cfg.Dmm.R, "ohms");
        meterGuard = onCleanup(@() pvload.Util.quietly(@() pvload.Meter.closeOne(meter)));

        fprintf("Board connected on %s.\n", cfg.SerialPort);
        Board.safeState(board);

        if cfg.SelfTest
            Board.selfTest(board);
        end

        fprintf("Ohms meter: %s\n", Meter.identify(meter, "ohms"));
        Meter.configure(meter, "ohms", cfg.Dmm.R.Range);

        fprintf("\n%d states, about %.0f s in total.\n", numel(plan), ...
            numel(plan) * (cfg.OhmsSettle + cfg.Dmm.R.Conversion));
        fprintf("Meter goes on J1 and J3, set to ohms, with no cell connected.\n\n");

        measured = nan(numel(plan), 1);
        stamps   = NaT(numel(plan), 1);
        faults   = 0;
        run      = 0;

        for k = 1:numel(plan)
            Board.apply(board, plan(k), cfg.OhmsSettle);
            [measured(k), bad] = readOhms(meter);
            stamps(k) = datetime("now");

            if bad
                faults = faults + 1;
                run    = run + 1;
                if k == 1 || run > cfg.Dmm.MaxFaults
                    error("PVLoad:MeterUnresponsive", ...
                        "The meter failed %d reading(s) in a row at state %d " + ...
                        "of %d. Check the cabling and the address.", ...
                        run, k, numel(plan));
                end
            else
                run = 0;
            end

            if cfg.PrintStatus
                fprintf("  [%4d/%4d] %-5s  U1=%3d  U2=%3d  model ~%9.1f ohm" + ...
                    "   meter %11.1f ohm\n", k, numel(plan), plan(k).Mode, ...
                    plan(k).Code1, plan(k).Code2, plan(k).Resistance, measured(k));
            end
        end

        Board.safeState(board);
        clear boardGuard meterGuard;

        fprintf("\n%d state(s) measured, %d read fault(s).\n", ...
            numel(plan), faults);
        Output.saveOhmsRun(cfg, plan, measured, stamps);
    end

    function runMeters(cfg)

        if ~cfg.Dmm.Enabled
            error("PVLoad:MetersDisabled", ...
                "RUN is ""meters"" but DMM_ENABLED is false.");
        end

        meas  = Meter.connect(cfg.Dmm, Ranging.pickVoltage(cfg), ...
                              Ranging.pickCurrent(cfg.Cell.IscFull, cfg));
        guard = onCleanup(@() pvload.Util.quietly(@() pvload.Meter.closeBoth(meas)));

        fprintf("\nOne conversion takes about %.0f ms on the voltmeter and " + ...
            "%.0f ms on the ammeter.\n", ...
            1e3 * cfg.Dmm.V.Conversion, 1e3 * cfg.Dmm.I.Conversion);
        fprintf("Ten readings:\n");
        for k = 1:10
            [v, i, fault, meas] = Meter.readPoint(meas, cfg.Dmm.Parallel);
            fprintf("  %2d  V = %11.6f   I = %11.6f A%s\n", k, v, i, ...
                Util.ternary(fault, "   (fault)", ""));
        end

        Meter.closeBoth(meas);
        clear guard;
        fprintf("\nMeters OK.\n");
    end

    function results = runSweep(cfg)

        plan = Plan.master(cfg);
        reportPlan(cfg, plan);

        board = Board.connect(cfg);
        fprintf("Board connected.\n");

        try
            meas = Meter.connect(cfg.Dmm, Ranging.pickVoltage(cfg), ...
                                 Ranging.pickCurrent(cfg.Cell.IscFull, cfg));
            [cfg, meas] = Ranging.probe(board, meas, cfg, plan);
            log  = Output.openLog(cfg, numel(plan));
        catch openError
            pvload.Util.quietly(@() pvload.Board.safeState(board));
            rethrow(openError);
        end

        results = Sweep.execute(board, meas, plan, cfg, log);

        fprintf("\nRun complete. %d states.\n", numel(results.StateIndex));
        if strlength(log.Readings) > 0
            fprintf("Readings: %s\n", log.Readings);
        end

        stats = Curve.summarise(results, cfg);
        Curve.report(stats);
        Curve.draw(results, stats, Output.figurePath(log));
    end

end
end

function h = verifyHold(mode, code1, code2, proves)
    h = struct('Mode', mode, 'Code1', code1, 'Code2', code2, 'Proves', proves);
end

function [ohms, fault] = readOhms(meter)

    ohms  = NaN;
    fault = false;

    try
        ohms = Meter.readOnce(meter);
    catch
        fault = true;
    end

    fault = fault || isnan(ohms);
end

function reportPlan(cfg, plan)

    perPoint = Timing.perPoint(cfg, plan);
    nCoarse  = numel(Plan.coarse(plan, cfg));
    cap      = min(cfg.Adapt.MaxPoints, numel(plan));

    fprintf("Sweep: %d coarse states of %d possible, %g ohm to %g ohm.\n", ...
        nCoarse, numel(plan), plan(1).Resistance, plan(end).Resistance);
    fprintf("Refinement then adds states where the measured curve " + ...
        "bends, to at most %d.\n", cap);

    if cfg.Cell.IscFull > 0 || cfg.Cell.VocFull > 0
        fprintf("Cell as configured: Isc %g mA, Voc %g V.\n", ...
            1e3 * cfg.Cell.IscFull, cfg.Cell.VocFull);
    else
        fprintf("Cell: measured at the start of the run and the meters " + ...
            "sized from it.\n");
    end

    if cfg.Dmm.Enabled
        fprintf("Meters: %s on volts at %.0f ms, %s on amps at %.0f ms " + ...
            "per conversion%s.\n", ...
            cfg.Dmm.V.Label, 1e3 * cfg.Dmm.V.Conversion, ...
            cfg.Dmm.I.Label, 1e3 * cfg.Dmm.I.Conversion, ...
            Util.ternary(cfg.Dmm.Parallel, ", overlapped", ""));
    else
        fprintf("Meters: none. Voltage and current will be logged as NaN.\n");
    end

    fprintf("About %.0f ms per point. Estimated run time %.1f to " + ...
        "%.1f minutes, set by how much\nof the curve turns out to " + ...
        "bend.\n", 1e3 * perPoint, perPoint * nCoarse / 60, ...
        perPoint * cap / 60);
end
