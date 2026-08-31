% TO STOP: press Ctrl-C once and wait about three seconds. The cleanup
% handler returns the board to OPEN; a second press can interrupt it.
%
% The code is in matlab/+pvload. This file is the settings and the dispatch.

clear;
clc;


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PART 1. SETTINGS.

%   "plan"    print the plan and the time estimate, open nothing
%   "board"   Arduino and PCB only
%   "ramp"    climb the range slowly enough to follow on a handheld
%   "wiper"   the state pairs whose difference is one wiper resistance
%   "verify"  seven holds that exercise every part of a fresh board
%   "ohms"    board and one meter, every state measured on ohms
%   "meters"  both sweep meters only
%   "sweep"   the full experiment, written to CSV

RUN = "sweep";


% Each meter needs its own primary address, set from its front panel: they
% all ship on 27. serialportlist and visadevlist confirm both.

SERIAL_PORT = "COM4";

DMM_ENABLED   = true;
DMM_V_ADDRESS = "GPIB0::22::INSTR";  % across the cell
DMM_I_ADDRESS = "GPIB0::1::INSTR";   % in series with PV+
DMM_R_ADDRESS = "GPIB0::1::INSTR";   % RUN "ohms"; ignores DMM_ENABLED


% Zero means measure it before the run and size the meters from that. A
% number pins the range instead, for a family of runs at different light.

ISC_FULL      = 0;         % A
VOC_FULL      = 0;         % V
CELL_AREA_CM2 = 0;         % cm2, or 0 for absolute current not density


POINT_BUDGET   = 1.0;      % s per state end to end. caps the hold, never
                           % the conversion.
CODE_STEP      = 16;       % thins the board-only modes, 767/step + 2 states.
                           % the sweep ignores it and uses all 769.
PRINT_STATUS   = true;
SELF_TEST      = true;     % false runs the flow on a bare Arduino
MEASURE_SETTLE = true;     % time the cell settling instead of guessing C_LOAD


% Board-only modes.

RAMP_STEPS  = 769;         % 2 to 769. an even stride locks onto one mode.
RAMP_DWELL  = 1.0;         % s per hold, "ramp" and "wiper"
OHMS_SETTLE = 0.5;         % s before the reading. 0.1 on a fixed range.
WIPER_CODES = [0 255];     % code sums "wiper" compares at


% A coarse pass first, then states added between measured neighbours where
% the curve bends or a gap could hide the knee. Decided from measured V and
% I; SHORT and OPEN are always in the coarse pass.

ADAPT_COARSE_STEP = 32;    % wiper codes between coarse states. 32 gives 27.
ADAPT_GAP         = 0.12;  % fraction of the measured I-V span
ADAPT_BEND        = 0.020; % fraction of span off the neighbours' chord.
                           % must clear the light's own wobble.
ADAPT_MAX_POINTS  = 200;   % states the run may spend
ADAPT_MAX_ROUNDS  = 12;    % passes including the coarse one


% "196" or "34401A" per meter. These say what is cabled where; do not
% change them to suit the software. docs/METERS.md has the rest.

DMM_V_MODEL      = "34401A";
DMM_I_MODEL      = "196";
DMM_R_MODEL      = "196";
DMM_TIMEOUT      = 10;             % s, must exceed one conversion
DMM_ZERO_CORRECT = true;           % 34401A autozero, costs a second conversion
DMM_NPLC         = 10;             % 34401A only: 0.02, 0.2, 1, 10 or 100
DMM_LINE_HZ      = 60;             % mains frequency
DMM_V_RANGE      = 0;              % V, or 0 to size from the probe and follow
DMM_I_RANGE      = 0;              % A, likewise
DMM_R_RANGE      = 0;              % ohm, or 0 for autorange
DMM_PARALLEL     = true;           % trigger both, then collect both
DMM_MAX_FAULTS   = 5;              % consecutive read failures before abort


% RUN_TAG goes in the file name and is the only record of the illumination.

WRITE_CSV = true;
OUT_DIR   = "../data/sweep_data";
RUN_TAG   = "ILASER0p850";
CSV_CHUNK = 64;            % rows per write; writetable reopens the file


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PART 2. ASSEMBLY AND DISPATCH. Not tuning.
%
% The pin map, the resistance model and the settle constants are in
% pvload.Hardware; the meter command sets are in pvload.Profiles. Change
% those only when the hardware changes, and change docs/HARDWARE.md too.

