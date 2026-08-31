  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% TO STOP: press Ctrl-C ONCE and wait about three seconds.
%
% The cleanup handler returns the board to OPEN. 
% Pressing it a second time can interrupt that handler.

clear;
clc;


%   "plan"    print the plan and the time estimate, open nothing
%   "board"   Arduino and PCB only
%   "ramp"    board only, climbing the resistance range slowly enough to
%             follow on a handheld meter across J1 and J3
%   "wiper"   board only, the pairs of states whose difference is one
%             wiper resistance and nothing else
%   "verify"  board only, seven holds that between them exercise every
%             part of the board. the check for a freshly built one.
%   "ohms"    board and one meter on ohms across J1 and J3. every
%             state in the sweep is measured, written to CSV and plotted.
%             no cell, one meter.
%   "meters"  both sweep meters only
%   "sweep"   the full experiment, written to CSV

RUN = "sweep";  


% Ports and addresses, and what each one needs on the bench. Wiring and the
% power sequence are in docs/PVLoad_BenchCard.pdf, which is meant to be
% printed; only the parts that reach this file are repeated here.
%
%   SERIAL_PORT   Arduino over a USB-B cable, nothing to set on it.
%                 serialportlist("available") lists what is attached.
%   DMM_*_ADDRESS neither meter has anything but an IEEE-488 connector,
%                 so each needs a USB-GPIB adapter matched to the VISA,
%                 which here is Keysight. one adapter carries both meters: the
%                 connectors stack, so the second cable runs meter to meter
%                 rather than back to the laptop. give each meter its own
%                 primary address from its front panel first, because they
%                 all ship on 27 and two of those collide. visadevlist
%                 confirms them.

SERIAL_PORT = "COM4";                % Arduino com port

DMM_ENABLED   = true;                % set to true if both sweep meters are
                                     % attached. the DMM_*_MODEL settings in
                                     % part 2 say which instrument each one
                                     % is; they need not be the same.
DMM_V_ADDRESS = "GPIB0::22::INSTR";  % meter across the cell
DMM_I_ADDRESS = "GPIB0::1::INSTR";   % meter in series with PV+

DMM_R_ADDRESS = "GPIB0::1::INSTR";  % the one meter RUN "ohms" uses, on
                                     % ohms across J1 and J3. that mode
                                     % ignores DMM_ENABLED, so a bench with
                                     % one meter free runs it with the sweep
                                     % meters still switched off.




% roughly what your cell does under the illumination you will run it at.
% sizes the meter ranges and prints estimates only, never enters a result,
% so rough is fine. the one place it is not advisory is the top of the
% ammeter: an ISC_FULL above the highest range the configured meter has is
% refused rather than measured badly.
%
% illumination is set by hand: set the lamp, run the sweep, change the
% lamp, run it again; each run writes its own timestamped CSV and RUN_TAG
% is how you tell them apart afterwards.

ISC_FULL = 0;              % A, short-circuit current under that light.
VOC_FULL = 0;              % V, open-circuit voltage under that light.
                           % zero for both, which is the normal setting,
                           % means the sweep measures them itself before it
                           % starts and sizes the meters from what it
                           % found. see probeRanges. a number here pins the
                           % range instead, which is only worth doing when
                           % the light will change mid-run and you want one
                           % range across the family.

CELL_AREA_CM2 = 0;         % cm2 of illuminated cell, or 0 if not known.
                           % decides whether the figure carries current or
                           % current density. labels output and nothing else.



% a sweep costs about six minutes; RUN "plan" prints the estimate before
% anything is opened.

PRINT_STATUS = true;       % echo each state. off for long unattended runs.
SELF_TEST    = true;       % probe both pots over SPI first. false to test
                           % the flow on a bare Arduino with no board.

RAMP_STEPS = 769;           % states RUN "ramp" visits, spread evenly across
                           % the sweep. 2 to 769.
RAMP_DWELL = 1.0;          % s each state is held, in "ramp" and "wiper"
                           % both. an autoranging handheld needs a second
                           % or two to re-range and you need longer than
                           % that to write the number down.

OHMS_SETTLE = 0.5;         % s each state is held in RUN "ohms" before the
                           % reading is triggered. the conversion follows
                           % it, so a state costs this plus about 0.4 s and
                           % the 769 of them take roughly twelve minutes.
                           % autoranging needs most of this; a fixed
                           % DMM_R_RANGE runs happily at 0.1.

WIPER_CODES = [0 255];
                           % code sums RUN "wiper" compares at. a wiper
                           % resistance that changes across them is not a
                           % wiper resistance. past 255 there is no LOW
                           % state to pair with, so those codes contribute
                           % a FULL row alone and walk U2 by itself.

WRITE_CSV = true;
OUT_DIR   = "../data/sweep_data";
RUN_TAG   = "ILASER0p850";            % added to the file names. this is where the
                           % illumination goes, since nothing else records
                           % it. e.g. "cell3_lamp60"


% the sweep can spend its states where the curve earns them instead of
% evenly along the ladder. a coarse pass measures the whole range first,
% and then states are added between measured neighbours wherever the curve
% bends or a gap is wide enough to hide the knee, round after round, until
% neither is true. every decision comes from the measured voltages and
% currents; the resistance model keeps its old job of ordering the states
% and nothing more. SHORT and OPEN are always in the coarse pass, so Isc
% and Voc do not depend on any of this. CODE_STEP is ignored while this is
% on: the coarse thinning is ADAPT_COARSE_STEP and refinement can land on
% any of the 769 states.

ADAPT_COARSE_STEP = 32;    % wiper codes between coarse states, the same
                           % thinning CODE_STEP does. 32 makes the first
                           % pass 27 states.
ADAPT_GAP         = 0.12;  % fraction of the measured I-V span. a segment
                           % between neighbours longer than this is split
                           % whether or not it looks bent, which is what
                           % stops a knee hiding between two coarse states
                           % that each read as flat.
ADAPT_BEND        = 0.020; % fraction of the span a point may sit off the
                           % chord of its neighbours before the curve is
                           % bent there and both segments at it are split.
                           % has to sit above the illumination's own
                           % wobble: the 174402 run moved 1-2% in seconds,
                           % and a threshold below that spends rounds
                           % splitting straight segments the light bent.
ADAPT_MAX_POINTS  = 200;   % states the run may spend in total. reached,
                           % it stops further refinement; it never skips a
                           % state already queued or cuts a reading short.
ADAPT_MAX_ROUNDS  = 12;    % passes including the coarse one. each round
                           % halves the gaps it touches, so this resolves
                           % any gap the ladder has with room to spare.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BELOW HERE DESCRIBES THE HARDWARE. NOT TUNING.
% Only change it if the hardware changes, and change docs/HARDWARE.md too.


% pin map, docs/HARDWARE.md section 4. SPI pins fixed by the Uno's SPI
% peripheral, cannot be reassigned.

BOARD_TYPE = "Uno";

PIN_SCK = "D13";           % SPI clock,          U1 SCK and U2 SCK
PIN_SDI = "D11";           % SPI MOSI, MCU->pot, U1 SDI and U2 SDI
PIN_SDO = "D12";           % SPI MISO, pot->MCU, U1 SDO and U2 SDO

PIN_CS_U1 = "D10";         % U1 CS#, active low
PIN_CS_U2 = "D9";          % U2 CS#, active low

PIN_K1_DRIVE = "D6";       % K1, 470 kohm bypass relay. HIGH bypasses it.
PIN_K2_DRIVE = "D7";       % K2, whole-load short relay. HIGH shorts the cell.
PIN_K3_DRIVE = "D8";       % K3, DigiPot 2 bypass relay. HIGH bypasses U2.

CODE_STEP     = 16;        % states = 767/step + 2. thins by wiper code,
                           % never by resistance.


% orders sweep, labels output. never enters a result.

R_AB_NOMINAL = 5000;       % ohms, one MCP41HV51-502 end to end
WIPER_STEPS  = 255;        % 8-bit ladder has 255 step resistors
R_WIPER      = 155;        % ohms/device, measured board 2, docs/BRINGUP.md
R_CONTACT    = 0.150;      % ohms, reed contact resistance, maximum
R_OPEN_PATH  = 470e3;      % ohms, R1



% "196" = Keithley 196 (amps from 300 uA). "34401A" = Agilent 34401A (amps
% from 10 mA, has NPLC and switchable high-Z input). Named per meter since
% voltmeter and ammeter need not match.

DMM_V_MODEL      = "34401A";       % "196" or "34401A", per meter.
DMM_I_MODEL      = "196";          % the sweep's two, and then the single
DMM_R_MODEL      = "196";          % meter RUN "ohms" opens
DMM_TIMEOUT      = 10;             % s, must exceed one conversion
DMM_ZERO_CORRECT = true;           % null meter offset. 34401A only.
DMM_NPLC         = 10;             % power line cycles/conversion. 34401A
                                   % only: 0.02, 0.2, 1, 10 or 100.
DMM_LINE_HZ      = 60;             % mains frequency
DMM_V_RANGE      = 0;              % V, or 0 to pick smallest holding VOC_FULL
DMM_I_RANGE      = 0;              % A, or 0 to size from ISC_FULL
DMM_R_RANGE      = 0;              % ohm, or 0 for autorange (sweep spans
                                   % five decades, no fixed range holds it)
DMM_PARALLEL     = true;           % trigger both meters, then collect both
DMM_MAX_FAULTS   = 5;              % consecutive read failures before abort

% Keithley 196, manual 196-901-01 Rev D section 3.9. Amps is F3 (F1/F2 are AC).
DDC_196 = struct( ...
    'Model',      "196", ...
    'Label',      "Keithley 196", ...
    'Dialect',    "ddc", ...
    'ReadTerm',   "CR/LF", ...
    'WriteTerm',  "LF", ...
    'IdPrefix',   "196", ...
    'Volts',      "F0", ...
    'Amps',       "F3", ...
    'Ohms',       "F2", ...
    'Range',      "R%d", ...
    'AutoRange',  "R0", ...
    'RangeOnly',  "R%d", ...
    'Prefixes',   "DCV|ACV|OHM|OCO|DCI|ACI|dBV|dBI", ...
    'StatusMap',  struct('F', 3, 'K', 6, 'R', 18, 'S', 19, 'T', 20, 'Z', 27), ...
    'Common',     "Z0B0G0M0K2S3T5", ...
    'Machine',    "U0", ...
    'Error',      "U1", ...
    'Conversion', 0.106, ...
    'VRanges',    [0.3 3 30 300], ...
    'IRanges',    [3e-4 3e-3 3e-2 3e-1 3], ...
    'RRanges',    [300 3e3 3e4 3e5 3e6 3e7 3e8]);
%   DCI not DCA (another Keithley uses DCA) — a decoder that misses this
%   turns every current reading into NaN. StatusMap is read instead of the
%   error word because the error word is unreliable after open (primeDdc).

