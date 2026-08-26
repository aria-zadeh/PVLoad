%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% TO STOP: press Ctrl-C ONCE and wait about three seconds.
%
% The cleanup handler turns the pump off and returns the board to OPEN. 
% Pressing it a second time can interrupt that handler.

clear;
clc;


%   "plan"    print the plan and the time estimate, open nothing
%   "board"   Arduino and PCB only
%   "ramp"    board only, climbing the resistance range slowly enough to
%             follow on a handheld meter across J1 and J3
%   "wiper"   board only, the pairs of states whose difference is one
%             wiper resistance and nothing else
%   "k3"      board only, four holds that say whether K3 closes
%   "verify"  board only, seven holds that between them exercise every
%             part of the board. the check for a freshly built one.
%   "edfa"    amplifier only
%   "meters"  electrometers only
%   "sweep"   the full experiment, written to CSV

RUN = "verify";  


% to find com ports: serialportlist("available")
% to find meter addresses: visadevlist

SERIAL_PORT = "COM4";                % Arduino com port

EDFA_ENABLED  = false;               % set to true if laser enabled
EDFA_PORT     = "COM5";              % amplifier port

DMM_ENABLED   = false;               % set to true if electrometers enabled
DMM_V_ADDRESS = "GPIB0::22::INSTR";  % meter across the cell
DMM_I_ADDRESS = "GPIB0::23::INSTR";  % meter in series with PV+




% roughly what your cell does at POWER_FULL. sizes the ammeter range and
% prints estimates only, never enters a result, so rough is fine. the one
% place it is not advisory is the 20 mA ceiling: the 617 has no range above
% it, so an ISC_FULL past that is refused rather than measured badly.

ISC_FULL   = 0.016;        % A, short-circuit current at POWER_FULL
VOC_FULL   = 9;            % V, open-circuit voltage at POWER_FULL
POWER_FULL = 100;          % mW, the power those two were seen at


% the amplifier sets pump current, not power, so measure the relation once.
% entry k of one array is the power at entry k of the other.
% fill with RUN = "edfa": step the current, record the power meter.
% 10-15 points, denser near the threshold knee. both must increase.
% leave empty and use LEVEL_MODE "current" until measured.

CAL_CURRENT_MA = [];       % pump current, mA
CAL_POWER_MW   = [];       % optical power at that current, mW

%   CAL_CURRENT_MA = [ 100  150  200  250  300  400  500  600];
%   CAL_POWER_MW   = [0.05  0.8  4.1  9.6   18   42   72  105];


% LEVEL_MODE reads LEVEL_VALUES as:
%   "current"  pump currents in mA, no calibration needed
%   "power"    optical powers in mW, looked up in the arrays above
%   "table"    ignores LEVEL_VALUES, uses every calibration point
%
% LEVEL_SPACING:
%   "list"     take the values literally
%   "linear"   read as [min max], generate LEVEL_COUNT points
%   "log"      same but logarithmic. use this for power: Voc goes as
%              log(P), so linear spacing crowds levels where nothing moves

LEVEL_MODE    = "table";
LEVEL_SPACING = "list";
LEVEL_VALUES  = [300 450 600];
LEVEL_COUNT   = 8;              % only for linear/log spacing
LEVEL_ORDER   = "ascend";       % sweep dim to bright

EDFA_CURRENT_LIMIT = 600;       % mA. device max is 1000. a level above
                                % this is refused, not clamped.
EDFA_WARMUP        = 900;       % s at the first level. 900 is the 15 min
                                % the stability spec is quoted after.
                                % 0 for a quick test.


% the 617 converts on a fixed schedule, so there is no integration time to
% trade against speed and nothing here to tune. a level costs about six
% minutes; RUN "plan" prints the estimate for the levels configured.

SETTLE_TIME  = 0.20;       % s per state with no meters. ignored once
                           % DMM_ENABLED, which computes the hold instead.
PRINT_STATUS = true;       % echo each state. off for long unattended runs.
SELF_TEST    = true;       % probe both pots over SPI first. false to test
                           % the flow on a bare Arduino with no board.

RAMP_STEPS = 80;           % states RUN "ramp" visits, spread evenly across
                           % the sweep. 2 to 769.
RAMP_DWELL = 4.0;          % s each state is held, in "ramp" and "wiper"
                           % both. an autoranging handheld needs a second
                           % or two to re-range and you need longer than
                           % that to write the number down.

WIPER_CODES = [0 255];
                           % code sums RUN "wiper" compares at. a wiper
                           % resistance that changes across them is not a
                           % wiper resistance. past 255 there is no LOW
                           % state to pair with, so those codes contribute
                           % a FULL row alone and walk U2 by itself.

WRITE_CSV = true;
OUT_DIR   = "../data/sweep_data";
RUN_TAG   = "";            % added to the file names, e.g. "cell3"


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BELOW HERE DESCRIBES THE HARDWARE. NOT TUNING.
% Only change it if the hardware changes, and change docs/HARDWARE.md too.


% pin map, docs/HARDWARE.md section 4. the SPI pins are fixed by the Uno's
% hardware SPI peripheral and cannot be reassigned.

BOARD_TYPE = "Uno";

PIN_SCK = "D13";           % SPI clock,          U1 SCK and U2 SCK
PIN_SDI = "D11";           % SPI MOSI, MCU->pot, U1 SDI and U2 SDI
PIN_SDO = "D12";           % SPI MISO, pot->MCU, U1 SDO and U2 SDO

PIN_CS_U1 = "D10";         % U1 CS#, active low
PIN_CS_U2 = "D9";          % U2 CS#, active low

PIN_K1_DRIVE = "D6";       % K1, 470 kohm bypass relay. HIGH bypasses it.
PIN_K2_DRIVE = "D7";       % K2, whole-load short relay. HIGH shorts the cell.
PIN_K3_DRIVE = "D8";       % K3, DigiPot 2 bypass relay. HIGH bypasses U2.

CODE_STEP     = 1;         % 1 visits all 769 states. raising it thins the
                           % sweep and breaks that count.
INCLUDE_SHORT = true;      % the Isc endpoint (K2 closed)
INCLUDE_OPEN  = true;      % the Voc endpoint (470 kohm in circuit)
VERIFY_WIPER  = true;      % read each wiper register back after writing


% orders the sweep and labels output. never enters a result.

R_AB_NOMINAL = 5000;       % ohms, one MCP41HV51-502 end to end
WIPER_STEPS  = 255;        % 8-bit ladder has 255 step resistors
R_WIPER      = 155;        % ohms per device, measured on board 2 with
                           % RUN "verify" at a 24 V span. the two chips
                           % agreed to 1%. docs/BRINGUP.md has the numbers.
                           % affects ordering and labels only.
R_CONTACT    = 0.150;      % ohms, reed contact resistance, maximum
R_OPEN_PATH  = 470e3;      % ohms, R1


% EDFA100P protocol, manual TTN118382-D02 Rev C sections 7.2 and 7.3.

EDFA_BAUD       = 115200;
EDFA_TERMINATOR = "CR";
EDFA_TIMEOUT    = 2.0;     % s, deadline for one reply
EDFA_QUIET_GAP  = 0.06;    % s of silence that ends a reply
EDFA_PROMPT     = "<";     % emitted on power up and after every command

EDFA_MAX_CURRENT  = 1000;  % mA, the device limit. not a setting.
EDFA_RAMP_STEP    = 50;    % mA per ramp step
EDFA_RAMP_DWELL   = 0.25;  % s between ramp steps
EDFA_ENABLE_DELAY = 4.0;   % s. manual specifies about 3 s to output.
EDFA_LEVEL_SETTLE = 10.0;  % s after a current change. this is the cell
                           % reaching thermal equilibrium, not the
                           % amplifier. unmeasured.
EDFA_TEMP_TARGET  = [];    % degC, or [] to leave the unit's own target
                           % alone. the operator may have set it.
EDFA_TEMP_TOL     = 0.5;   % degC that temp? may differ from target?
EDFA_VERIFY       = true;  % query every setting back after writing it


% meters. two Keithley 617 electrometers on GPIB, one on volts and one on
% amps. the 617 predates SCPI: a command is a letter and a number, several
% of them travel in one string, and none of them do anything until an X
% arrives. it has no serial port, so VISA over GPIB is the only way in.
% section and table numbers below are the 617 manual, 617-901-01 Rev G.