pins  = pvload.Hardware.pins();
model = pvload.Hardware.model();
times = pvload.Hardware.timing();

cfg = struct( ...
    'Run',           RUN, ...
    'SerialPort',    SERIAL_PORT, ...
    'BoardType',     pins.BoardType, ...
    'PinSCK',        pins.SCK, ...
    'PinSDI',        pins.SDI, ...
    'PinSDO',        pins.SDO, ...
    'PinCSU1',       pins.CsU1, ...
    'PinCSU2',       pins.CsU2, ...
    'PinK1',         pins.K1, ...
    'PinK2',         pins.K2, ...
    'PinK3',         pins.K3, ...
    'CodeStep',      CODE_STEP, ...
    'PrintStatus',   PRINT_STATUS, ...
    'SelfTest',      SELF_TEST, ...
    'RampSteps',     RAMP_STEPS, ...
    'RampDwell',     RAMP_DWELL, ...
    'OhmsSettle',    OHMS_SETTLE, ...
    'WiperCodes',    WIPER_CODES, ...
    'RabNominal',    model.RabNominal, ...
    'WiperSteps',    model.WiperSteps, ...
    'RWiper',        model.RWiper, ...
    'RContact',      model.RContact, ...
    'ROpenPath',     model.ROpenPath);

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

% Each meter gets one spec holding its profile, where it lives, the range
% list for the function it will be asked for, and how long a conversion
% takes. That is what travels down to the bus functions, so nothing below
% has to know which of the three meters it is holding.
profiles = pvload.Profiles.all(DMM_NPLC, DMM_LINE_HZ, DMM_ZERO_CORRECT);
ddcV = pvload.Profiles.select(profiles, DMM_V_MODEL, "DMM_V_MODEL");
ddcI = pvload.Profiles.select(profiles, DMM_I_MODEL, "DMM_I_MODEL");
ddcR = pvload.Profiles.select(profiles, DMM_R_MODEL, "DMM_R_MODEL");

cfg.Dmm = struct( ...
    'Enabled',     DMM_ENABLED, ...
    'Timeout',     DMM_TIMEOUT, ...
    'LineHz',      DMM_LINE_HZ, ...
    'Parallel',    DMM_PARALLEL, ...
    'MaxFaults',   DMM_MAX_FAULTS, ...
    'ZeroCorrect', DMM_ZERO_CORRECT, ...
    'V', pvload.Profiles.spec(ddcV, DMM_V_ADDRESS, DMM_V_RANGE, ddcV.VRanges, ...
                              DMM_ZERO_CORRECT, DMM_TIMEOUT), ...
    'I', pvload.Profiles.spec(ddcI, DMM_I_ADDRESS, DMM_I_RANGE, ddcI.IRanges, ...
                              DMM_ZERO_CORRECT, DMM_TIMEOUT), ...
    'R', pvload.Profiles.spec(ddcR, DMM_R_ADDRESS, DMM_R_RANGE, ddcR.RRanges, ...
                              DMM_ZERO_CORRECT, DMM_TIMEOUT));

cfg.Timing = struct( ...
    'RelaySettle', times.RelaySettle, ...
    'WiperSettle', times.WiperSettle, ...
    'Safety',      times.Safety, ...
    'TauCount',    times.TauCount, ...
    'CLoad',       times.CLoad, ...
    'CellSettle',  times.CellSettle, ...
    'Budget',      POINT_BUDGET, ...
    'Overhead',    times.Overhead, ...
    'Measure',     MEASURE_SETTLE);

cfg.Out = struct( ...
    'WriteCsv', WRITE_CSV, ...
    'Dir',      OUT_DIR, ...
    'Tag',      RUN_TAG, ...
    'Chunk',    CSV_CHUNK);

pvload.Config.check(cfg);

switch cfg.Run
    case "plan",   pvload.Modes.runPlan(cfg);
    case "board",  pvload.Modes.runBoard(cfg);
    case "ramp",   pvload.Modes.runRamp(cfg);
    case "wiper",  pvload.Modes.runWiper(cfg);
    case "verify", pvload.Modes.runVerify(cfg);
    case "ohms",   pvload.Modes.runOhms(cfg);
    case "meters", pvload.Modes.runMeters(cfg);
    case "sweep",  results = pvload.Modes.runSweep(cfg);
end