% Agilent 34401A, manual 34401-90004. NOT RUN AGAINST THE INSTRUMENT YET.
%
% CONF resets integration time, autozero and input impedance to defaults,
% so Common must follow it, not precede it.
%
% TRIG:DEL:AUTO ON, not TRIG:DEL AUTO — AUTO is a node, not a parameter
% (manual p.80); the short form is -224 Illegal parameter value.
SCPI_34401A = struct( ...
    'Model',      "34401A", ...
    'Label',      "Agilent 34401A", ...
    'Dialect',    "scpi", ...
    'ReadTerm',   "LF", ...
    'WriteTerm',  "LF", ...
    'IdPrefix',   "34401A", ...
    'Volts',      "VOLT:DC", ...
    'Amps',       "CURR:DC", ...
    'Ohms',       "RES", ...
    'AutoRange',  "RANG:AUTO ON", ...
    'RangeOnly',  "%s:RANG %g", ...
    'Common',     ["TRIG:SOUR IMM", "TRIG:DEL:AUTO ON", ...
                   "TRIG:COUN 1", "SAMP:COUN 1"], ...
    'AutoZero',   "ZERO:AUTO %s", ...
    'HighZ',      "INP:IMP:AUTO ON", ...
    'Nplc',       DMM_NPLC, ...
    'Clear',      "*CLS", ...
    'Trigger',    "INIT", ...
    'Fetch',      "FETC?", ...
    'Read',       "READ?", ...
    'Machine',    "*IDN?", ...
    'Error',      "SYST:ERR?", ...
    'NoError',    "+0", ...
    'Overflow',   9.8e37, ...
    'Conversion', 0.06 + (1 + double(DMM_ZERO_CORRECT)) * ...
                  DMM_NPLC / DMM_LINE_HZ, ...
    'VRanges',    [0.1 1 10 100 1000], ...
    'IRanges',    [0.01 0.1 1 3], ...
    'RRanges',    [100 1e3 1e4 1e5 1e6 1e7 1e8]);
%   HighZ must follow CONF (CONFigure/MEASure? reset INP:IMP:AUTO off).
%   Without it the 10 Mohm input divides against the 470 kohm OPEN path
%   and reads Voc ~4.5% low. Setting is volatile, sent every configure.

PROFILES = {DDC_196, SCPI_34401A};

DDC_V = selectProfile(PROFILES, DMM_V_MODEL, "DMM_V_MODEL");
DDC_I = selectProfile(PROFILES, DMM_I_MODEL, "DMM_I_MODEL");
DDC_R = selectProfile(PROFILES, DMM_R_MODEL, "DMM_R_MODEL");


% settle = max(RELAY, SAFETY * (switch + TAUS * R * C_LOAD + CELL)).
% the conversion is deliberately absent: the trigger goes out after this
% pause and the reply blocks for it, so counting it here would only slow
% the sweep.

RELAY_SETTLE  = 0.010;     % s after a relay changes. HARDWARE.md s6;
                           % the relays themselves spec 1.0 ms.
WIPER_SETTLE  = 0.001;     % s after a wiper-only change. the pot settles
                           % in ~1 us; this is the SPI round trip.
SETTLE_SAFETY = 1.5;       % covers USB jitter and pause() granularity
POINT_BUDGET  = 1.0;       % s, the most one state may cost end to end.
                           % the hold is whatever is left after the
                           % conversion and the board, so this is the
                           % number the run is actually built to, not an
                           % estimate of one. 50 states at a second is a
                           % minute.
BOARD_OVERHEAD = 0.08;     % s of USB round trips per state, measured off
                           % the clock. omitting it made the last estimate
                           % 3x too low.
RC_TAU_COUNT  = 7;         % time constants. e^-7 is 0.09%.
C_LOAD        = 300e-12;   % F, dominated by leads and meter input
CELL_SETTLE   = 0.020;     % s of flat hold for the cell, on top of the RC
MEASURE_SETTLE = true;     % measure the cell's settling at the slowest
                           % state and set C_LOAD from it. guessing low
                           % tilts the whole curve, worst where R is
                           % largest, rather than adding noise.

CSV_CHUNK     = 64;        % states per disk write. writetable reopens the
                           % file per call, so a row at a time is too slow
                           % and one write at the end loses an abort.

%% =====================================================================
%  Run
%  =====================================================================

cfg = struct( ...
    'Run',           RUN, ...
    'SerialPort',    SERIAL_PORT, ...
    'BoardType',     BOARD_TYPE, ...
    'PinSCK',        PIN_SCK, ...
    'PinSDI',        PIN_SDI, ...
    'PinSDO',        PIN_SDO, ...
    'PinCSU1',       PIN_CS_U1, ...
    'PinCSU2',       PIN_CS_U2, ...
    'PinK1',         PIN_K1_DRIVE, ...
    'PinK2',         PIN_K2_DRIVE, ...
    'PinK3',         PIN_K3_DRIVE, ...
    'CodeStep',      CODE_STEP, ...
    'PrintStatus',   PRINT_STATUS, ...
    'SelfTest',      SELF_TEST, ...
    'RampSteps',     RAMP_STEPS, ...
    'RampDwell',     RAMP_DWELL, ...
    'OhmsSettle',    OHMS_SETTLE, ...
    'WiperCodes',    WIPER_CODES, ...
    'RabNominal',    R_AB_NOMINAL, ...
    'WiperSteps',    WIPER_STEPS, ...
    'RWiper',        R_WIPER, ...
    'RContact',      R_CONTACT, ...
    'ROpenPath',     R_OPEN_PATH);

cfg.Cell = struct( ...
    'IscFull', ISC_FULL, ...
    'VocFull', VOC_FULL, ...
    'AreaCm2', CELL_AREA_CM2);

cfg.Adapt = struct( ...
    'CoarseStep', ADAPT_COARSE_STEP, ...
    'Gap',        ADAPT_GAP, ...
    'Bend',       ADAPT_BEND, ...
    'MaxPoints',  ADAPT_MAX_POINTS, ...
    'MaxRounds',  ADAPT_MAX_ROUNDS);

cfg.Dmm = struct( ...
    'Enabled',     DMM_ENABLED, ...
    'Timeout',     DMM_TIMEOUT, ...
    'LineHz',      DMM_LINE_HZ, ...
    'Parallel',    DMM_PARALLEL, ...
    'MaxFaults',   DMM_MAX_FAULTS, ...
    'ZeroCorrect', DMM_ZERO_CORRECT, ...
    'V', meterSpec(DDC_V, DMM_V_ADDRESS, DMM_V_RANGE, DDC_V.VRanges, ...
                   DMM_ZERO_CORRECT, DMM_TIMEOUT), ...
    'I', meterSpec(DDC_I, DMM_I_ADDRESS, DMM_I_RANGE, DDC_I.IRanges, ...
                   DMM_ZERO_CORRECT, DMM_TIMEOUT), ...
    'R', meterSpec(DDC_R, DMM_R_ADDRESS, DMM_R_RANGE, DDC_R.RRanges, ...
                   DMM_ZERO_CORRECT, DMM_TIMEOUT));

cfg.Timing = struct( ...
    'RelaySettle', RELAY_SETTLE, ...
    'WiperSettle', WIPER_SETTLE, ...
    'Safety',      SETTLE_SAFETY, ...
    'TauCount',    RC_TAU_COUNT, ...
    'CLoad',       C_LOAD, ...
    'CellSettle',  CELL_SETTLE, ...
    'Budget',      POINT_BUDGET, ...
    'Overhead',    BOARD_OVERHEAD, ...
    'Measure',     MEASURE_SETTLE);

cfg.Out = struct( ...
    'WriteCsv', WRITE_CSV, ...
    'Dir',      OUT_DIR, ...
    'Tag',      RUN_TAG, ...
    'Chunk',    CSV_CHUNK);

assertConfig(cfg);

switch cfg.Run
    case "plan",   runPlanOnly(cfg);
    case "board",  runBoardCheck(cfg);
    case "ramp",   runRamp(cfg);
    case "wiper",  runWiperCheck(cfg);
    case "verify", runVerify(cfg);
    case "ohms",   runOhmsSweep(cfg);
    case "meters", runMeterCheck(cfg);
    case "sweep",  results = runSweepAll(cfg);
end


%% =====================================================================
%  Run modes
%  =====================================================================

function runPlanOnly(cfg)

    plan = buildMasterPlan(cfg);
    reportPlan(cfg, plan);
    fprintf("\nNothing was opened. Set RUN to board, meters or sweep to " + ...
        "use hardware.\n");
end

function runBoardCheck(cfg)
% Arduino and PCB only. No cell, no meters.

    plan  = buildSweepPlan(cfg);
    board = connectBoard(cfg);
    guard = onCleanup(@() quietly(@() enterSafeState(board)));

    fprintf("Board connected on %s.\n", cfg.SerialPort);
    enterSafeState(board);
    fprintf("Safe state (OPEN) entered.\n");

    if cfg.SelfTest
        selfTestPotentiometers(board);
    end

    probes = unique(round(linspace(1, numel(plan), 8)));
    fprintf("\nWalking %d states spread across the sweep:\n", numel(probes));
    prev = "";
    for k = probes
        applyState(board, plan(k), settleFor(plan(k), prev, cfg));
        prev = plan(k).Mode;
        fprintf("  [%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm\n", ...
            k, numel(plan), plan(k).Mode, plan(k).Code1, plan(k).Code2, ...
            plan(k).Resistance);
    end

    enterSafeState(board);
    clear guard;
    fprintf("\nBoard OK. Returned to OPEN.\n");
end

function runRamp(cfg)
% Board only, handheld meter across J1 and J3, no cell.
%
% Printed ohms are the model, not a measurement. R_AB is +/-20%, so a
% disagreement at the low end is the model's tolerance. A larger one on a
% different board is what R_WIPER should be set to for that board.

    plan  = buildSweepPlan(cfg);
    board = connectBoard(cfg);
    guard = onCleanup(@() quietly(@() enterSafeState(board)));

    fprintf("Board connected on %s.\n", cfg.SerialPort);
    enterSafeState(board);
    fprintf("Safe state (OPEN) entered.\n");

    if cfg.SelfTest
        selfTestPotentiometers(board);
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
        % Printed and flushed before the state is applied, so the console
        % says what is coming.
        fprintf("  [%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm%s\n", ...
            k, numel(plan), plan(k).Mode, plan(k).Code1, plan(k).Code2, ...
            plan(k).Resistance, gap);
        drawnow;
        applyState(board, plan(k), cfg.RampDwell);
    end

    enterSafeState(board);
    clear guard;
    fprintf("\nRamp done. Returned to OPEN.\n");
end

function runWiperCheck(cfg)
% Board only. Wiper resistance by difference, which cancels the probes,
% jacks and traces every reading shares. With s the ladder step:
%
%   SHORT   = K2
%   LOW(n)  = K1 + Rw1 + n*s + K3
%   FULL(n) = K1 + Rw1 + n*s + Rw2
%
% so LOW(0) - SHORT is Rw1 and FULL(n) - LOW(n) is Rw2. Rw2 is a switch,
% so the same number should come back at every code; one that tracks the
% code is R_AB being wrong instead.

    plan  = buildSweepPlan(cfg);
    board = connectBoard(cfg);
    guard = onCleanup(@() quietly(@() enterSafeState(board)));

    fprintf("Board connected on %s.\n", cfg.SerialPort);
    enterSafeState(board);

    if cfg.SelfTest
        selfTestPotentiometers(board);
    end

    idx = findState(plan, "SHORT", 0, cfg);
    for k = 1:numel(cfg.WiperCodes)
        n = cfg.WiperCodes(k);
        % LOW runs one pot, so it stops at 255. Past that a FULL row stands
        % alone and every further step is U2 moving on its own.
        if n <= cfg.WiperSteps
            idx(end + 1) = findState(plan, "LOW", n, cfg);   %#ok<AGROW>
        end
        idx(end + 1) = findState(plan, "FULL", n, cfg);      %#ok<AGROW>
    end

    fprintf("\n%d states, %g s each, about %.0f s in total.\n", ...
        numel(idx), cfg.RampDwell, numel(idx) * cfg.RampDwell);
    fprintf("Write down the meter at every hold.\n\n");

    for k = 1:numel(idx)
        state = plan(idx(k));
        fprintf("  %2d  %-5s  U1=%3d  U2=%3d   model ~%9.1f ohm\n", ...
            k, state.Mode, state.Code1, state.Code2, state.Resistance);
        drawnow;
        applyState(board, state, cfg.RampDwell);
    end

    enterSafeState(board);
    clear guard;

    fprintf("\nU1 wiper is row 2 minus row 1.\n");
    fprintf("U2 wiper is each FULL row minus the LOW row above it, and " + ...
            "should be\nthe same number every time.\n");
    fprintf("Returned to OPEN.\n");