DMM_TIMEOUT      = 10;             % s, must exceed one conversion
DMM_CONVERSION   = 0.40;           % s from trigger to reading ready. table
                                   % 3-15 gives 365 ms or 780 ms depending
                                   % on function and range. there is no
                                   % integration time to set.
DMM_ZERO_CORRECT = true;           % null a range's own offset when it is set
DMM_V_RANGE      = 20;             % V. Voc is 9 V and the range below is 2 V.
DMM_V_RANGES     = [0.2 2 20 200]; % volts ranges R1 to R4. 250 V peak is
                                   % the input limit whatever the range.
DMM_I_RANGE      = 0;              % A, or 0 to pick per level from ISC_FULL
DMM_I_RANGES     = [2e-12 2e-11 2e-10 2e-9 2e-8 2e-7 2e-6 2e-5 ...
                    2e-4 2e-3 2e-2];
                                   % amps ranges R1 to R11, table 3-12.
DMM_PARALLEL     = true;           % trigger both meters, then collect both
DMM_MAX_FAULTS   = 5;              % consecutive read failures before abort

% Device-dependent commands, section 3.10. Range takes the R number, which
% is a position in the lists above. Common is everything independent of
% function and range, in order: baseline suppression off, display the
% electrometer and not the voltage source, read the electrometer and not
% the buffer, data store off, voltage source output off, send the prefix
% that flags an overflowed reading, clear the SRQ mask, stop holding the
% bus off until X has finished, and convert once per X. Those last two are
% what let the two meters run at the same time. ddcTell appends the X, so
% nothing here carries one.
DDC = struct( ...
    'Volts',     "F0", ...
    'Amps',      "F1", ...
    'Range',     "R%d", ...
    'ZeroCheck', "C%d", ...
    'ZeroCorr',  "Z%d", ...
    'Common',    "N0D0B0Q7O0G0M0K2T5", ...
    'Machine',   "U0", ...
    'Error',     "U1");


% settle = max(RELAY, SAFETY * (switch + TAUS * R * C_LOAD + CELL)).
% the conversion is deliberately absent: the trigger goes out after this
% pause and the reply blocks for it, so counting it here would only slow
% the sweep.

RELAY_SETTLE  = 0.010;     % s after a relay changes. HARDWARE.md s6;
                           % the relays themselves spec 1.0 ms.
WIPER_SETTLE  = 0.001;     % s after a wiper-only change. the pot settles
                           % in ~1 us; this is the SPI round trip.
SETTLE_SAFETY = 1.5;       % covers USB jitter and pause() granularity
RC_TAU_COUNT  = 7;         % time constants. e^-7 is 0.09%.
C_LOAD        = 300e-12;   % F, dominated by the leads. the 617 puts
                           % 20 pF of it across the load.
CELL_SETTLE   = 0;         % s for the cell's own junction capacitance.
                           % unmeasured, and the term that could actually
                           % matter. to find it: park at OPEN, take 50
                           % readings and see where they stop moving.

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
    'SettleTime',    SETTLE_TIME, ...
    'CodeStep',      CODE_STEP, ...
    'PrintStatus',   PRINT_STATUS, ...
    'IncludeShort',  INCLUDE_SHORT, ...
    'IncludeOpen',   INCLUDE_OPEN, ...
    'VerifyWiper',   VERIFY_WIPER, ...
    'SelfTest',      SELF_TEST, ...
    'RampSteps',     RAMP_STEPS, ...
    'RampDwell',     RAMP_DWELL, ...
    'WiperCodes',    WIPER_CODES, ...
    'RabNominal',    R_AB_NOMINAL, ...
    'WiperSteps',    WIPER_STEPS, ...
    'RWiper',        R_WIPER, ...
    'RContact',      R_CONTACT, ...
    'ROpenPath',     R_OPEN_PATH);

cfg.Levels = struct( ...
    'Mode',       LEVEL_MODE, ...
    'Spacing',    LEVEL_SPACING, ...
    'Values',     LEVEL_VALUES, ...
    'Count',      LEVEL_COUNT, ...
    'Order',      LEVEL_ORDER, ...
    'CalCurrentMa', CAL_CURRENT_MA(:), ...
    'CalPowerMw',   CAL_POWER_MW(:), ...
    'IscFull',    ISC_FULL, ...
    'PowerFull',  POWER_FULL, ...
    'VocFull',    VOC_FULL);

cfg.Edfa = struct( ...
    'Enabled',      EDFA_ENABLED, ...
    'Port',         EDFA_PORT, ...
    'Baud',         EDFA_BAUD, ...
    'Terminator',   EDFA_TERMINATOR, ...
    'Timeout',      EDFA_TIMEOUT, ...
    'QuietGap',     EDFA_QUIET_GAP, ...
    'Prompt',       EDFA_PROMPT, ...
    'MaxCurrent',   EDFA_MAX_CURRENT, ...
    'CurrentLimit', EDFA_CURRENT_LIMIT, ...
    'RampStep',     EDFA_RAMP_STEP, ...
    'RampDwell',    EDFA_RAMP_DWELL, ...
    'EnableDelay',  EDFA_ENABLE_DELAY, ...
    'Warmup',       EDFA_WARMUP, ...
    'LevelSettle',  EDFA_LEVEL_SETTLE, ...
    'TempTarget',   EDFA_TEMP_TARGET, ...
    'TempTol',      EDFA_TEMP_TOL, ...
    'Verify',       EDFA_VERIFY);

cfg.Dmm = struct( ...
    'Enabled',     DMM_ENABLED, ...
    'VAddress',    DMM_V_ADDRESS, ...
    'IAddress',    DMM_I_ADDRESS, ...
    'Timeout',     DMM_TIMEOUT, ...
    'Conversion',  DMM_CONVERSION, ...
    'ZeroCorrect', DMM_ZERO_CORRECT, ...
    'VRange',      DMM_V_RANGE, ...
    'VRanges',     DMM_V_RANGES, ...
    'IRange',      DMM_I_RANGE, ...
    'IRanges',     DMM_I_RANGES, ...
    'Parallel',    DMM_PARALLEL, ...
    'MaxFaults',   DMM_MAX_FAULTS, ...
    'Ddc',         DDC);

cfg.Timing = struct( ...
    'RelaySettle', RELAY_SETTLE, ...
    'WiperSettle', WIPER_SETTLE, ...
    'Safety',      SETTLE_SAFETY, ...
    'TauCount',    RC_TAU_COUNT, ...
    'CLoad',       C_LOAD, ...
    'CellSettle',  CELL_SETTLE);

cfg.Out = struct( ...
    'WriteCsv', WRITE_CSV, ...
    'Dir',      OUT_DIR, ...
    'Tag',      RUN_TAG);

assertConfig(cfg);

switch cfg.Run
    case "plan",   runPlanOnly(cfg);
    case "board",  runBoardCheck(cfg);
    case "ramp",   runRamp(cfg);
    case "wiper",  runWiperCheck(cfg);
    case "k3",     runK3Check(cfg);
    case "verify", runVerify(cfg);
    case "edfa",   runEdfaCheck(cfg);
    case "meters", runMeterCheck(cfg);
    case "sweep",  results = runSweepAll(cfg);
end


%% =====================================================================
%  Run modes
%  =====================================================================

function runPlanOnly(cfg)

    plan   = buildSweepPlan(cfg);
    levels = buildPowerPlan(cfg, loadCalibration(cfg));
    reportPlan(cfg, plan, levels);
    fprintf("\nNothing was opened. Set RUN to board, edfa, meters or " + ...
        "sweep to use hardware.\n");
end