end

function runVerify(cfg)
% Board only. Seven holds covering both chips over SPI, all three relays,
% both ladders and R1. Pass conditions are differences and orders of
% magnitude, so a handheld's tens of ohms of lead offset does not matter.
%
% Holds 6 and 7 are written straight to the pots: no planned state drives
% U2 while K3 is meant to short it out, which is what catches a K3 that
% never operates.

    board = connectBoard(cfg);
    guard = onCleanup(@() quietly(@() enterSafeState(board)));

    fprintf("Board connected on %s.\n", cfg.SerialPort);
    enterSafeState(board);
    selfTestPotentiometers(board);

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
        setMode(board, h.Mode);
        setWipers(board, h.Code1, h.Code2);
        pause(cfg.RampDwell);
    end

    enterSafeState(board);
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

function h = verifyHold(mode, code1, code2, proves)
    h = struct('Mode', mode, 'Code1', code1, 'Code2', code2, 'Proves', proves);
end

function runOhmsSweep(cfg)
% Board and one meter on ohms across J1 and J3, no cell. What "ramp" does
% without a human copying numbers down. A constant offset of a few ohms
% across every point is the wiring, not the board.
%
% DMM_ENABLED stays out of it: that flag is about the pair the sweep needs.

    plan  = buildSweepPlan(cfg);

    % Two guards, because an onCleanup captures what exists when it is
    % built and the meter opens second. A meter that will not open still
    % leaves the board guarded.
    board      = connectBoard(cfg);
    boardGuard = onCleanup(@() quietly(@() enterSafeState(board)));
    meter      = openMeter(cfg.Dmm.R, "ohms");
    meterGuard = onCleanup(@() quietly(@() closePort(meter)));

    fprintf("Board connected on %s.\n", cfg.SerialPort);
    enterSafeState(board);

    if cfg.SelfTest
        selfTestPotentiometers(board);
    end

    fprintf("Ohms meter: %s\n", identifyMeter(meter, "ohms"));
    configureMeter(meter, "ohms", cfg.Dmm.R.Range);

    fprintf("\n%d states, about %.0f s in total.\n", numel(plan), ...
        numel(plan) * (cfg.OhmsSettle + cfg.Dmm.R.Conversion));
    fprintf("Meter goes on J1 and J3, set to ohms, with no cell connected.\n\n");

    measured = nan(numel(plan), 1);
    stamps   = NaT(numel(plan), 1);
    faults   = 0;
    run      = 0;

    for k = 1:numel(plan)
        applyState(board, plan(k), cfg.OhmsSettle);
        [measured(k), bad] = readOhms(meter);
        stamps(k) = datetime("now");

        if bad
            faults = faults + 1;
            run    = run + 1;
            % Same rule the sweep uses: the first point failing is the
            % wiring or the address, not a glitch.
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

    enterSafeState(board);
    clear boardGuard meterGuard;

    fprintf("\n%d state(s) measured, %d read fault(s).\n", ...
        numel(plan), faults);
    saveOhmsRun(cfg, plan, measured, stamps);
end

function [ohms, fault] = readOhms(meter)
% A timeout comes back NaN and is counted rather than thrown, the same way
% the sweep treats a dropped point.

    ohms  = NaN;
    fault = false;

    try
        ohms = meterReadOnce(meter);
    catch
        fault = true;
    end

    fault = fault || isnan(ohms);
end

function saveOhmsRun(cfg, plan, measured, stamps)
% CSV and plot share a stamped base name, so a later run cannot overwrite
% either. The figure is drawn whether or not WRITE_CSV is set.

    if ~cfg.Out.WriteCsv
        plotOhmsRun(plan, measured, "");
        fprintf("WRITE_CSV is false, so the plot is on screen only.\n");
        return
    end

    dir = resolvePath(cfg.Out.Dir);
    if ~isfolder(dir)
        mkdir(dir);
    end

    tag = cfg.Out.Tag;
    if strlength(tag) > 0
        tag = "_" + tag;
    end
    base = string(fullfile(dir, "pvload_" + ...
        string(datetime("now", "Format", "yyyyMMdd_HHmmss")) + tag + "_ohms"));

    t = table(stamps, (1:numel(plan))', [plan.Mode]', [plan.Code1]', ...
        [plan.Code2]', [plan.Resistance]', measured, ...
        'VariableNames', {'timestamp', 'state_index', 'mode', 'u1_code', ...
            'u2_code', 'r_model_ohm', 'r_measured_ohm'});
    writetable(t, base + ".csv");

    plotOhmsRun(plan, measured, base + ".png");

    fprintf("Readings: %s\n", base + ".csv");
    fprintf("Plot:     %s\n", base + ".png");
end

function plotOhmsRun(plan, measured, path)
% Lower axes is a ratio, not a difference: the SHORT state models at
% 0.150 ohm and R_AB's 20% at the top is tens of kohm, so only a ratio
% holds the whole range at once. 1 is agreement.
%
% OPEN is off both axes and SHORT off the ratio axes, because each sets a
% scale that hides the other 767 states. Both stay in the CSV; this is a
% choice about the axes, not about what gets measured.

    model = [plan.Resistance]';
    index = (1:numel(plan))';
    ratio = measured ./ model;
    mode  = [plan.Mode]';

    drawn = mode ~= "OPEN";
    model(~drawn) = NaN;
    shown = measured;
    shown(~drawn) = NaN;

    scaled = ratio;
    scaled(~drawn | mode == "SHORT") = NaN;

    fig = figure("Name", "PVLoad resistance sweep", "Color", "w");
    layout = tiledlayout(fig, 2, 1, "TileSpacing", "compact", ...
        "Padding", "compact");

    ax1 = nexttile(layout);
    plot(ax1, index, model, "-", "LineWidth", 1.0, ...
        "DisplayName", "model");
    hold(ax1, "on");
    plot(ax1, index, shown, ".", "MarkerSize", 6, ...
        "DisplayName", "measured");
    hold(ax1, "off");
    grid(ax1, "on");
    ylabel(ax1, "resistance, ohm");
    legend(ax1, "Location", "northwest");
    title(ax1, sprintf("%d states, J1 to J3, less the %d OPEN point(s)", ...
        numel(plan), sum(~drawn)));

    ax2 = nexttile(layout);
    plot(ax2, index, scaled, ".", "MarkerSize", 6);
    yline(ax2, 1, "-");
    grid(ax2, "on");
    xlabel(ax2, "state index, ordered by the model");
    ylabel(ax2, "meter / model");
    title(ax2, "SHORT and OPEN not shown", "FontWeight", "normal");

    linkaxes([ax1 ax2], "x");
    xlim(ax1, [find(drawn, 1, "first") find(drawn, 1, "last")]);

    if strlength(path) > 0
        exportgraphics(fig, path, "Resolution", 200);
    end

    hidden = sum(isnan(measured));
    if hidden > 0
        fprintf("%d point(s) the meter did not return are in the CSV " + ...
            "and are gaps on both axes.\n", hidden);
    end
end

function k = findState(plan, mode, code, cfg)
% Pulled out of the plan rather than rebuilt, so this cannot drift away
% from the model the sweep uses.

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

function runMeterCheck(cfg)
% Meters only. Checks dialect and wiring before a sweep depends on them.

    if ~cfg.Dmm.Enabled
        error("PVLoad:MetersDisabled", ...
            "RUN is ""meters"" but DMM_ENABLED is false.");
    end

    meas  = connectMeters(cfg);
    guard = onCleanup(@() quietly(@() closeMeters(meas)));

    fprintf("\nOne conversion takes about %.0f ms on the voltmeter and " + ...
        "%.0f ms on the ammeter.\n", ...
        1e3 * cfg.Dmm.V.Conversion, 1e3 * cfg.Dmm.I.Conversion);
    fprintf("Ten readings:\n");
    for k = 1:10
        [v, i, fault, meas] = readPoint(meas, cfg);
        fprintf("  %2d  V = %11.6f   I = %11.6f A%s\n", k, v, i, ...
            ternary(fault, "   (fault)", ""));
    end

    closeMeters(meas);
    clear guard;
    fprintf("\nMeters OK.\n");
end

function results = runSweepAll(cfg)
% One sweep at whatever illumination the bench is under. The lamp is set
% by hand, so a family of curves is several runs of this and RUN_TAG is
% the only record of which was which.

    % Refinement works into the gaps of the coarse pass, so the full plan
    % is needed whatever CODE_STEP says.
    plan = buildMasterPlan(cfg);
    reportPlan(cfg, plan);

    board = connectBoard(cfg);
    fprintf("Board connected.\n");

    % runExperiment's guard covers board and meters together, so it does
    % not exist while the meters are coming up. Without this catch, a
    % meter that will not open leaves the board energised behind nothing.
    try
        meas = connectMeters(cfg);
        [cfg, meas] = probeRanges(board, meas, cfg, plan);
        log  = openLog(cfg, numel(plan));
    catch openError
        quietly(@() enterSafeState(board));
        rethrow(openError);
    end

    results = runExperiment(board, meas, plan, cfg, log);

    fprintf("\nRun complete. %d states.\n", numel(results.StateIndex));
    if strlength(log.Readings) > 0
        fprintf("Readings: %s\n", log.Readings);
    end

    % Off the measured columns only. Nothing here reaches back into what
    % was swept.
    stats = summariseCurve(results, cfg);
    reportCurve(stats);
    plotCurve(results, stats, figurePath(log));
end

%% =====================================================================
%  Curve summary
%  =====================================================================

function path = figurePath(log)
% Figure sits beside the CSV under the same stamped name. No CSV means no
% path, and the figure is drawn on screen only.

    path = "";
    if strlength(log.Readings) > 0
        path = replace(log.Readings, ".csv", ".png");
    end
end

function stats = summariseCurve(results, cfg)
% Magnitudes throughout: sign depends on which way the leads went on. The
% CSV keeps the signs the meters reported.
%
% Isc and Voc come from the SHORT and OPEN states, falling back to the
% extremes of what was measured so a partial run stays useful; the flags
% say which happened.
%
% Efficiency is absent: it needs the incident optical power, which the
% software neither sets nor knows.

    v  = abs(results.VoltageV);
    i  = abs(results.CurrentA);
    p  = v .* i;
    ok = ~isnan(v) & ~isnan(i);

    stats = struct('Isc', NaN, 'Voc', NaN, 'Pmax', NaN, 'Vmp', NaN, ...
                   'Imp', NaN, 'FillFactor', NaN, ...
                   'AreaCm2', cfg.Cell.AreaCm2, ...
                   'Points', sum(ok), 'Missing', sum(~ok), ...
                   'IscFromEndpoint', false, 'VocFromEndpoint', false, ...
                   'OpenFraction', NaN, 'VocIsFloor', false, ...
                   'PmaxAtEdge', false);

    if ~any(ok)
        return
    end

    short = find(results.Mode == "SHORT" & ok, 1);
    if isempty(short)
        stats.Isc = max(i(ok));
    else
        stats.Isc = i(short);
        stats.IscFromEndpoint = true;
    end

    open = find(results.Mode == "OPEN" & ok, 1);
    if isempty(open)
        stats.Voc = max(v(ok));
    else
        stats.Voc = v(open);
        stats.VocFromEndpoint = true;
    end

    p(~ok) = NaN;
    [stats.Pmax, at] = max(p);
    stats.Vmp = v(at);
    stats.Imp = i(at);

    if stats.Voc > 0 && stats.Isc > 0
        stats.FillFactor = stats.Pmax / (stats.Voc * stats.Isc);
    end

    % Whether the numbers above hold, decided from the measurement.
    %
    % OPEN is 470 kohm, not an open circuit: that path draws a current set
    % by Voc while Isc scales with the light, so under weak illumination
    % the voltage there is a floor under Voc and FF inherits the error.
    %
    % The ladder stops at 10.3 kohm. A cell whose knee needs more never
    % leaves its current-source region, and the largest power in the sweep
    % is then the last ladder point rather than a maximum.

    if ~isempty(open) && stats.Isc > 0
        stats.OpenFraction = i(open) / stats.Isc;
        stats.VocIsFloor   = stats.OpenFraction > 0.05;
    end

    ladder = ok & results.Mode ~= "OPEN" & results.Mode ~= "SHORT";
    if any(ladder)
        [~, edge] = max(v .* ladder);
        stats.PmaxAtEdge = at == edge;
    end
end

function reportCurve(stats)

    if stats.Points == 0
        fprintf("No state returned a reading, so there is no curve.\n");
        return
    end

    guessed = "   (no SHORT state, largest measured)";

    % Same units as the figure, so an area given for one cannot leave the
    % other reporting the other thing.
    if stats.AreaCm2 > 0
        scale = 1e3 / stats.AreaCm2;
        fprintf("\nJsc  %8.3f mA/cm2%s\n", scale * stats.Isc, ...
            ternary(stats.IscFromEndpoint, "", guessed));
    else
        scale = 1e3;
        fprintf("\nIsc  %8.3f mA%s\n", scale * stats.Isc, ...
            ternary(stats.IscFromEndpoint, "", guessed));
    end

    fprintf("Voc  %8.3f V%s\n", stats.Voc, ...
        ternary(stats.VocFromEndpoint, "", ...
                "   (no OPEN state, largest measured)"));
    fprintf("FF   %8.3f\n", stats.FillFactor);
    fprintf("Pmax %8.3f %s   at Vmp %.3f V, Imp %.3f %s\n", ...
        scale * stats.Pmax, ternary(stats.AreaCm2 > 0, "mW/cm2", "mW"), ...
        stats.Vmp, scale * stats.Imp, ...
        ternary(stats.AreaCm2 > 0, "mA/cm2", "mA"));

    if stats.FillFactor >= 0.95
        fprintf("\nA fill factor of %.2f is not one a real cell makes: " + ...
            "points in the middle\nof the curve read more power than " + ...
            "Isc and Voc allow, which means the\nillumination moved " + ...
            "between readings. The curve is a record of the light,\n" + ...
            "not the cell. Nothing here is worth keeping.\n", ...
            stats.FillFactor);
    end

    if stats.VocIsFloor
        fprintf("\nThe OPEN state still drew %.1f%% of Isc through the " + ...
            "470 kohm path,\nso Voc is a floor and FF is smaller than " + ...
            "the cell's. More light\nis the fix; nothing in software " + ...
            "reaches it.\n", 100 * stats.OpenFraction);
    end

    if stats.PmaxAtEdge
        fprintf("\nThe largest power in the sweep is the last state of " + ...
            "the ladder, so the\nknee is above 10.3 kohm and outside " + ...
            "what the board can make. Pmax\nis a lower bound, not a " + ...
            "maximum.\n");
    end

    if stats.Missing > 0
        fprintf("%d state(s) returned no reading and are gaps in both.\n", ...
            stats.Missing);
    end
end

function plotCurve(results, stats, path)
% Current density where CELL_AREA_CM2 gives the area, absolute current
% where it does not.
%
% Sorted by voltage before the line is drawn: the sweep is ordered by the
% resistance model, which is allowed to be wrong about the order, so
% joining points in sweep order could draw a line the measurement does not
% support.

    if stats.Points == 0
        return
    end

    scale = 1e3;
    unitI = "mA";
    unitP = "mW";
    label = "Current (mA)";
    if stats.AreaCm2 > 0
        scale = 1e3 / stats.AreaCm2;
        unitI = "mA/cm^2";
        unitP = "mW/cm^2";
        label = "Current density (mA/cm^2)";
    end

    v = abs(results.VoltageV);
    i = scale * abs(results.CurrentA);
    p = scale * abs(results.VoltageV .* results.CurrentA);

    % Ladder gets the line, endpoints get their own markers. The board has
    % no states between the top of the ladder and the 470 kohm OPEN path,
    % so a line joining them would draw curve through a region nothing was
    % measured in — exactly where a dim cell's knee falls.

    ladder = results.Mode ~= "SHORT" & results.Mode ~= "OPEN";
    [vl, order] = sort(v(ladder));
    il = i(ladder); il = il(order);
    pl = p(ladder); pl = pl(order);

    fig = figure("Name", "PVLoad I-V curve", "Color", "w", ...
        "Units", "centimeters", "Position", [2 2 16 11]);
    ax = axes(fig);
    hold(ax, "on");

    yyaxis(ax, "left");
    plot(ax, vl, il, "-o", "MarkerSize", 3, "LineWidth", 1.1, ...
        "DisplayName", "load ladder");

    at = results.Mode == "SHORT";
    if any(at)
        plot(ax, v(at), i(at), "d", "MarkerSize", 8, "LineWidth", 1.2, ...
            "MarkerFaceColor", "w", "DisplayName", "SHORT");
    end

    at = results.Mode == "OPEN";
    if any(at)
        plot(ax, v(at), i(at), "^", "MarkerSize", 8, "LineWidth", 1.2, ...
            "MarkerFaceColor", "w", ...
            "DisplayName", ternary(stats.VocIsFloor, ...
                "OPEN (470 kohm, loaded)", "OPEN"));
    end

    plot(ax, stats.Vmp, scale * stats.Imp, "s", "MarkerSize", 10, ...
        "LineWidth", 1.4, "MarkerFaceColor", "w", ...
        "DisplayName", ternary(stats.PmaxAtEdge, ...
            "largest power (edge of sweep)", "maximum power"));
    ylabel(ax, label);
    ylim(ax, [0 1.1 * scale * stats.Isc]);

    yyaxis(ax, "right");
    plot(ax, vl, pl, "--", "LineWidth", 1.0, "DisplayName", "P-V");
    ylabel(ax, "Power (" + unitP + ")");
    ylim(ax, [0 1.4 * scale * stats.Pmax]);

    yyaxis(ax, "left");
    hold(ax, "off");
    box(ax, "on");
    ax.TickDir = "in";
    ax.LineWidth = 0.8;
    ax.FontSize = 10;
    xlabel(ax, "Voltage (V)");
    xlim(ax, [0 1.05 * stats.Voc]);
    legend(ax, "Location", "southwest", "Box", "off");

    if stats.AreaCm2 > 0
        first = sprintf("J_{sc} = %.3f %s", scale * stats.Isc, unitI);
    else
        first = sprintf("I_{sc} = %.3f mA", 1e3 * stats.Isc);
    end

    % Data coordinates, so the box lands in the same empty region below
    % the plateau whatever the cell does.
    text(ax, 0.04 * stats.Voc, 0.74 * 1.1 * scale * stats.Isc, ...
        {first, ...
         sprintf(ternary(stats.VocIsFloor, ...
             "V_{oc} > %.3f V", "V_{oc} = %.3f V"), stats.Voc), ...
         sprintf("FF = %.3f", stats.FillFactor), ...
         sprintf("P_{max} = %.3f %s", scale * stats.Pmax, unitP)}, ...
        "VerticalAlignment", "top", "FontSize", 10, ...
        "BackgroundColor", "w", "Margin", 6, ...
        "EdgeColor", [0.15 0.15 0.15]);

    if strlength(path) > 0
        exportgraphics(fig, path, "Resolution", 300);
        fprintf("Plot:     %s\n", path);
    end
end

%% =====================================================================
%  Sweep planning
%  =====================================================================

function plan = buildSweepPlan(cfg)
% Every state the board can produce, ordered by the resistance model. That
% model orders and labels only, it never decides what gets measured.

    states = enumerateStates(cfg);

    resistances = [states.Resistance];
    [~, order]  = sort(resistances);      % sort is stable, so on a tie the
    plan        = states(order);          % earlier-listed mode wins
end

function master = buildMasterPlan(cfg)
% All 769 states whatever CODE_STEP says: the adaptive sweep thins for
% itself and refines into the gaps.

    cfg.CodeStep = 1;
    master = buildSweepPlan(cfg);
end

function idx = coarseIndices(master, cfg)
% Thinned by wiper code, never by resistance, plus both endpoints.

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