function runBoardCheck(cfg)
% Arduino and PCB only, so SPI and the relays can be proved with no laser
% and no meters in the way.

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
% Board only, for watching the load change on a handheld meter clipped
% across J1 and J3 with no cell in the loop. Same states runBoardCheck
% walks, held long enough to read.
%
% The plan is already sorted by resistance, so stepping through it evenly
% climbs from the SHORT contact to the 470 kohm OPEN path without going
% back on itself. Relays click on the way, which is part of what is being
% checked.
%
% The printed ohms are the resistance model, not a measurement. R_WIPER is
% the datasheet worst case of 200 ohm and R_AB is +/-20%, so a meter that
% disagrees at the low end is the model being pessimistic rather than the
% board being wrong. That reading is worth keeping: it is what R_WIPER
% should be set to.

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
        % Printed before the state is applied, and flushed, so the console
        % says what is coming rather than what has already been and gone.
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
% Board only. Wiper resistance measured by difference, which is the only
% way to get it off a handheld: every reading shares the same probes,
% jacks and traces, so subtracting two of them cancels all of that.
%
% Writing s for the ladder step and taking FULL at a code sum of n, which
% splits as U1 = n and U2 = 0:
%
%   SHORT   = K2
%   LOW(n)  = K1 + Rw1 + n*s + K3
%   FULL(n) = K1 + Rw1 + n*s + Rw2
%
% so LOW(0) - SHORT is Rw1 and FULL(n) - LOW(n) is Rw2, both to within a
% reed contact, which is 0.150 ohm. Neither difference contains the leads,
% the jacks or K1, so a bad probe offset does not reach the answer.
%
% Repeating across codes is the check that matters. Rw2 is a switch, not a
% resistor, so the same number should come back at every code. A
% difference that tracks the code is R_AB being wrong instead.

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
        % alone and every further step is U2 moving on its own, which is
        % the only way to see U2 without a probe.
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
% Board only, for deciding whether a freshly assembled board is sound.
% Seven holds that between them touch both chips over SPI, all three
% relays, both ladders and R1. Nothing else on the board is load bearing.
%
% The pass conditions are comparisons rather than absolute numbers. A
% handheld carries its leads, its clips and both jacks in every reading,
% which is tens of ohms and drifts, and every check below is a difference
% or an order of magnitude, so none of them notice.
%
% Two holds are written straight to the pots rather than taken from the
% plan. LOW always carries a zero second code in a sweep, so no planned
% state drives U2 while K3 is meant to be shorting it out, which is
% exactly the case that catches a relay that never operates.

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

function runK3Check(cfg)
% Four holds and one question: does K3 close.
%
% K3 shorts out U2 whenever the board is in LOW, so U2's code cannot reach
% the terminals and all four holds have to read alike. If they do not, K3
% never operated and U2 has been in the path the whole time. That failure
% is invisible everywhere else on this board, because it only makes LOW and
% FULL read the same, which looks like a component with no resistance
% rather than a relay that did not move.
%
% The codes are written straight to the pots instead of coming from the
% plan, because no planned state drives U2 while K3 is closed.

    board = connectBoard(cfg);
    guard = onCleanup(@() quietly(@() enterSafeState(board)));

    enterSafeState(board);

    fprintf("\nFour holds, %g s each. Write down all four.\n", cfg.RampDwell);
    fprintf("All four alike means K3 closes. A jump of about 5000 ohm\n");
    fprintf("between them means it does not.\n\n");

    setMode(board, "LOW");
    labels = ["A" "B" "C" "D"];
    codes  = [0 255 0 255];
    for k = 1:4
        fprintf("  %s   U2 code %3d\n", labels(k), codes(k));
        drawnow;
        setWipers(board, 0, codes(k));
        pause(cfg.RampDwell);
    end

    enterSafeState(board);
    clear guard;
    fprintf("\nDone. Returned to OPEN.\n");
end

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
            "INCLUDE_SHORT is %d; both have to leave that state in.", ...
            mode, code, cfg.CodeStep, cfg.IncludeShort);
    end
end

function runEdfaCheck(cfg)
% Amplifier only. This is the laser bring-up, so it touches nothing else.

    if ~cfg.Edfa.Enabled
        error("PVLoad:EdfaDisabled", ...
            "RUN is ""edfa"" but EDFA_ENABLED is false.");
    end

    levels = buildPowerPlan(cfg, loadCalibration(cfg));
    edfa   = connectEdfa(cfg);
    guard  = onCleanup(@() quietly(@() edfaShutdown(edfa, true)));

    fprintf("target  %.2f degC\n", edfaNumber(edfa, "target"));
    fprintf("temp    %.2f degC\n", edfaNumber(edfa, "temp"));
    fprintf("current %.0f mA\n",   edfaNumber(edfa, "current"));
    fprintf("on      %d\n",        edfaIsOn(edfa));

    fprintf("\nEnabling. Output is live from here.\n");
    edfaSet(edfa, "enable", 1);
    pause(cfg.Edfa.EnableDelay);
    if ~edfaIsOn(edfa)
        error("PVLoad:EdfaWillNotEnable", ...
            "The amplifier did not turn on. The rear interlock must be " + ...
            "shorted before it will enable.");
    end

    for k = 1:numel(levels)
        edfaRampTo(edfa, levels(k).CurrentMa);
        fprintf("  %s -> readback %.0f mA, %.2f degC\n", ...
            describeLevel(levels(k)), edfaNumber(edfa, "current"), ...
            edfaNumber(edfa, "temp"));
        pause(cfg.Edfa.LevelSettle);
    end

    edfaShutdown(edfa, false);
    clear guard;
    fprintf("\nAmplifier OK. Pump at zero and disabled.\n");
end

function runMeterCheck(cfg)
% Meters only, so the command dialect and the wiring can be checked before
% a sweep depends on them.

    if ~cfg.Dmm.Enabled
        error("PVLoad:MetersDisabled", ...
            "RUN is ""meters"" but DMM_ENABLED is false.");
    end

    meas  = connectMeters(cfg);
    guard = onCleanup(@() quietly(@() closeMeters(meas)));

    setCurrentRange(meas, cfg.Levels.IscFull, cfg);

    fprintf("\nOne conversion takes about %.0f ms.\n", ...
        1e3 * cfg.Dmm.Conversion);
    fprintf("Ten readings:\n");
    for k = 1:10
        [v, i, fault] = readPoint(meas, cfg);
        fprintf("  %2d  V = %11.6f   I = %11.6f A%s\n", k, v, i, ...
            ternary(fault, "   (fault)", ""));
    end

    closeMeters(meas);
    clear guard;
    fprintf("\nMeters OK.\n");
end

function results = runSweepAll(cfg)

    cal    = loadCalibration(cfg);
    plan   = buildSweepPlan(cfg);
    levels = buildPowerPlan(cfg, cal);

    reportPlan(cfg, plan, levels);

    board = connectBoard(cfg);
    fprintf("Board connected.\n");

    edfa = connectEdfa(cfg);
    meas = connectMeters(cfg);
    log  = openLog(cfg, levels);

    results = runExperiment(board, edfa, meas, plan, levels, cfg, log);

    fprintf("\nRun complete. %d level(s) x %d states.\n", ...
        numel(levels), numel(plan));
    if ~isempty(log.Readings)
        fprintf("Readings: %s\n", log.Readings);
        fprintf("Levels:   %s\n", log.Levels);
    end
end


%% =====================================================================
%  Sweep planning
%  =====================================================================

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

function states = enumerateStates(cfg)
% LOW is listed before FULL so a resistance tie visits the LOW state first,
% putting one fewer wiper resistance in the path.

    step   = cfg.RabNominal / cfg.WiperSteps;
    states = makeState("", 0, 0, 0);
    states(:) = [];                       % empty struct array of the right shape

    if cfg.IncludeShort
        states(end+1) = makeState("SHORT", 0, 0, cfg.RContact);
    end

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

    if cfg.IncludeOpen
        r = cfg.ROpenPath + 2 * cfg.RWiper;
        states(end+1) = makeState("OPEN", 0, 0, r);
    end
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
%  Illumination planning
%  =====================================================================

function assertConfig(cfg)
% Catches a mistyped config block before anything is energised.

    mustBeOneOf(cfg.Run, ...
        ["plan" "board" "ramp" "wiper" "k3" "verify" "edfa" "meters" ...
         "sweep"], "RUN");

    if cfg.RampSteps < 2 || cfg.RampSteps > 769
        error("PVLoad:BadRampSteps", ...
            "RAMP_STEPS is %g. The sweep has 769 states and a ramp needs " + ...
            "at least 2 of them.", cfg.RampSteps);
    end
    if cfg.RampDwell <= 0
        error("PVLoad:BadRampDwell", "RAMP_DWELL must be positive.");
    end
    if isempty(cfg.WiperCodes) || any(cfg.WiperCodes < 0) || ...
       any(cfg.WiperCodes > 2 * cfg.WiperSteps) || ...
       any(mod(cfg.WiperCodes, 1) ~= 0)
        error("PVLoad:BadWiperCodes", ...
            "WIPER_CODES must be whole numbers from 0 to %d, which is the " + ...
            "range of a FULL code sum.", 2 * cfg.WiperSteps);
    end

    L = cfg.Levels;
    mustBeOneOf(L.Mode,    ["current" "power" "table"], "LEVEL_MODE");
    mustBeOneOf(L.Spacing, ["list" "linear" "log"],     "LEVEL_SPACING");
    mustBeOneOf(L.Order,   ["ascend" "descend"],        "LEVEL_ORDER");

    if L.Spacing ~= "list" && numel(L.Values) ~= 2
        error("PVLoad:BadLevelRange", ...
            "LEVEL_SPACING ""%s"" reads LEVEL_VALUES as [min max], " + ...
            "but it has %d elements.", L.Spacing, numel(L.Values));
    end

    E = cfg.Edfa;
    if E.CurrentLimit > E.MaxCurrent
        error("PVLoad:CurrentLimitTooHigh", ...
            "EDFA_CURRENT_LIMIT is %g mA but the device maximum is %g mA.", ...
            E.CurrentLimit, E.MaxCurrent);
    end
    if E.RampStep <= 0
        error("PVLoad:BadRampStep", "EDFA_RAMP_STEP must be positive.");
    end
    if E.Enabled && cfg.SerialPort == E.Port
        error("PVLoad:PortConflict", ...
            "The Arduino and the amplifier are both set to %s.", E.Port);
    end

    D = cfg.Dmm;
    if D.Enabled && D.VAddress == D.IAddress
        error("PVLoad:MeterAddressConflict", ...
            "Both meters are set to %s. They need separate addresses.", ...
            D.VAddress);
    end
    if D.Enabled && D.Timeout <= D.Conversion
        error("PVLoad:MeterTimeoutTooShort", ...
            "DMM_TIMEOUT is %g s but one conversion takes %g s.", ...
            D.Timeout, D.Conversion);
    end
    if D.Enabled
        % Every range is named, so one that does not exist is a config
        % error here rather than something the meter sorts out later.
        rangeCode(D.VRange, D.VRanges, "DMM_V_RANGE");
        if D.IRange > 0
            rangeCode(D.IRange, D.IRanges, "DMM_I_RANGE");
        end
    end
    if D.Enabled && cfg.Levels.VocFull > D.VRange
        error("PVLoad:VocAboveMeterRange", ...
            "VOC_FULL is %g V but DMM_V_RANGE is %g V, so the OPEN point " + ...
            "would overflow.", cfg.Levels.VocFull, D.VRange);
    end
    if D.Enabled && cfg.Levels.IscFull > max(D.IRanges)
        error("PVLoad:IscAboveMeterRange", ...
            "ISC_FULL is %g A and the 617 stops at %g A. Nothing in the " + ...
            "instrument goes higher, so the cell has to be measured " + ...
            "through a shunt or at a lower illumination.", ...
            cfg.Levels.IscFull, max(D.IRanges));
    end
end