function assertConfig(cfg)

    mustBeOneOf(cfg.Run, ...
        ["plan" "board" "ramp" "wiper" "verify" "ohms" "meters" ...
         "sweep"], "RUN");

    if cfg.RampSteps < 2 || cfg.RampSteps > 769
        error("PVLoad:BadRampSteps", ...
            "RAMP_STEPS is %g. The sweep has 769 states and a ramp needs " + ...
            "at least 2 of them.", cfg.RampSteps);
    end
    if cfg.RampDwell <= 0
        error("PVLoad:BadRampDwell", "RAMP_DWELL must be positive.");
    end
    if cfg.OhmsSettle <= 0
        error("PVLoad:BadOhmsSettle", "OHMS_SETTLE must be positive.");
    end
    if isempty(cfg.WiperCodes) || any(cfg.WiperCodes < 0) || ...
       any(cfg.WiperCodes > 2 * cfg.WiperSteps) || ...
       any(mod(cfg.WiperCodes, 1) ~= 0)
        error("PVLoad:BadWiperCodes", ...
            "WIPER_CODES must be whole numbers from 0 to %d, which is the " + ...
            "range of a FULL code sum.", 2 * cfg.WiperSteps);
    end

    A = cfg.Adapt;
    if A.CoarseStep < 1 || A.CoarseStep > cfg.WiperSteps || ...
       mod(A.CoarseStep, 1) ~= 0
        error("PVLoad:BadAdaptStep", ...
            "ADAPT_COARSE_STEP is %g. It thins by wiper code the way " + ...
            "CODE_STEP does, so it must be a whole number from 1 to " + ...
            "%d.", A.CoarseStep, cfg.WiperSteps);
    end
    if A.Gap <= 0 || A.Gap > 1 || A.Bend <= 0 || A.Bend > 1
        error("PVLoad:BadAdaptThreshold", ...
            "ADAPT_GAP and ADAPT_BEND are fractions of the measured " + ...
            "I-V span, above 0 and at most 1. They are %g and %g.", ...
            A.Gap, A.Bend);
    end
    nCoarse = numel(0:A.CoarseStep:cfg.WiperSteps) + ...
              numel(0:A.CoarseStep:2 * cfg.WiperSteps) + ...
              2;                        % SHORT and OPEN
    if A.MaxPoints < nCoarse
        error("PVLoad:BadAdaptCap", ...
            "ADAPT_MAX_POINTS is %g and the coarse pass alone is %d " + ...
            "states. The cap has to hold at least the coarse pass.", ...
            A.MaxPoints, nCoarse);
    end
    if A.MaxRounds < 1 || mod(A.MaxRounds, 1) ~= 0
        error("PVLoad:BadAdaptRounds", ...
            "ADAPT_MAX_ROUNDS is %g. It must be a whole number of at " + ...
            "least 1.", A.MaxRounds);
    end

    D = cfg.Dmm;
    if D.Enabled && D.V.Address == D.I.Address
        error("PVLoad:MeterAddressConflict", ...
            "Both meters are set to %s. They need separate addresses.", ...
            D.V.Address);
    end
    if D.Enabled && D.Timeout <= max(D.V.Conversion, D.I.Conversion)
        error("PVLoad:MeterTimeoutTooShort", ...
            "DMM_TIMEOUT is %g s but one conversion takes %g s.", ...
            D.Timeout, max(D.V.Conversion, D.I.Conversion));
    end
    assertNplc(D.V, D.LineHz);
    assertNplc(D.I, D.LineHz);
    assertNplc(D.R, D.LineHz);

    if D.Enabled && D.V.Range > 0
        rangeCode(D.V.Range, D.V.Ranges, "DMM_V_RANGE", D.V.Label);
    end
    if D.Enabled && D.I.Range > 0
        rangeCode(D.I.Range, D.I.Ranges, "DMM_I_RANGE", D.I.Label);
    end
    % RUN "ohms" uses one meter; not gated on D.Enabled.
    if D.R.Range > 0
        rangeCode(D.R.Range, D.R.Ranges, "DMM_R_RANGE", D.R.Label);
    end
    if D.Enabled && cfg.Cell.VocFull > max([D.V.Range, max(D.V.Ranges)])
        error("PVLoad:VocAboveMeterRange", ...
            "VOC_FULL is %g V and the highest volts range the %s has is " + ...
            "%g V, so the OPEN point would overflow.", ...
            cfg.Cell.VocFull, D.V.Label, max(D.V.Ranges));
    end
    if D.Enabled && D.V.Range > 0 && cfg.Cell.VocFull > D.V.Range
        error("PVLoad:VocAboveMeterRange", ...
            "VOC_FULL is %g V but DMM_V_RANGE is %g V, so the OPEN point " + ...
            "would overflow. Set it to 0 to size the range from VOC_FULL.", ...
            cfg.Cell.VocFull, D.V.Range);
    end
    if D.Enabled && cfg.Cell.IscFull > max(D.I.Ranges)
        error("PVLoad:IscAboveMeterRange", ...
            "ISC_FULL is %g A and the %s stops at %g A. Nothing in the " + ...
            "instrument goes higher, so the cell has to be measured " + ...
            "through a shunt or under weaker light.", ...
            cfg.Cell.IscFull, D.I.Label, max(D.I.Ranges));
    end
    if D.Enabled && cfg.Cell.IscFull > 0 && ...
       cfg.Cell.IscFull < 0.001 * min(D.I.Ranges)
        warning("PVLoad:IscFarBelowMeterRange", ...
            "ISC_FULL is %g A and the lowest amps range the %s has is " + ...
            "%g A, so the current reading is the bottom of a range. A " + ...
            "6.5 digit DMM is not an electrometer.", ...
            cfg.Cell.IscFull, D.I.Label, min(D.I.Ranges));
    end
end

function assertNplc(spec, lineHz)

    if spec.Ddc.Dialect ~= "scpi"
        return
    end

    nplc = [0.02 0.2 1 10 100];
    if ~any(abs(nplc - spec.Ddc.Nplc) <= 1e-9 * nplc)
        error("PVLoad:BadNplc", ...
            "DMM_NPLC is %g. The %s has %s.", ...
            spec.Ddc.Nplc, spec.Label, strjoin(string(nplc), ", "));
    end
    if lineHz <= 0
        error("PVLoad:BadLineFrequency", ...
            "DMM_LINE_HZ is %g. It is the mains frequency, 50 or 60.", ...
            lineHz);
    end
end

function mustBeOneOf(value, allowed, name)
    if ~any(string(value) == allowed)
        error("PVLoad:BadOption", "%s must be one of %s, not ""%s"".", ...
            name, strjoin("""" + allowed + """", ", "), string(value));
    end
end

function path = resolvePath(relative)
    if isfile(relative) || isfolder(relative)
        path = char(relative);
        return
    end
    here = fileparts(mfilename("fullpath"));
    path = fullfile(here, char(relative));
end

function reportPlan(cfg, plan)

    perPoint = estimatePointTime(cfg, plan);
    nCoarse  = numel(coarseIndices(plan, cfg));
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
            ternary(cfg.Dmm.Parallel, ", overlapped", ""));
    else
        fprintf("Meters: none. Voltage and current will be logged as NaN.\n");
    end

    fprintf("About %.0f ms per point. Estimated run time %.1f to " + ...
        "%.1f minutes, set by how much\nof the curve turns out to " + ...
        "bend.\n", 1e3 * perPoint, perPoint * nCoarse / 60, ...
        perPoint * cap / 60);
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

%% =====================================================================
%  Board control
%  =====================================================================

function board = connectBoard(cfg)

    a = arduino(cfg.SerialPort, cfg.BoardType, "Libraries", "SPI");

    assertSpiPins(a, cfg);

    board = struct();
    board.Arduino    = a;
    board.U1         = device(a, "SPIChipSelectPin", cfg.PinCSU1, "SPIMode", 0);
    board.U2         = device(a, "SPIChipSelectPin", cfg.PinCSU2, "SPIMode", 0);
    board.PinK1      = cfg.PinK1;
    board.PinK2      = cfg.PinK2;
    board.PinK3      = cfg.PinK3;
    board.SafeSettle = cfg.Timing.RelaySettle;
    board.Print      = cfg.PrintStatus;

    configurePin(a, cfg.PinK1, "DigitalOutput");
    configurePin(a, cfg.PinK2, "DigitalOutput");
    configurePin(a, cfg.PinK3, "DigitalOutput");
end

function assertSpiPins(a, cfg)
% SPI pins are fixed by the hardware peripheral; an edited pin map must
% fail loudly rather than silently describe the wrong wiring.

    switch string(a.Board)
        case {"Uno", "Nano3", "ProMini328_5V", "ProMini328_3V"}
            expected = ["D13", "D11", "D12"];   % SCK, MOSI, MISO
        case {"Mega2560", "MegaADK"}
            expected = ["D52", "D51", "D50"];
        otherwise
            warning("PVLoad:UnknownBoard", ...
                "SPI pin names not verified for board '%s'.", a.Board);
            return
    end

    actual = [string(cfg.PinSCK), string(cfg.PinSDI), string(cfg.PinSDO)];
    if ~isequal(actual, expected)
        error("PVLoad:SpiPinMismatch", ...
            "Hardware SPI on the %s is SCK=%s, SDI=%s, SDO=%s. " + ...
            "The configuration block says SCK=%s, SDI=%s, SDO=%s.", ...
            a.Board, expected(1), expected(2), expected(3), ...
            actual(1), actual(2), actual(3));
    end
end

function setRelays(board, k1, k2, k3)
    writeDigitalPin(board.Arduino, board.PinK1, k1);
    writeDigitalPin(board.Arduino, board.PinK2, k2);
    writeDigitalPin(board.Arduino, board.PinK3, k3);
end

function setMode(board, mode)
% K2 is opened first when leaving SHORT, so the short path is never left
% closed on the way into OPEN, which would collapse Voc to roughly 0 V.

    if ~strcmp(mode, "SHORT")
        writeDigitalPin(board.Arduino, board.PinK2, 0);
    end

    switch mode
        case "SHORT"                  % Isc. Whole load bypassed.
            setRelays(board, 1, 1, 0);
        case "LOW"                    % One pot in circuit.
            setRelays(board, 1, 0, 1);
        case "FULL"                   % Both pots in series.
            setRelays(board, 1, 0, 0);
        case "OPEN"                   % Voc. 470 kohm in circuit.
            setRelays(board, 0, 0, 0);
        otherwise
            error("PVLoad:BadMode", "Unknown mode '%s'.", mode);
    end
end

function writeWiper(dev, code)
% Two-byte write, HARDWARE.md section 5: address 0000, command 00, then
% the 8-bit code.

    if ~isscalar(code) || code < 0 || code > 255 || mod(code, 1) ~= 0
        error("PVLoad:BadWiperCode", "Wiper code must be an integer 0-255.");
    end
    writeRead(dev, uint8([0, code]), 'uint8');
end

function code = readWiper(dev)
% Read command 0x0C. The answer clocks out in the second byte.

    out  = writeRead(dev, uint8([12, 0]), 'uint8');
    code = double(out(2));
end

function verifyWiper(dev, expected, label)
    actual = readWiper(dev);
    if actual ~= expected
        error("PVLoad:WiperMismatch", ...
            "%s did not take the wiper code: wrote %d, read back %d. " + ...
            "Check the chip select wiring, the SDO line, and that " + ...
            "SHDN# is held high.", label, expected, actual);
    end
end

function setWipers(board, code1, code2)
% U2 is written even when K3 bypasses it, so it is never left unknown.
    writeWiper(board.U1, code1);
    writeWiper(board.U2, code2);

    verifyWiper(board.U1, code1, "U1");
    verifyWiper(board.U2, code2, "U2");
end

function selfTestPotentiometers(board)
% The only check that SPI is bidirectional and that each chip select
% reaches its own chip. HARDWARE.md section 6: a bad supply sequence
% silently forces the wiper to mid-scale.

    probes = [0, 85, 170, 255];
    chips  = {'U1', 'U2'};

    fprintf("Self-test: reading wiper registers back over SPI.\n");
    for c = 1:numel(chips)
        name = chips{c};
        dev  = board.(name);
        for code = probes
            writeWiper(dev, code);
            pause(0.01);
            readback = readWiper(dev);
            if readback ~= code
                error("PVLoad:SelfTestFailed", ...
                    "%s failed readback: wrote %d, read %d. The chip is " + ...
                    "not responding as expected. Check CS, SDO, SDI, SCK, " + ...
                    "VL, SHDN# and the 24 V rail before sweeping.", ...
                    name, code, readback);
            end
        end
        writeWiper(dev, 0);
        fprintf("  %s: OK across codes %s\n", name, mat2str(probes));
    end
end

function applyState(board, state, settle)
    setMode(board, state.Mode);
    setWipers(board, state.Code1, state.Code2);
    pause(settle);
end

function enterSafeState(board)
    setMode(board, "OPEN");
    setWipers(board, 0, 0);
    pause(board.SafeSettle);
end


%% =====================================================================
%  Multimeters
%  =====================================================================

function meas = connectMeters(cfg)
% Every port opened here is closed again unless all of them come up: the
% caller's guard is built from the returned struct, so it does not exist
% while this runs. Closing on the way out makes the next run's open a
% fresh session rather than a race against the last one.

    meas = struct('Enabled', false, 'V', [], 'I', [], ...
                  'VId', "", 'IId', "", 'Faults', 0, 'Cfg', cfg.Dmm, ...
                  'VOpenSeen', NaN, 'VAdaptive', false, ...
                  'VRangeNow', 0, 'VRanges', [], 'VChanges', 0, ...
                  'IAdaptive', false, 'IRangeNow', 0, 'IRanges', [], ...
                  'IChanges', 0);

    if ~cfg.Dmm.Enabled
        return
    end

    meas.V = openMeter(cfg.Dmm.V, "voltage");

    try
        meas.I = openMeter(cfg.Dmm.I, "current");

        meas.VId = identifyMeter(meas.V, "voltage");
        meas.IId = identifyMeter(meas.I, "current");
        fprintf("Voltage meter: %s\n", meas.VId);
        fprintf("Current meter: %s\n", meas.IId);

        % Configured once. On a Keithley each configuration leaves another
        % triggered reading behind, so doing it twice is worse than
        % redundant.
        configureMeter(meas.V, "voltage", pickVoltageRange(cfg));
        configureMeter(meas.I, "current", ...
                       pickCurrentRange(cfg.Cell.IscFull, cfg));
    catch setupError
        quietly(@() closeMeters(meas));
        rethrow(setupError);
    end

    meas.Enabled = true;
end

function spec = meterSpec(profile, address, range, ranges, zeroCorrect, timeout)
% Ranges is the list for the function this meter will be asked for, so a
% caller holding a spec never picks between the three.

    spec = struct( ...
        'Ddc',         profile, ...
        'Address',     address, ...
        'Model',       profile.Model, ...
        'Label',       profile.Label, ...
        'Conversion',  profile.Conversion, ...
        'ZeroCorrect', zeroCorrect, ...
        'Timeout',     timeout, ...
        'Range',       range, ...
        'Ranges',      ranges, ...
        'Port',        []);
end

function profile = selectProfile(profiles, model, name)
% Profiles carry different fields, so they arrive as a cell array and are
% matched on Model rather than indexed by position.

    for k = 1:numel(profiles)
        if profiles{k}.Model == model
            profile = profiles{k};
            return
        end
    end

    known = strings(1, numel(profiles));
    for k = 1:numel(profiles)
        known(k) = """" + profiles{k}.Model + """";
    end
    error("PVLoad:BadMeterModel", ...
        "%s is ""%s"". It must be one of %s.", ...
        name, model, strjoin(known, ", "));
end

function m = openMeter(spec, role)
% The terminator comes from the profile: a Keithley reply ends CR LF, a
% 34401A ends LF alone, and waiting on a pair that never arrives is a
% timeout on every read. The 34401A also has RS-232, reached as an ASRL
% resource, so an address is not necessarily GPIB.

    m = spec;
    D = spec.Ddc;

    try
        m.Port = visadev(spec.Address);
        m.Port.Timeout = spec.Timeout;
        configureTerminator(m.Port, D.ReadTerm, D.WriteTerm);
        % A meter can be mid-reading when a fresh session opens; without
        % this the first query waits on a terminator already gone past.
        flush(m.Port, "input");
        if D.Dialect == "scpi"
            if startsWith(upper(string(spec.Address)), "ASRL")
                % Over RS-232 the meter ignores the bus until this
                % arrives. Over GPIB the addressing does it and the meter
                % does not accept the command, so it is sent only here.
                writeline(m.Port, "SYST:REM");
            end
        else
            primeDdc(m);
        end
    catch openError
        error("PVLoad:MeterOpenFailed", ...
            "Could not open the %s meter (%s) at %s over VISA: %s\n%s", ...
            role, spec.Label, spec.Address, openError.message, ...
            availableResources());
    end
end

function primeDdc(m)
% visadev sends *IDN? to whatever it opens and cannot be told not to
% (MATLAB Answers 2118301). The 196 predates SCPI and executes nothing
% without a trailing X, so that fragment strands in its parser and the
% next real command is concatenated onto it. Hence the session-open
% faults: a first command that vanishes, an IDDCO latched with no invalid
% command sent, both surfacing an exchange late. The error word is
% unreliable near an open, so ddcVerifySetup reads the machine word.
%
% The bare X below is the terminator visadev never sent, executing the
% fragment at a time of our choosing and draining what it latches.
%
% T5 must land before the first question: power-on is T0, continuous on
% talk (table 3-8), so being addressed to talk is itself a trigger and
% every query comes back as a reading. One write per attempt — two writes
% into a fresh session get mangled into one string.

    pause(0.5);
    ddcTell(m.Port, "");
    pause(0.3);
    % The fragment contains a D, the display-message command, so it paints
    % the tail of *IDN? on the front panel (reads "n7"). A bare D restores
    % the display. The TRIG ERROR flashed alongside is equally cosmetic.
    ddcTell(m.Port, "D");
    pause(0.3);
    flush(m.Port, "input");

    for attempt = 1:3
        ddcTell(m.Port, "T5");
        pause(0.5);
        flush(m.Port, "input");

        for k = 1:4
            try
                word = ddcAsk(m, m.Ddc.Error);
            catch
                break
            end
            flags = extractAfter(word, m.Ddc.IdPrefix);
            if ~ismissing(flags) && strlength(flags) > 0 && ...
               all(char(flags) == '0')
                return
            end
        end
    end

    error("PVLoad:MeterWillNotSettle", ...
        "The %s at %s never answered %s with a clean word during " + ...
        "priming. Power-cycle it and check the front panel.", ...
        m.Label, m.Address, m.Ddc.Error);
end

function text = availableResources()

    try
        found = visadevlist;
        if isempty(found)
            text = "visadevlist found no instruments.";
        else
            text = "visadevlist sees: " + ...
                   strjoin(string(found.ResourceName), ", ");
        end
    catch listError
        text = "visadevlist failed: " + string(listError.message);
    end
end

function word = identifyMeter(m, role)
% The 196 has no *IDN?; its U0 machine word opens with the model number.
% The 34401A's *IDN? puts the model in the middle. Either way this catches
% a DMM_*_MODEL naming one meter while the address reaches the other,
% which would otherwise show up as a range number meaning something else.

    D = m.Ddc;

    if D.Dialect == "scpi"
        word  = meterAsk(m, D.Machine);
        found = contains(word, D.IdPrefix);
    else
        word  = ddcAskStatus(m, D.Machine);
        found = startsWith(word, D.IdPrefix);
    end

    if ~found
        error("PVLoad:MeterModelMismatch", ...
            "The %s meter is configured as a %s but answered %s with " + ...
            """%s"". The model number is in that reply, and it is not " + ...
            "this one.", role, D.Model, D.Machine, word);
    end
end

function configureMeter(m, role, range)
% Function and range travel together: an R number means a different range
% in every function, and CONF takes both as one command. The 196's setup
% is checked against the machine word rather than the error word, which
% visadev poisons at every open (primeDdc).

    if m.Ddc.Dialect == "scpi"
        scpiConfigure(m, role, range);
        assertMeterHappy(m, role);
    else
        sent = ddcConfigure(m, role, range);
        ddcVerifySetup(m, role, sent);
        % The queries above each triggered another conversion. Left in the
        % buffer it becomes the sweep's first reading and shifts the whole
        % curve by one point, which does not look broken.
        flush(m.Port, "input");
    end
end

function name = rangeSetting(role)

    switch role
        case "voltage", name = "DMM_V_RANGE";
        case "ohms",    name = "DMM_R_RANGE";
        otherwise,      name = "DMM_I_RANGE";
    end
end

function node = functionFor(D, role)
    switch role
        case "voltage", node = D.Volts;
        case "ohms",    node = D.Ohms;
        otherwise,      node = D.Amps;
    end
end

function sent = ddcConfigure(m, role, range)
% Returns what it sent, so the verification that follows knows which
% digits to expect in the machine word.

    D  = m.Ddc;
    fn = functionFor(D, role);

    % Zero means autorange: RUN "ohms" spans five decades, and the probe
    % reads before any range is known.
    if range <= 0
        command = fn + D.AutoRange;
    else
        command = fn + sprintf(D.Range, ...
            rangeCode(range, m.Ranges, rangeSetting(role), m.Label));
    end

    sent = command + D.Common;
    ddcTell(m.Port, sent);

    % This string's X is also a trigger; the query that follows would
    % otherwise race the conversion it starts.
    pause(0.2);
end

function scpiConfigure(m, role, range)
% Order is not cosmetic: CONF resets integration time, autozero and input
% impedance to the function's defaults, so everything else must follow it.
% The error queue is cleared first so configureMeter's SYST:ERR? reports
% this setup and not what the front panel did earlier.

    D    = m.Ddc;
    node = functionFor(D, role);
    auto = range <= 0;

    if auto
        select = "CONF:" + node;
    else
        rangeCode(range, m.Ranges, rangeSetting(role), m.Label);
        select = sprintf("CONF:%s %g", node, range);
    end

    meterTell(m, D.Clear);
    meterTell(m, select);

    if auto
        meterTell(m, node + ":" + D.AutoRange);
    end

    for k = 1:numel(D.Common)
        meterTell(m, D.Common(k));
    end

    meterTell(m, sprintf("%s:NPLC %g", node, D.Nplc));
    meterTell(m, sprintf(D.AutoZero, ternary(m.ZeroCorrect, "ON", "OFF")));

    if role == "voltage"
        % Ammeter and ohmmeter have no use for it, and on the current
        % function the volts input is not the one being read.
        meterTell(m, D.HighZ);
    end
end

function assertMeterHappy(m, role)
% SCPI only. The 196's setup is checked in ddcVerifySetup instead, its
% error word not being trustworthy near a session open. The queue is
% drained rather than sampled: a setup sends nine commands and several can
% be rejected.

    faults = scpiErrorQueue(m);
    if isempty(faults)
        return
    end
    error("PVLoad:MeterRejectedSetup", ...
        "The %s meter (%s) answered %s with %s.", ...
        role, m.Label, m.Ddc.Error, strjoin("""" + faults + """", "; "));
end

function ddcVerifySetup(m, role, sent)
% Compares the machine word digit by digit against what was sent,
% positions from StatusMap. Checks what the meter is in, not what it
% complained about, because a phantom IDDCO from the session open
% (primeDdc) can surface in the error word commands later. A refused
% setting shows up as a digit that did not move.
%
% R0, the ohms autorange, is skipped: the word then reports whichever
% range the meter chose, which is information rather than disagreement.

    word  = ddcAskStatus(m, m.Ddc.Machine);
    state = extractAfter(word, m.Ddc.IdPrefix);
    map   = m.Ddc.StatusMap;

    if ismissing(state) || strlength(state) < map.Z
        error("PVLoad:MeterRejectedSetup", ...
            "The %s meter (%s) answered %s with ""%s"", which is not a " + ...
            "machine status word.", role, m.Label, m.Ddc.Machine, word);
    end

    text = char(state);
    for letter = string(fieldnames(map))'
        digit = regexp(sent, letter + "(\d)", "tokens", "once");
        if isempty(digit) || (letter == "R" && digit{1} == '0')
            continue
        end
        at = map.(letter);
        if text(at) ~= char(digit{1})
            error("PVLoad:MeterRejectedSetup", ...
                "The %s meter (%s) was sent %s%s but its machine word " + ...
                "reads %s%c at that position: ""%s"".", role, m.Label, ...
                letter, string(digit{1}), letter, text(at), word);
        end
    end
end

function faults = scpiErrorQueue(m)
% The 34401A holds 20 entries and returns +0 once drained; the counter is
% there for a meter that never says +0.

    faults = strings(0, 1);

    for k = 1:25
        word = meterAsk(m, m.Ddc.Error);
        if startsWith(word, m.Ddc.NoError)
            return
        end
        faults(end+1, 1) = word;   %#ok<AGROW>
    end
end

function code = rangeCode(range, ranges, name, label)
% On the Keithleys R1 is the most sensitive range and they climb by
% decades, so the R number is a position in the list (table 3-12). The
% 34401A names the range as a number but wants the same check: a range the
% instrument does not have is an error here, not something it rounds up.

    code = find(abs(ranges - range) <= 1e-9 * ranges, 1);
    if isempty(code)
        error("PVLoad:BadMeterRange", ...
            "%s is %g. The %s has %s.", ...
            name, range, label, strjoin(string(ranges), ", "));
    end
end

function range = pickCurrentRange(iscExpected, cfg)
% Sized once, before the first state. A range hunt inside a settled point
% spends conversions on the wrong range.

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
% Sized from a voltage rather than a named number, so one configuration
% works on either meter: a 9 V Voc lands on 30 V on a 196 and 10 V on a
% 34401A. vocSeen is VOC_FULL if pinned, what OPEN read if probed, and
% nothing before either, which asks for autorange.

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

    % No headroom, unlike the ammeter: OPEN is already the highest voltage
    % the sweep reaches, and rounding a 9 V cell past the 10 V range costs
    % the 34401A's high impedance input, which exists only below that.
    fits = V.Ranges(V.Ranges >= vocSeen);
    if isempty(fits)
        range = max(V.Ranges);
    else
        range = min(fits);
    end
end

function [cfg, meas] = probeRanges(board, meas, cfg, plan)
% Measures the two numbers the meters are sized from instead of being told
% them. OPEN is the largest voltage of the run and SHORT the largest
% current, and every other state is one of those two with resistance
% added, so two autoranged readings bound the whole run.
%
% ISC_FULL and VOC_FULL pin the range instead when a family of runs at
% different light should share one; a pinned range skips its half.

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
        enterSafeState(board);
        pause(settleFor(probeState("OPEN"), "", cfg));
        voc = probeRead(meas.V, "voltage", "OPEN");
        fprintf("  OPEN  %9.4f V\n", voc);
    end

    if wantI
        setMode(board, "SHORT");
        setWipers(board, 0, 0);
        pause(settleFor(probeState("SHORT"), "OPEN", cfg));
        isc = probeRead(meas.I, "current", "SHORT");
        fprintf("  SHORT %9.4f mA\n", 1e3 * isc);
    end

    % A closed K2 across a lit cell is not a state to leave the board in
    % while the meters are reconfigured.
    enterSafeState(board);

    meas.VOpenSeen = voc;

    vRange = pickVoltageRange(cfg, voc);
    iRange = pickCurrentRange(isc, cfg);

    configureMeter(meas.V, "voltage", vRange);
    configureMeter(meas.I, "current", iRange);

    fprintf("  ranges %g V and %g mA, 20%% above what the cell showed.\n", ...
        vRange, 1e3 * iRange);

    % Both meters follow the reading from here.
    meas.VAdaptive = true;
    meas.VRangeNow = vRange;
    meas.VRanges   = meas.V.Ranges;

    % The ammeter was once pinned, on the argument that a cell's current is
    % flat across a sweep. True of the cell, not of the bench: run
    % 20260828_163338 drifted 125 uA to 197 uA in fourteen minutes as the
    % illumination climbed, ran off the top of its range and aborted.
    meas.IAdaptive = true;
    meas.IRangeNow = iRange;
    meas.IRanges   = meas.I.Ranges;

    % The 470 kohm path draws a current fixed by Voc while Isc scales with
    % the light, so under weak illumination OPEN stops being an open
    % circuit. Said before an hour of sweeping rather than after.
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
% Measures settling at the slowest state (largest R, worst-case RC) and
% derives CLoad from it. Guessing low is not noise: an under-settled point
% reads current still falling toward its value, worse at high R, which is
% exactly the order the sweep runs in, so the whole plateau leans.

    ladder = [plan.Mode] ~= "SHORT" & [plan.Mode] ~= "OPEN";
    [rTop, at] = max([plan.Resistance] .* ladder);
    tol   = 0.002;                  % 0.2%, a few counts at 6.5 digits
    limit = 5;                      % s

    applyState(board, plan(at), 0);

    times   = zeros(1, 256);
    reading = nan(1, 256);
    n       = 0;
    clock   = tic;

    while n < numel(times) && toc(clock) < limit
        n = n + 1;
        try
            reading(n) = meterReadOnce(meas.I);
        catch
            reading(n) = NaN;
        end
        times(n) = toc(clock);
    end

    enterSafeState(board);

    reading = reading(1:n);
    times   = times(1:n);
    good    = ~isnan(reading);

    if sum(good) < 4
        fprintf("  settling: the ammeter would not read, keeping " + ...
            "C_LOAD at %g F.\n", cfg.Timing.CLoad);
        return
    end

    % Last quarter's median so a slow tail isn't mistaken for the answer.
    final = median(reading(good & times >= 0.75 * times(n)));
    moved = find(good & abs(reading - final) > tol * abs(final), 1, "last");

    if isempty(moved)
        % Inside tolerance by the first reading: that's the meter's own
        % conversion speed, not a cell capacitance, so nothing is reported.
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

    % Settling and drift look identical over one window but mean opposite
    % things; misreading drift as capacitance stretches every state and
    % gives the drift more time to work (see docs/BRINGUP.md). Told apart
    % by where the change sits: settling leaves the tail flat, drift keeps
    % the tail moving as much as the middle.
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
% Rmpp = Vmp/Imp, approximated as 0.8*Voc / 0.9*Isc, checked against the
% ladder's range so the operator knows before the sweep runs. Prints and
% warns only: it never skips or chooses a state, same rule as the
% resistance model everywhere else.

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
% Must arrive: a probe that quietly returned NaN would size the range
% from nothing and the whole run would inherit it.

    try
        value = meterReadOnce(m);
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

function [volts, amps, fault, meas] = readPoint(meas, cfg)
% Both meters are triggered before either reply is collected, so the two
% conversions overlap (196: K2 holds the bus open under a running
% conversion; 34401A: INIT / FETC? are already separate).
%
% A timeout returns NaN rather than throwing: one dropped reading in 769 is
% a lost row, and aborting an hour-long sweep over a bus hiccup is worse.

    volts = NaN;
    amps  = NaN;
    fault = false;

    if ~meas.Enabled
        return
    end

    try
        if cfg.Dmm.Parallel
            meterTrigger(meas.V);
            meterTrigger(meas.I);
            volts = meterFetch(meas.V);
            amps  = meterFetch(meas.I);
        else
            volts = meterReadOnce(meas.V);
            amps  = meterReadOnce(meas.I);
        end
    catch
        fault = true;
    end

    if meas.VAdaptive
        [volts, meas.VRangeNow, meas.VChanges] = followRange( ...
            meas.V, "voltage", meas.VRanges, meas.VRangeNow, ...
            volts, meas.VChanges);
    end

    iChangesBefore = meas.IChanges;
    if meas.IAdaptive
        [amps, meas.IRangeNow, meas.IChanges] = followRange( ...
            meas.I, "current", meas.IRanges, meas.IRangeNow, ...
            amps, meas.IChanges);
    end

    % An ammeter overload mid-point clamps burden voltage in series with
    % the cell, corrupting the paired voltage reading even though the
    % recovered current is real. Reread now that both meters fit.
    if meas.IChanges > iChangesBefore && ~isnan(amps)
        try
            if cfg.Dmm.Parallel
                meterTrigger(meas.V);
                meterTrigger(meas.I);
                volts = meterFetch(meas.V);
                amps  = meterFetch(meas.I);
            else
                volts = meterReadOnce(meas.V);
                amps  = meterReadOnce(meas.I);
            end
        catch
            fault = true;
        end
    end

    fault = fault || isnan(volts) || isnan(amps);
end

function [value, rangeNow, changes] = followRange(m, role, ranges, ...
                                                 rangeNow, value, changes)
% Keeps a meter on the smallest range its reading fits. Volts: range floor
% dominates resolution (34401A: 0.0035% rdg + 0.0005% range). Amps: a
% pinned range can't follow moving illumination and overflow (NaN) after
% five in a row aborts the run. Hysteresis against oscillation: widen at
% 90% of range or on overflow, narrow only under 8%, and jump straight to
% the fitting range (SHORT to next state can fall volts to millivolts in
% one step).

    % Widen one step at a time; overflow alone doesn't say how far over.
    while isnan(value)
        wider = min(ranges(ranges > rangeNow * 1.0001));
        if isempty(wider)
            return                  % already as wide as the meter goes
        end
        setMeterRange(m, role, wider);
        rangeNow = wider;
        changes  = changes + 1;
        try
            value = meterReadOnce(m);
        catch
            value = NaN;
        end
    end

    magnitude = abs(value);

    if magnitude > 0.9 * rangeNow
        wider = min(ranges(ranges > rangeNow * 1.0001));
        if ~isempty(wider)
            setMeterRange(m, role, wider);
            rangeNow = wider;
            changes  = changes + 1;
        end
        return
    end

    target = min(ranges(ranges >= magnitude / 0.9));
    if ~isempty(target) && target < rangeNow && magnitude < 0.08 * rangeNow
        setMeterRange(m, role, target);
        rangeNow = target;
        changes  = changes + 1;
    end
end

function setMeterRange(m, role, range)
% Range only, via RANGe not CONF: CONF resets NPLC, autozero and input
% impedance to function defaults, which would silently undo the meter's
% configured setup on every range change mid-sweep.

    D = m.Ddc;

    if D.Dialect == "scpi"
        meterTell(m, sprintf(D.RangeOnly, functionFor(D, role), range));
        return
    end

    meterTell(m, sprintf(D.RangeOnly, ...
        rangeCode(range, m.Ranges, rangeSetting(role), m.Label)));

    % That command's X is a trigger like every other, so the conversion it
    % starts is discarded before the next point asks for its own.
    pause(0.15);
    flush(m.Port, "input");
end

function meterTrigger(m)
% Start a conversion and return without waiting for it. A bare X under T5
% on the 196, INIT on the 34401A.

    if m.Ddc.Dialect == "scpi"
        writeline(m.Port, m.Ddc.Trigger);
    else
        ddcTell(m.Port, "");
    end
end

function value = meterFetch(m)
% Collect the reading a previous meterTrigger started. The 196 sends it
% unasked once the conversion ends; the 34401A holds it in memory until
% FETC? asks.

    if m.Ddc.Dialect == "scpi"
        value = meterDecode(m, meterAsk(m, m.Ddc.Fetch));
    else
        value = meterDecode(m, readline(m.Port));
    end
end

function value = meterReadOnce(m)
% Trigger and collect as one exchange, where nothing is overlapped.

    if m.Ddc.Dialect == "scpi"
        value = meterDecode(m, meterAsk(m, m.Ddc.Read));
    else
        value = meterDecode(m, ddcAsk(m, ""));
    end
end

function value = meterDecode(m, reply)
    if m.Ddc.Dialect == "scpi"
        value = scpiDecode(reply, m.Ddc.Overflow);
    else
        value = ddcDecode(reply, m.Ddc.Prefixes);
    end
end

function value = ddcDecode(reply, prefixes)
% Reply is N/O + 3-letter function tag (196 manual fig 3-6) + mantissa.
% Overflow (O) decodes to NaN so the caller treats it as a fault instead of
% a full-scale number. The prefix match is required, not optional: a reply
% missing it (e.g. a stray status word) would otherwise parse as a
% plausible reading. Takes a string, not a port, so it can run offline.

    text   = extractBefore(strtrim(string(reply)) + ",", ",");   % G2 suffix
    prefix = regexp(text, "^[NO](" + prefixes + ")", "match", "once");

    if ismissing(prefix) || startsWith(prefix, "O")
        value = NaN;
        return
    end

    value = str2double(extractAfter(text, strlength(prefix)));
end

function value = scpiDecode(reply, overflow)
% 34401A returns 9.9E37 for an over-range reading, a valid-looking number
% that would otherwise land in the CSV as a measurement; treated as NaN.
% Takes a string, not a port, so it can run offline.

    value = str2double(strtrim(string(reply)));

    if abs(value) >= overflow
        value = NaN;
    end
end

function meterTell(m, command)

    if m.Ddc.Dialect == "scpi"
        writeline(m.Port, command);
    else
        ddcTell(m.Port, command);
    end
end

function reply = meterAsk(m, command)
% For commands that produce a reply. Both meters answer a setting command
% with nothing, so routing a set through here is a timeout on success.

    if m.Ddc.Dialect == "scpi"
        writeline(m.Port, command);
        reply = strtrim(string(readline(m.Port)));
        if strlength(reply) == 0
            error("PVLoad:MeterNoReply", ...
                "No reply to ""%s"" within %g s.", command, m.Timeout);
        end
    else
        reply = ddcAsk(m, command);
    end
end

function word = ddcAskStatus(m, command)
% The answer must be the status word, not a reading. ddcAsk's flush clears
% the host buffer, but a stale reading can sit in the meter itself and be
% handed out on the next talk. Seen as U1 answering "NDCI-00.00084E-3"
% after a clean identify. Readings are recognisable (N or O then a
% function tag), so up to two are read past.

    word = ddcAsk(m, command);
    for k = 1:2
        if startsWith(word, m.Ddc.IdPrefix) || ...
           ~startsWith(word, ["N", "O"])
            return
        end
        word = strtrim(string(readline(m.Port)));
    end
end

function ddcTell(port, command)
% Nothing happens on a 196 until an X arrives, so every command leaves
% through here and every one of them gets one. An empty command is a bare
% X, which under T5 is a trigger and nothing else.

    writeline(port, command + "X");
end

function reply = ddcAsk(m, command)
% Flushed first: under T5 every command string ends in an X and every X is
% a trigger, so a setup string leaves an uncollected reading and the next
% query reads that instead of its own answer, one behind from then on.
% Discarded rather than counted, because whether a string produces a
% reading depends on the trigger mode it is itself setting up.

    flush(m.Port, "input");
    ddcTell(m.Port, command);
    reply = strtrim(string(readline(m.Port)));
    if strlength(reply) == 0
        error("PVLoad:MeterNoReply", ...
            "No reply to ""%sX"" within %g s.", command, m.Timeout);
    end

    % The query's own X started a conversion and K2 leaves the bus unheld,
    % so a command following too closely is a latched TRIGGER OVERRUN. The
    % overlapped sweep path uses meterTrigger/meterFetch, not this.
    pause(0.1);
end

function closeMeters(meas)
% Closed without a reset, so an abort does not wipe the front panel setup.
    if ~isstruct(meas)
        return
    end
    quietly(@() closePort(meas.V));
    quietly(@() closePort(meas.I));
end

function closePort(m)
    if isstruct(m)
        delete(m.Port);
    end
end


%% =====================================================================
%  Timing
%  =====================================================================

function settle = settleFor(state, prevMode, cfg)
% The meter's integration window is deliberately absent: READ? blocks for
% it after this pause, so counting it here would only slow the sweep.

% Every term below is the board and the load, so this holds with the
% meters off as well; conversionTime is what goes to zero there.

    T = cfg.Timing;
    if state.Mode == prevMode
        tSwitch = T.WiperSettle;
    else
        tSwitch = T.RelaySettle;
    end

    settle = max(T.RelaySettle, ...
        T.Safety * (tSwitch + T.TauCount * state.Resistance * T.CLoad + ...
                    T.CellSettle));

    % Capped by what is left of the point's budget after the conversion and
    % the board, so the ceiling is on the state, not just the pause in it.
    settle = min(settle, settleCap(cfg));
end

function cap = settleCap(cfg)
% Never below the relay settle, a hardware minimum.
%
% This shortens the waiting and nothing else. The conversion runs to
% completion and a point that overruns still lands in the CSV. The budget
% decides how long the sweep pauses, not whether it measures.

    T = cfg.Timing;
    cap = T.Budget - T.Overhead - conversionTime(cfg);
    cap = max(T.RelaySettle, cap);
end

function reading = conversionTime(cfg)
% Overlapped, the pair costs the slower of the two; one at a time, both.

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

function results = runExperiment(board, meas, plan, cfg, log)
% Has to be a function, not script-level code. Ctrl-C in MATLAB is an
% interrupt, not an exception: it does not run catch blocks. onCleanup is
% the only thing that fires, and only when the workspace holding it is
% destroyed, which never happens to a script's base workspace. This
% function exists to give the guard a workspace to die with.

    guard = onCleanup(@() safeShutdown(board, meas, cfg));

    enterSafeState(board);
    fprintf("Board initialised to the safe state (OPEN).\n");

    if cfg.SelfTest
        selfTestPotentiometers(board);
    else
        fprintf("Self-test skipped. The potentiometers are unverified.\n");
    end

    results = runSweepAdaptive(board, meas, plan, cfg, log);

    enterSafeState(board);
    clear guard;
end

function results = runSweepAdaptive(board, meas, master, cfg, log)
% Coarse pass, then rounds of states added between measured neighbours
% until refineIntervals stops asking or the point cap lands. Refinement
% decides from the measured columns only; the master plan supplies the
% codes and the order. Every round runs in that order, so the settles see
% the same ascending walk.
%
% First point failing is misconfiguration; MaxFaults in a row aborts.

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
    queue   = coarseIndices(master, cfg);

    for round = 1:cfg.Adapt.MaxRounds
        for k = queue(:)'
            if row >= cap
                break
            end

            settle = settleFor(master(k), prev, cfg);
            applyState(board, master(k), settle);
            prev = master(k).Mode;

            [volts, amps, fault, meas] = readPoint(meas, cfg);

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
                appendPoints(log, results, (written + 1):row, written == 0);
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
        appendPoints(log, results, (written + 1):row, written == 0);
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
        1e3 * estimatePointTime(cfg, master));
    reportRangeChanges(meas);
end

function [next, noise] = refineIntervals(measured, V, I, cfg)
% Three rules, all read off the measured V and I, normalised to the
% measured span so one setting serves any cell:
%
%   - a segment longer than Gap is split whatever its shape, because a
%     knee can sit between two coarse states that both read tame.
%   - a point further than Bend off the chord of its neighbours is a bend;
%     both segments at it are split.
%   - the two segments at the largest measured power are always split.
%
% Splitting is by position in the master plan: the model orders, the
% measurements decide. A segment between plan neighbours cannot split
% further and drops out, which is what ends refinement. A NaN takes no
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
    % increasing load, so current can only fall and voltage only rise;
    % every step the wrong way is the illumination having moved between
    % readings. Both thresholds sit on top of it, so a light that will not
    % hold still widens what counts as a bend instead of splitting
    % segments whose shape is noise: the 0.55 A laser run wobbled ~10% and
    % spent a hundred states chasing it. A clean curve floors at zero.
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
% SHORT measured again at the end brackets the run: the cell has no
% memory, so a first and last reading that disagree are the illumination
% having moved while the sweep ran. Reported rather than corrected, and
% not a row in the CSV, so the sweep's own SHORT stays the Isc.

    at = find([master.Mode] == "SHORT", 1);
    first = find(results.Mode == "SHORT", 1);
    if ~meas.Enabled || isempty(at) || isempty(first) || ...
       isnan(results.CurrentA(first))
        return
    end

    applyState(board, master(at), settleFor(master(at), prev, cfg));
    try
        last = abs(meterReadOnce(meas.I));
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
% Perpendicular distance from the middle point to its neighbours' chord.
% A degenerate chord falls back to the plain distance to the first point.

    len = hypot(x3 - x1, y3 - y1);
    if len < eps
        d = hypot(x2 - x1, y2 - y1);
        return
    end
    d = abs((x3 - x1) * (y1 - y2) - (x1 - x2) * (y3 - y1)) / len;
end

function results = trimResults(results, n)
% Cut the preallocated rows an adaptive run did not use.

    for name = string(fieldnames(results))'
        results.(name) = results.(name)(1:n);
    end
end

function reportRangeChanges(meas)
    if meas.VChanges > 0
        fprintf("The voltmeter changed range %d time(s), ending on %g V.\n", ...
            meas.VChanges, meas.VRangeNow);
    end
    if meas.IChanges > 0
        fprintf("The ammeter changed range %d time(s), ending on %g mA. " + ...
            "A run that\nkeeps doing that is illumination moving, not a " + ...
            "cell moving along its curve.\n", ...
            meas.IChanges, 1e3 * meas.IRangeNow);
    end
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

function results = recordPoint(results, row, state, settle, volts, amps)
% Resistance and power come from the measured values, never from the wiper
% code: the tap code is a repeatable setting, not a known resistance.

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

function log = openLog(cfg, nStates)
% One file per run, never overwritten: the timestamp stops a second run
% landing on the first, and RUN_TAG is the only record of the lamp.

    log = struct('Readings', "");

    if ~cfg.Out.WriteCsv
        return
    end

    dir = resolvePath(cfg.Out.Dir);
    if ~isfolder(dir)
        mkdir(dir);
    end

    stamp = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
    tag   = strtrim(cfg.Out.Tag);
    if strlength(tag) > 0
        tag = "_" + tag;
    end

    log.Readings = string(fullfile(dir, "pvload_" + stamp + tag + ".csv"));

    fprintf("Logging to %s\n", log.Readings);
    fprintf("  at most %d states, written in blocks of %d.\n", ...
        min(cfg.Adapt.MaxPoints, nStates), cfg.Out.Chunk);
end

function appendPoints(log, results, rows, first)
% Called as each block of states finishes, so an abort keeps what it
% measured. The first call writes the header and the rest append.

    if strlength(log.Readings) == 0
        return
    end

    t = table( ...
        results.Timestamp(rows),     results.StateIndex(rows), ...
        results.Mode(rows),          results.Code1(rows), ...
        results.Code2(rows),         results.RNominal(rows), ...
        results.VoltageV(rows),      results.CurrentA(rows), ...
        results.ResistanceOhm(rows), results.PowerW(rows), ...
        results.SettleS(rows), ...
        'VariableNames', {'timestamp', 'state_index', 'mode', ...
            'u1_code', 'u2_code', 'r_nominal_ohm', 'voltage_v', ...
            'current_a', 'resistance_ohm', 'power_w', 'settle_s'});

    if first
        writetable(t, log.Readings);
    else
        writetable(t, log.Readings, 'WriteMode', 'append');
    end
end


%% =====================================================================
%  Shutdown
%  =====================================================================

function safeShutdown(board, meas, cfg)
% Every step guarded separately and none rethrow: this runs during an
% interrupt, and an error raised here would mask what caused the abort.
%
% Returning the board to OPEN is the whole job. The cell is still lit when
% this finishes; darkening it is the operator's, as lighting it was.

    try
        enterSafeState(board);
    catch
        warning("PVLoad:SafeStateFailed", ...
            "Could not return the board to OPEN. Power down the Arduino, " + ...
            "which releases every relay.");
    end

    closeMeters(meas);

    if cfg.Dmm.Enabled
        fprintf("Board returned to OPEN and the meters are closed.\n");
    end
end

function quietly(fn)
% Swallows whatever a teardown step throws, so a second failure cannot hide
% the first.
    try
        fn();
    catch
    end
end

function out = ternary(condition, a, b)
    if condition
        out = a;
    else
        out = b;
    end
end