function mustBeOneOf(value, allowed, name)
    if ~any(string(value) == allowed)
        error("PVLoad:BadOption", "%s must be one of %s, not ""%s"".", ...
            name, strjoin("""" + allowed + """", ", "), string(value));
    end
end

function cal = loadCalibration(cfg)
% Empty is not an error: LEVEL_MODE "current" does not need it.

    cal = [];
    if isempty(cfg.Levels.CalCurrentMa) && isempty(cfg.Levels.CalPowerMw)
        return
    end

    if numel(cfg.Levels.CalCurrentMa) ~= numel(cfg.Levels.CalPowerMw)
        error("PVLoad:CalibrationLengthMismatch", ...
            "CAL_CURRENT_MA has %d entries and CAL_POWER_MW has %d. Entry " + ...
            "k of one is the power at entry k of the other, so they have " + ...
            "to be the same length.", ...
            numel(cfg.Levels.CalCurrentMa), numel(cfg.Levels.CalPowerMw));
    end

    cal = struct('CurrentMa', cfg.Levels.CalCurrentMa(:), ...
                 'PowerMw',   cfg.Levels.CalPowerMw(:), ...
                 'Path',      "CAL_CURRENT_MA / CAL_POWER_MW");
end

function path = resolvePath(relative)
% Resolved against this file's folder, so the current directory does not
% matter.
    if isfile(relative) || isfolder(relative)
        path = char(relative);
        return
    end
    here = fileparts(mfilename("fullpath"));
    path = fullfile(here, char(relative));
end

function assertCalibrationUsable(cal, cfg)
% Inverted to solve for current, so both arrays must strictly increase.
% Non-monotonic data means the measurement is wrong, which deserves a
% human rather than a silent sort.

    if isempty(cal)
        error("PVLoad:NoCalibration", ...
            "LEVEL_MODE ""%s"" needs the calibration arrays, but " + ...
            "CAL_CURRENT_MA and CAL_POWER_MW at the top of this file are " + ...
            "empty. Measure them, or use LEVEL_MODE ""current"" to give " + ...
            "pump currents directly.", cfg.Levels.Mode);
    end
    if numel(cal.CurrentMa) < 2
        error("PVLoad:CalibrationTooShort", ...
            "CAL_CURRENT_MA has %d entry. At least 2 are needed to " + ...
            "interpolate between.", numel(cal.CurrentMa));
    end

    checkIncreasing(cal.CurrentMa, "CAL_CURRENT_MA");
    checkIncreasing(cal.PowerMw,   "CAL_POWER_MW");

    bad = cal.CurrentMa < 0 | cal.CurrentMa > cfg.Edfa.MaxCurrent;
    if any(bad)
        error("PVLoad:CalibrationOutOfRange", ...
            "CAL_CURRENT_MA entry %d is %g mA, outside 0 to %g mA.", ...
            find(bad, 1), cal.CurrentMa(find(bad, 1)), cfg.Edfa.MaxCurrent);
    end
end

function checkIncreasing(values, name)
    k = find(diff(values) <= 0, 1);
    if ~isempty(k)
        error("PVLoad:CalibrationNotMonotonic", ...
            "%s is not strictly increasing: entry %d is %g and entry %d " + ...
            "is %g. The arrays are inverted to solve for pump current, " + ...
            "which a non-monotonic one makes ambiguous.", ...
            name, k, values(k), k + 1, values(k + 1));
    end
end

function levels = buildPowerPlan(cfg, cal)
% The ordered list of illumination levels the sweep is repeated at.

    L = cfg.Levels;

    if ~cfg.Edfa.Enabled
        levels = makeLevel(1, NaN, NaN, "ambient", cfg);
        return
    end

    switch L.Mode
        case "current"
            currents = round(expandValues(L, "mA"));
            powers   = currentToPower(cal, currents);
            source   = "current";

        case "power"
            assertCalibrationUsable(cal, cfg);
            currents = powerToCurrent(cal, expandValues(L, "mW"), cfg);
            % Report the power the rounded current actually delivers, not
            % the power that was asked for.
            powers   = currentToPower(cal, currents);
            source   = "power";

        case "table"
            assertCalibrationUsable(cal, cfg);
            currents = round(cal.CurrentMa);
            powers   = cal.PowerMw;
            source   = "table";
    end

    [currents, keep] = unique(currents, "stable");
    powers = powers(keep);

    [currents, order] = sort(currents, L.Order);
    powers = powers(order);

    overLimit = currents > cfg.Edfa.CurrentLimit;
    if any(overLimit)
        error("PVLoad:CurrentOverLimit", ...
            "Level %d needs %g mA but EDFA_CURRENT_LIMIT is %g mA. " + ...
            "Raise the limit deliberately or drop the level.", ...
            find(overLimit, 1), currents(find(overLimit, 1)), ...
            cfg.Edfa.CurrentLimit);
    end

    levels = repmat(makeLevel(1, currents(1), powers(1), source, cfg), ...
                    numel(currents), 1);
    for k = 2:numel(currents)
        levels(k) = makeLevel(k, currents(k), powers(k), source, cfg);
    end
end

function values = expandValues(L, unit)

    switch L.Spacing
        case "list"
            values = L.Values(:);
        case "linear"
            values = linspace(L.Values(1), L.Values(2), L.Count)';
        case "log"
            if any(L.Values <= 0)
                error("PVLoad:BadLogRange", ...
                    "LEVEL_SPACING ""log"" needs both endpoints above " + ...
                    "zero, got [%g %g] %s.", L.Values(1), L.Values(2), unit);
            end
            values = logspace(log10(L.Values(1)), log10(L.Values(2)), L.Count)';
    end
end

function mA = powerToCurrent(cal, mW, cfg)
% Linear only: a spline can overshoot non-monotonically and destroy the
% inverse it is being used to compute. Extrapolation is refused rather
% than clamped, because guessing an unmeasured laser drive current is not
% something to do quietly.

    mA = interp1(cal.PowerMw, cal.CurrentMa, mW(:), "linear", NaN);

    bad = find(isnan(mA), 1);
    if ~isempty(bad)
        error("PVLoad:PowerOutOfRange", ...
            "%g mW is outside the calibrated range %g to %g mW covered by " + ...
            "CAL_POWER_MW. Measure more points rather than extrapolating.", ...
            mW(bad), min(cal.PowerMw), max(cal.PowerMw));
    end

    mA = round(mA);          % current=n takes an integer
    mA = min(mA, cfg.Edfa.MaxCurrent);
end

function mW = currentToPower(cal, mA)
% Labelling only, so NaN outside the table is fine.
    if isempty(cal)
        mW = nan(size(mA));
        return
    end
    mW = interp1(cal.CurrentMa, cal.PowerMw, mA(:), "linear", NaN);
end

function level = makeLevel(index, currentMa, powerMw, source, cfg)
% OpenFraction: the 470 kohm path draws a fixed current while Isc scales
% with light, so at low power the OPEN point stops being a Voc reading.

    L = cfg.Levels;

    if isnan(powerMw)
        iscExpected = NaN;
    else
        iscExpected = L.IscFull * powerMw / L.PowerFull;
    end

    % Current drawn through the 470 kohm path at the OPEN point, as a
    % fraction of the cell's short-circuit current. That current is fixed
    % while Isc scales with illumination, so at low power the OPEN point
    % stops being an open-circuit measurement.
    openFraction = (L.VocFull / cfg.ROpenPath) / iscExpected;

    level = struct( ...
        'Index',           index, ...
        'CurrentMa',       currentMa, ...
        'PowerMw',         powerMw, ...
        'Source',          string(source), ...
        'IscExpected',     iscExpected, ...
        'OpenFraction',    openFraction, ...
        'CurrentReadback', NaN, ...
        'TempC',           NaN, ...
        'IRange',          NaN, ...
        'Faults',          0, ...
        'Valid',           true);
end

function reportPlan(cfg, plan, levels)
% Everything needed to decide whether to let it run, before anything opens.

    perPoint = estimatePointTime(cfg, plan);
    settling = numel(levels) * cfg.Edfa.LevelSettle * double(cfg.Edfa.Enabled);
    warmup   = cfg.Edfa.Warmup * double(cfg.Edfa.Enabled);
    total    = numel(levels) * perPoint * numel(plan) + settling + warmup;

    fprintf("Sweep plan: %d load states, %g ohm to %g ohm.\n", ...
        numel(plan), plan(1).Resistance, plan(end).Resistance);
    fprintf("Illumination: %d level(s).\n", numel(levels));

    for k = 1:numel(levels)
        fprintf("  %s\n", describeLevel(levels(k)));
        if levels(k).OpenFraction > 0.05
            warning("PVLoad:OpenPointWeak", ...
                "Level %d draws %.1f%% of Isc through the 470 kohm path. " + ...
                "The OPEN point is not a Voc measurement at this " + ...
                "illumination.", k, 100 * levels(k).OpenFraction);
        end
    end

    if cfg.Dmm.Enabled
        fprintf("Meters: two Keithley 617, %.0f ms per conversion%s.\n", ...
            1e3 * cfg.Dmm.Conversion, ...
            ternary(cfg.Dmm.Parallel, ", overlapped", ""));
    else
        fprintf("Meters: none. Voltage and current will be logged as NaN.\n");
    end

    fprintf("About %.0f ms per point. Estimated run time %.1f minutes.\n", ...
        1e3 * perPoint, total / 60);
    if warmup > 0
        fprintf("  including a %.0f minute warm-up at the first level.\n", ...
            warmup / 60);
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
        reads = 1 + double(~cfg.Dmm.Parallel);   % overlapped or one at a time
        t = t + reads * cfg.Dmm.Conversion + 0.02;
    end
end

function text = describeLevel(level)
    if isnan(level.CurrentMa)
        text = "ambient light, amplifier not in use";
        return
    end
    if isnan(level.PowerMw)
        text = sprintf("level %d: %g mA", level.Index, level.CurrentMa);
    else
        text = sprintf("level %d: %g mA, about %.3g mW, Isc about %.3g mA", ...
            level.Index, level.CurrentMa, level.PowerMw, ...
            1e3 * level.IscExpected);
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
    board.SettleTime = cfg.SettleTime;
    board.Print      = cfg.PrintStatus;
    board.Verify     = cfg.VerifyWiper;

    configurePin(a, cfg.PinK1, "DigitalOutput");
    configurePin(a, cfg.PinK2, "DigitalOutput");
    configurePin(a, cfg.PinK3, "DigitalOutput");
end

function assertSpiPins(a, cfg)
% SPI pins are fixed by the hardware peripheral, so an edited pin map must
% fail loudly instead of silently describing the wrong wiring.

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
% Read command 0x0C. The answer clocks out in the second byte. The first
% byte's status bits are not decoded, because comparing the code already
% catches every failure they would report.

    out  = writeRead(dev, uint8([12, 0]), 'uint8');
    code = double(out(2));
end

function verifyWiper(dev, expected, label)
    actual = readWiper(dev);
    if actual ~= expected
        error("PVLoad:WiperMismatch", ...
            "%s did not take the wiper code: wrote %d, read back %d. " + ...
            "Check the chip select wiring, the SDO line, and that SHDN# " + ...
            "is held high. Set VERIFY_WIPER to false to sweep blind.", ...
            label, expected, actual);
    end
end

function setWipers(board, code1, code2)
% U2 is written even when K3 bypasses it, so it is never left unknown.
    writeWiper(board.U1, code1);
    writeWiper(board.U2, code2);

    if board.Verify
        verifyWiper(board.U1, code1, "U1");
        verifyWiper(board.U2, code2, "U2");
    end
end

function selfTestPotentiometers(board)
% The only check that the SPI link is bidirectional and that each chip
% select reaches the chip it should. HARDWARE.md section 6: a bad supply
% sequence silently forces the wiper to mid-scale.

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
% Also where the board lands on an Arduino reset, entered deliberately.
    setMode(board, "OPEN");
    setWipers(board, 0, 0);
    pause(board.SettleTime);
end


%% =====================================================================
%  EDFA100P control
%  =====================================================================
%  Serial settings and the command set are from the operating manual,
%  Thorlabs TTN118382-D02 Rev C, sections 7.2 and 7.3.

function edfa = connectEdfa(cfg)

    edfa = struct('Enabled', false, 'Port', [], 'Id', "", 'Cfg', cfg.Edfa);

    if ~cfg.Edfa.Enabled
        fprintf("Amplifier disabled. Running one ambient-light sweep.\n");
        return
    end

    try
        port = serialport(cfg.Edfa.Port, cfg.Edfa.Baud);
    catch openError
        error("PVLoad:EdfaPortFailed", ...
            "Could not open %s at %d baud: %s\nPorts available now: %s", ...
            cfg.Edfa.Port, cfg.Edfa.Baud, openError.message, ...
            strjoin(cellstr(serialportlist("available")), ", "));
    end

    configureTerminator(port, cfg.Edfa.Terminator);
    port.Timeout = cfg.Edfa.Timeout;

    edfa.Port    = port;
    edfa.Enabled = true;

    % Clear the power-up prompt and anything a previous session left behind,
    % so the first real query is not answered by stale bytes.
    flush(port);
    writeline(port, "");
    edfaCollect(edfa, 0.5);

    edfa.Id = edfaAsk(edfa, "id?");
    fprintf("Amplifier: %s\n", edfa.Id);

    edfaAssertReady(edfa, cfg);
end

function text = edfaCollect(edfa, deadline)
% readline is the wrong primitive here: the "<" prompt has no terminator
% after it, so readline would block the full timeout on every prompt.
% Never throws. An empty return is a distinguishable outcome.

    text  = '';
    began = tic;
    quiet = tic;

    while toc(began) < deadline
        n = edfa.Port.NumBytesAvailable;
        if n > 0
            text  = [text, read(edfa.Port, n, "char")];  %#ok<AGROW>
            quiet = tic;
            if contains(text, edfa.Cfg.Prompt) && any(text == char(13))
                break
            end
        elseif ~isempty(text) && toc(quiet) > edfa.Cfg.QuietGap
            break
        else
            pause(0.005);
        end
    end
end

function reply = edfaAsk(edfa, query)

    writeline(edfa.Port, query);
    raw = edfaCollect(edfa, edfa.Cfg.Timeout);

    reply = edfaDecode(raw, query, edfa.Cfg, true);
end

function edfaTell(edfa, command)
% A keyword=value command is answered with nothing but a fresh prompt, so
% silence is success. Only queries demand a reply.

    writeline(edfa.Port, command);
    raw = edfaCollect(edfa, edfa.Cfg.Timeout);

    edfaDecode(raw, command, edfa.Cfg, false);
end

function reply = edfaDecode(raw, command, ecfg, requireReply)
% Kept off the serial port so it can be driven from captured strings.
% Every guess about this interface lives here.

    text  = regexprep(string(raw), "\r\n?|\n", newline);   % normalise line ends
    text  = regexprep(text, "<\s*", "");                   % drop every prompt
    lines = strtrim(split(text, newline));
    lines(strlength(lines) == 0) = [];

    stem = regexprep(string(command), "[?=].*$", "");
    lines(strcmpi(lines, command)) = [];                   % full echo
    lines(startsWith(lines, stem + "?", "IgnoreCase", true) | ...
          startsWith(lines, stem + "=", "IgnoreCase", true)) = [];   % prefix echo

    failed = contains(lines, "Command error", "IgnoreCase", true) | ...
             contains(lines, "CMD_NOT_DEFINED", "IgnoreCase", true);
    if any(failed)
        error("PVLoad:EdfaCommandError", ...
            "The amplifier rejected ""%s"": %s", command, lines(find(failed, 1)));
    end

    if isempty(lines)
        if ~requireReply
            reply = "";
            return
        end
        error("PVLoad:EdfaNoReply", ...
            "No reply to ""%s"" on %s at %d baud within %.1f s. The port " + ...
            "may be wrong, or the Thorlabs GUI may be holding it open.", ...
            command, ecfg.Port, ecfg.Baud, ecfg.Timeout);
    end

    reply = lines(1);
end

function value = edfaNumber(edfa, keyword)
    value = edfaParseNumber(edfaAsk(edfa, keyword + "?"), keyword);
end

function value = edfaParseNumber(reply, keyword)
% A pattern rather than str2double, so a unit suffix like "450 mA" does
% not turn the reply into NaN.

    token = regexp(string(reply), "[-+]?\d+(\.\d+)?([eE][-+]?\d+)?", ...
                   "match", "once");

    % On no match regexp hands back a missing string, not an empty one, and
    % strlength(missing) is NaN rather than 0. Test for missing first or the
    % guard silently never fires.
    if ismissing(token) || strlength(token) == 0
        error("PVLoad:EdfaNotNumeric", ...
            "Expected a number from ""%s?"" but got ""%s"".", keyword, reply);
    end
    value = str2double(token);
end

function edfaSet(edfa, keyword, value)
% Read back after writing, same policy as the wiper registers: a
% write-only link cannot tell a working amplifier from an unplugged one.

    edfaTell(edfa, sprintf("%s=%d", keyword, round(value)));

    if ~edfa.Cfg.Verify
        return
    end

    actual = edfaNumber(edfa, keyword);
    if abs(actual - value) > 0.5
        error("PVLoad:EdfaSetFailed", ...
            "%s did not take: wrote %g, read back %g.", keyword, value, actual);
    end
end

function on = edfaIsOn(edfa)
    on = edfaDecodeStatword(edfaAsk(edfa, "statword?"));
end

function on = edfaDecodeStatword(reply)
% The manual's wording is ambiguous between "10000001" and "129". Both
% are handled, and they agree.
    token = regexprep(string(reply), "[^0-9A-Za-z]", "");

    if strlength(token) == 8 && all(ismember(char(token), '01'))
        on = extractAfter(token, 7) == "1";
    else
        on = bitand(uint16(str2double(token)), 1) == 1;
    end
end

function edfaAssertReady(edfa, cfg)

    if ~isempty(cfg.Edfa.TempTarget)
        edfaSet(edfa, "target", cfg.Edfa.TempTarget);
    end

    target = edfaNumber(edfa, "target");
    actual = edfaNumber(edfa, "temp");

    if abs(actual - target) > cfg.Edfa.TempTol
        warning("PVLoad:EdfaTempUnsettled", ...
            "Pump temperature is %.2f degC against a target of %.2f. The " + ...
            "manual allows 1 to 2 minutes to stabilise after power-up.", ...
            actual, target);
    end
end

function edfaRampTo(edfa, targetMa)
% Stepped rather than jumped, which keeps the pump's thermal loop in range.

    limit  = min(edfa.Cfg.CurrentLimit, edfa.Cfg.MaxCurrent);
    target = max(0, min(round(targetMa), limit));

    % Rounded, because the loop below closes an integer gap in integer steps.
    % A fractional reading would step past the target forever.
    present = round(edfaNumber(edfa, "current"));

    while abs(present - target) > 0
        step    = min(edfa.Cfg.RampStep, abs(target - present));
        present = present + sign(target - present) * step;
        edfaSet(edfa, "current", present);
        pause(edfa.Cfg.RampDwell);
    end
end

function edfaWarmUp(edfa, level, cfg)
% The output stability spec is quoted after 15 minutes, so this hold is
% what makes the first level comparable with the last.

    if ~edfa.Enabled
        return
    end

    edfaSet(edfa, "enable", 1);
    pause(cfg.Edfa.EnableDelay);        % the manual specifies about 3 s

    if ~edfaIsOn(edfa)
        error("PVLoad:EdfaWillNotEnable", ...
            "The amplifier did not turn on. The rear interlock must be " + ...
            "shorted before it will enable.");
    end

    edfaRampTo(edfa, level.CurrentMa);

    if cfg.Edfa.Warmup > 0
        fprintf("Warming up for %.0f minutes at %g mA.\n", ...
            cfg.Edfa.Warmup / 60, level.CurrentMa);
        pause(cfg.Edfa.Warmup);
    end
end

function level = edfaApplyLevel(edfa, level, cfg)

    if ~edfa.Enabled
        return
    end

    edfaRampTo(edfa, level.CurrentMa);

    if ~edfaIsOn(edfa)
        error("PVLoad:EdfaInterlock", ...
            "The amplifier is off at level %d. If the interlock opened, " + ...
            "the manual requires a deliberate re-enable; this script will " + ...
            "not do that on its own.", level.Index);
    end

    level.CurrentReadback = edfaNumber(edfa, "current");
    level.TempC           = edfaNumber(edfa, "temp");

    pause(cfg.Edfa.LevelSettle);
end

function edfaShutdown(edfa, emergency)
% Never throws: every abort path ends here. enable=0 goes first and alone
% on an emergency, because it takes effect at once and the graceful ramp
% is a courtesy for a normal exit.

    if ~isstruct(edfa) || ~edfa.Enabled || isempty(edfa.Port)
        return
    end

    if ~emergency
        quietly(@() edfaRampTo(edfa, 0));
    end
    quietly(@() writeline(edfa.Port, "enable=0"));
end


%% =====================================================================
%  Multimeters
%  =====================================================================

function meas = connectMeters(cfg)

    meas = struct('Enabled', false, 'V', [], 'I', [], ...
                  'VId', "", 'IId', "", 'Faults', 0, 'Cfg', cfg.Dmm);

    if ~cfg.Dmm.Enabled
        return
    end

    meas.V = openMeter(cfg, cfg.Dmm.VAddress, "voltage");
    meas.I = openMeter(cfg, cfg.Dmm.IAddress, "current");

    meas.VId = identifyMeter(meas.V, "voltage", cfg);
    meas.IId = identifyMeter(meas.I, "current", cfg);
    fprintf("Voltage meter: %s\n", meas.VId);
    fprintf("Current meter: %s\n", meas.IId);

    configureMeter(meas.V, "voltage", cfg.Dmm.VRange, cfg);
    configureMeter(meas.I, "current", pickCurrentRange(cfg.Levels.IscFull, cfg), cfg);

    meas.Enabled = true;
end

function handle = openMeter(cfg, address, role)
% The one place a transport is chosen, and on a 617 there is only the one:
% the rear panel carries an IEEE-488 connector and nothing else.

    try
        handle = visadev(address);
        handle.Timeout = cfg.Dmm.Timeout;
        % Replies end CR LF and the command parser ignores both, so reads
        % match the pair and writes send the one LF writeline appends.
        configureTerminator(handle, "CR/LF", "LF");
    catch openError
        error("PVLoad:MeterOpenFailed", ...
            "Could not open the %s meter at %s over VISA: %s\n%s", ...
            role, address, openError.message, availableResources());
    end
end

function text = availableResources()
% Put whatever the machine can see into the failure message.

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

function word = identifyMeter(handle, role, cfg)
% There is no *IDN?. The U0 query returns the machine status word, which
% opens with the model number and then spells out the whole front panel
% setup, so one query identifies the instrument and reports its state.
% Format is 617 F RR C Z N T O B G D Q MM K YY, figure 3-11.

    word = ddcAsk(handle, cfg.Dmm.Ddc.Machine, cfg);
    if ~startsWith(word, "617")
        error("PVLoad:MeterNotA617", ...
            "The %s meter answered U0 with ""%s"". A 617 opens its status " + ...
            "word with its model number.", role, word);
    end
end

function configureMeter(handle, role, range, cfg)
% Function and range travel together because an R number means a different
% range in every function. Then the offset is nulled for the range just
% selected, then the error queue is read.

    D = cfg.Dmm.Ddc;

    if role == "voltage"
        command = D.Volts + ...
            sprintf(D.Range, rangeCode(range, cfg.Dmm.VRanges, "DMM_V_RANGE"));
    else
        command = D.Amps + ...
            sprintf(D.Range, rangeCode(range, cfg.Dmm.IRanges, "DMM_I_RANGE"));
    end

    ddcTell(handle, command + D.Common);
    zeroCorrect(handle, cfg);
    assertMeterHappy(handle, role, cfg);
end

function zeroCorrect(handle, cfg)
% Section 3.10.4. Zero check shorts the input to the ranging amplifier, so
% the offset has to be captured with it on and then applied with it off:
% C1, Z1, C0, a conversion apart so each has taken effect before the next.
% A correction belongs to one range, which is why this runs again whenever
% the range moves.

    D = cfg.Dmm.Ddc;

    if ~cfg.Dmm.ZeroCorrect
        ddcTell(handle, sprintf(D.ZeroCheck, 0));
        return
    end

    ddcTell(handle, sprintf(D.ZeroCheck, 1) + sprintf(D.ZeroCorr, 0));
    pause(cfg.Dmm.Conversion);
    ddcTell(handle, sprintf(D.ZeroCorr, 1));
    pause(cfg.Dmm.Conversion);
    ddcTell(handle, sprintf(D.ZeroCheck, 0));
    pause(cfg.Dmm.Conversion);
end

function assertMeterHappy(handle, role, cfg)
% The U1 query returns the error condition word: the model number and then
% one digit per error, figure 3-12. Anything but zeros means the 617 threw
% a command back, which on this bench means a letter in the DDC block at
% the top of this file is not one it knows.

    word  = ddcAsk(handle, cfg.Dmm.Ddc.Error, cfg);
    flags = extractAfter(word, "617");

    if ismissing(flags) || strlength(flags) == 0 || any(char(flags) ~= '0')
        error("PVLoad:MeterRejectedSetup", ...
            "The %s meter answered U1 with ""%s"".", role, word);
    end
end

function code = rangeCode(range, ranges, name)
% R1 is the most sensitive range of a function and they climb by decades,
% so the R number is a position in the list. Table 3-12.

    code = find(abs(ranges - range) <= 1e-9 * ranges, 1);
    if isempty(code)
        error("PVLoad:BadMeterRange", ...
            "%s is %g. The 617 has %s.", ...
            name, range, strjoin(string(ranges), ", "));
    end
end

function range = pickCurrentRange(iscExpected, cfg)
% Isc scales with illumination, so the range is chosen once per level and
% not per point: a range change costs a fresh zero correction, and 769 of
% those per level would be absurd.
%
% Autorange exists, as R0, and is not used. A range hunt inside a settled
% point spends conversions on the wrong range, and the answer it would
% arrive at is already known from ISC_FULL.

    if cfg.Dmm.IRange > 0
        range = cfg.Dmm.IRange;
        return
    end
    if isnan(iscExpected) || iscExpected <= 0
        range = max(cfg.Dmm.IRanges);
        return
    end

    fits = cfg.Dmm.IRanges(cfg.Dmm.IRanges >= 1.2 * iscExpected);
    if isempty(fits)
        range = max(cfg.Dmm.IRanges);
    else
        range = min(fits);
    end
end

function meas = setCurrentRange(meas, iscExpected, cfg)
    if ~meas.Enabled
        return
    end
    configureMeter(meas.I, "current", pickCurrentRange(iscExpected, cfg), cfg);
end

function [volts, amps, fault] = readPoint(meas, cfg)
% Both meters are triggered before either reply is collected, so the two
% conversions overlap. T5 makes the X that ends a command the trigger, and
% K2 stops the 617 holding the bus off until that conversion finishes,
% which is what lets the second trigger leave while the first is running.
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
            ddcTell(meas.V, "");
            ddcTell(meas.I, "");
            volts = k617Decode(readline(meas.V));
            amps  = k617Decode(readline(meas.I));
        else
            volts = k617Decode(ddcAsk(meas.V, "", cfg));
            amps  = k617Decode(ddcAsk(meas.I, "", cfg));
        end
    catch
        fault = true;
    end

    fault = fault || isnan(volts) || isnan(amps);
end

function value = k617Decode(reply)
% A reading carries its own status: N for normal or O for overflow, then
% three letters for the function, then the mantissa and exponent, figure
% 3-9. An overflow comes back as NaN so the caller counts it as a fault,
% because it is a full-scale number that would otherwise sit in the CSV
% looking like a measurement.
%
% The prefix is required rather than optional. G0 in the setup string asks
% for it, so a reply arriving without one is not a reading this code asked
% for, and a status word left unread would otherwise parse as a perfectly
% plausible number.
%
% Takes a string, not a port, so captured replies can drive it offline.

    text   = extractBefore(strtrim(string(reply)) + ",", ",");   % G2 suffix
    prefix = regexp(text, "^[NO](DCV|DCA|OHM|DCC|DCX)", "match", "once");

    if ismissing(prefix) || startsWith(prefix, "O")
        value = NaN;
        return
    end

    value = str2double(extractAfter(text, strlength(prefix)));
end

function ddcTell(handle, command)
% Nothing happens on a 617 until an X arrives, so every command leaves
% through here and every one of them gets one. An empty command is a bare
% X, which under T5 is a trigger and nothing else.

    writeline(handle, command + "X");
end

function reply = ddcAsk(handle, command, cfg)
    ddcTell(handle, command);
    reply = strtrim(string(readline(handle)));
    if strlength(reply) == 0
        error("PVLoad:MeterNoReply", ...
            "No reply to ""%sX"" within %g s.", command, cfg.Dmm.Timeout);
    end
end

function closeMeters(meas)
% Closed without a reset, so an abort does not wipe the front panel setup.
    if ~isstruct(meas)
        return
    end
    quietly(@() delete(meas.V));
    quietly(@() delete(meas.I));
end


%% =====================================================================
%  Timing
%  =====================================================================

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
end


%% =====================================================================
%  Execution
%  =====================================================================

function results = runExperiment(board, edfa, meas, plan, levels, cfg, log)
% Has to be a function, not script-level code. Ctrl-C in MATLAB is an
% interrupt, not an exception: it does not run catch blocks. onCleanup is
% the only thing that fires, and only when the workspace holding it is
% destroyed, which never happens to a script's base workspace. This
% function exists to give the guard a workspace to die with.

    guard = onCleanup(@() safeShutdown(board, edfa, meas, cfg));

    enterSafeState(board);
    fprintf("Board initialised to the safe state (OPEN).\n");

    if cfg.SelfTest
        selfTestPotentiometers(board);
    else
        fprintf("Self-test skipped. The potentiometers are unverified.\n");
    end

    edfaWarmUp(edfa, levels(1), cfg);

    results = allocateResults(numel(plan), numel(levels));

    for k = 1:numel(levels)
        levels(k) = edfaApplyLevel(edfa, levels(k), cfg);
        levels(k).IRange = pickCurrentRange(levels(k).IscExpected, cfg);
        meas = setCurrentRange(meas, levels(k).IscExpected, cfg);

        fprintf("\n--- %s ---\n", describeLevel(levels(k)));

        [results, levels(k)] = runLevel(board, meas, plan, levels(k), cfg, results);
        levels(k) = closeLevel(edfa, levels(k));

        if ~levels(k).Valid
            warning("PVLoad:LevelInvalid", ...
                "The amplifier was off when level %d finished. Treat that " + ...
                "level's data as suspect.", levels(k).Index);
            results = markLevelInvalid(results, levels(k).Index);
        end

        fprintf("Level %d done. %d read fault(s).\n", ...
            levels(k).Index, levels(k).Faults);
        appendLevel(log, results, levels(k), numel(plan));
    end

    writeLevelTable(log, levels);

    edfaShutdown(edfa, false);
    enterSafeState(board);
end

function [results, level] = runLevel(board, meas, plan, level, cfg, results)
% A failure on the very first point is misconfiguration rather than a
% glitch, so it aborts instead of NaNing its way through 769 states.

    total = numel(plan);
    base  = (level.Index - 1) * total;
    prev  = "";
    run   = 0;                 % consecutive faults

    for k = 1:total
        settle = settleFor(plan(k), prev, cfg);
        applyState(board, plan(k), settle);
        prev = plan(k).Mode;

        [volts, amps, fault] = readPoint(meas, cfg);

        if fault
            level.Faults = level.Faults + 1;
            run = run + 1;
            % A failure on the very first point of a level is
            % misconfiguration, not a glitch, so it fails fast.
            if k == 1 || run > cfg.Dmm.MaxFaults
                error("PVLoad:MeterUnresponsive", ...
                    "The meters failed %d reading(s) in a row at level %d, " + ...
                    "state %d of %d. Check the cabling and the address.", ...
                    run, level.Index, k, total);
            end
        else
            run = 0;
        end

        results = recordPoint(results, base + k, level, k, plan(k), ...
                              settle, volts, amps);

        if cfg.PrintStatus
            printState(level, k, total, plan(k), volts, amps);
        end
    end
end

function level = closeLevel(edfa, level)
% Checked at the boundaries only, to keep 769 extra round trips per level
% out of the sweep. A mid-level trip therefore marks the whole level
% suspect rather than some guessed-at subset of it.

    if ~edfa.Enabled
        return
    end

    try
        level.Valid = edfaIsOn(edfa);
    catch
        level.Valid = false;
    end
end

function results = allocateResults(nStates, nLevels)
% Filled by index rather than grown, which keeps this linear.

    n = nStates * nLevels;
    z = nan(n, 1);

    results = struct( ...
        'LevelIndex',  z, 'LevelCurrentMa', z, 'LevelPowerMw', z, ...
        'LevelValid',  true(n, 1), ...
        'StateIndex',  z, 'Mode', strings(n, 1), ...
        'Code1',       z, 'Code2', z, 'RNominal', z, ...
        'VoltageV',    z, 'CurrentA', z, 'ResistanceOhm', z, 'PowerW', z, ...
        'SettleS',     z, 'Timestamp', NaT(n, 1));
end

function results = recordPoint(results, row, level, stateIndex, state, ...
                               settle, volts, amps)
% One row.
%
% Resistance and power are computed from the measured values, never from
% the wiper code. That is the whole reason the board carries no sensing:
% the tap code is a repeatable setting, not a known resistance.

    results.LevelIndex(row)     = level.Index;
    results.LevelCurrentMa(row) = level.CurrentMa;
    results.LevelPowerMw(row)   = level.PowerMw;
    results.StateIndex(row)     = stateIndex;
    results.Mode(row)           = state.Mode;
    results.Code1(row)          = state.Code1;
    results.Code2(row)          = state.Code2;
    results.RNominal(row)       = state.Resistance;
    results.VoltageV(row)       = volts;
    results.CurrentA(row)       = amps;
    results.ResistanceOhm(row)  = volts / amps;
    results.PowerW(row)         = volts * amps;
    results.SettleS(row)        = settle;
    results.Timestamp(row)      = datetime("now");
end

function results = markLevelInvalid(results, levelIndex)
    results.LevelValid(results.LevelIndex == levelIndex) = false;
end

function printState(level, index, total, state, volts, amps)
    if isnan(level.CurrentMa)
        tag = "  ambient  ";
    else
        tag = sprintf("%4g mA", level.CurrentMa);
    end

    if isnan(volts) && isnan(amps)
        reading = "";
    else
        reading = sprintf("   V=%9.5f  I=%9.4f mA", volts, 1e3 * amps);
    end

    fprintf("[lvl %d %s] [%4d/%4d] %-5s  U1=%3d  U2=%3d  ~%9.1f ohm%s\n", ...
        level.Index, tag, index, total, state.Mode, ...
        state.Code1, state.Code2, state.Resistance, reading);
end


%% =====================================================================
%  Logging
%  =====================================================================

function log = openLog(cfg, levels)
% Two files, not one wide one: a per-point table where every row is a
% measurement, and a per-level table for what is constant across a level.
% A shared timestamp keeps a run together and sorts the folder by date.

    log = struct('Readings', "", 'Levels', "", 'Started', false);

    if ~cfg.Out.WriteCsv
        return
    end

    dir = resolvePath(cfg.Out.Dir);
    if ~isfolder(dir)
        mkdir(dir);
    end

    stamp = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
    tag   = cfg.Out.Tag;
    if strlength(tag) > 0
        tag = "_" + tag;
    end

    log.Readings = string(fullfile(dir, "pvload_" + stamp + tag + ".csv"));
    log.Levels   = string(fullfile(dir, "pvload_" + stamp + tag + "_levels.csv"));

    fprintf("Logging to %s\n", log.Readings);
    fprintf("  %d level(s) will be appended as each one finishes.\n", ...
        numel(levels));
end

function appendLevel(log, results, level, nStates)
% Written as soon as a level is done, so an abort keeps what it measured.

    if strlength(log.Readings) == 0
        return
    end

    rows = (level.Index - 1) * nStates + (1:nStates);
    t = table( ...
        results.Timestamp(rows),     results.LevelIndex(rows), ...
        results.LevelCurrentMa(rows), results.LevelPowerMw(rows), ...
        results.LevelValid(rows),    results.StateIndex(rows), ...
        results.Mode(rows),          results.Code1(rows), ...
        results.Code2(rows),         results.RNominal(rows), ...
        results.VoltageV(rows),      results.CurrentA(rows), ...
        results.ResistanceOhm(rows), results.PowerW(rows), ...
        results.SettleS(rows), ...
        'VariableNames', {'timestamp', 'level_index', 'level_current_ma', ...
            'level_power_mw', 'level_valid', 'state_index', 'mode', ...
            'u1_code', 'u2_code', 'r_nominal_ohm', 'voltage_v', ...
            'current_a', 'resistance_ohm', 'power_w', 'settle_s'});

    if level.Index == 1
        writetable(t, log.Readings);
    else
        writetable(t, log.Readings, 'WriteMode', 'append');
    end
end

function writeLevelTable(log, levels)
% Everything constant across a level, written once at the end.

    if strlength(log.Levels) == 0
        return
    end

    t = table([levels.Index]', [levels.CurrentMa]', ...
        [levels.CurrentReadback]', [levels.PowerMw]', [levels.Source]', ...
        [levels.TempC]', [levels.IscExpected]', [levels.OpenFraction]', ...
        [levels.IRange]', [levels.Faults]', [levels.Valid]', ...
        'VariableNames', {'level_index', 'current_set_ma', ...
            'current_readback_ma', 'power_mw', 'power_source', 'temp_c', ...
            'isc_expected_a', 'open_fraction', 'i_range_a', 'read_faults', ...
            'valid'});

    writetable(t, log.Levels);
end


%% =====================================================================
%  Shutdown
%  =====================================================================

function safeShutdown(board, edfa, meas, cfg)
% Ordering matters: the Class 3B output goes off first and without waiting
% for a graceful ramp, then the load is made safe. Every step is guarded
% separately and none rethrow, because this runs during an interrupt and
% an error raised here would mask whatever caused the abort.

    try
        edfaShutdown(edfa, true);
    catch shutdownError
        warning("PVLoad:EdfaShutdownFailed", ...
            "Could not confirm the pump is off: %s\nCheck the front " + ...
            "panel ENABLE indicator before approaching the output.", ...
            shutdownError.message);
    end

    try
        enterSafeState(board);
    catch
        warning("PVLoad:SafeStateFailed", ...
            "Could not return the board to OPEN. Power down the Arduino, " + ...
            "which releases every relay.");
    end

    closeMeters(meas);
    quietly(@() delete(edfa.Port));

    if cfg.Edfa.Enabled
        fprintf("Pump disabled and board returned to OPEN.\n");
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
