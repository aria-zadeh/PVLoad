% TO STOP: press Ctrl-C ONCE and wait about three seconds.
%
% The cleanup handler returns the board to OPEN.
% Pressing it a second time can interrupt that handler.
%
% Everything below is the settings an operator changes, then the dispatch.
% The code lives in matlab/+pvload: Board, Meter and Profiles, Plan,
% Ranging, Timing, Sweep, Curve, Output, Modes, and the pin map and
% hardware constants in Hardware.

clear;
clc;


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PART 1. SETTINGS.

%   "plan"    print the plan and the time estimate, open nothing
%   "board"   Arduino and PCB only
%   "ramp"    board only, climbing the resistance range slowly enough to
%             follow on a handheld meter across J1 and J3
%   "wiper"   board only, the pairs of states whose difference is one
%             wiper resistance and nothing else
%   "k3"      board only, four holds that say whether K3 closes
%   "verify"  board only, seven holds that between them exercise every
%             part of the board. the check for a freshly built one.
%   "ohms"    board and one meter on ohms across J1 and J3. every
%             state in the sweep is measured, written to CSV and plotted.
%             no cell, one meter.
%   "meters"  both sweep meters only
%   "sweep"   the full experiment, written to CSV

RUN = "sweep";


% Ports and addresses. Wiring and the power sequence are in
% docs/PVLoad_BenchCard.pdf, which is meant to be printed.
%
%   SERIAL_PORT   Arduino over USB-B. serialportlist("available") lists it.
%   DMM_*_ADDRESS neither meter has anything but an IEEE-488 connector, so
%                 each needs a USB-GPIB adapter matched to the VISA, here
%                 Keysight. one adapter carries both: the connectors stack,
%                 so the second cable runs meter to meter. give each meter
%                 its own primary address from its front panel first, since
%                 they all ship on 27 and two of those collide. visadevlist
%                 confirms them.

SERIAL_PORT = "COM4";

DMM_ENABLED   = true;                % both sweep meters attached
DMM_V_ADDRESS = "GPIB0::22::INSTR";  % meter across the cell
DMM_I_ADDRESS = "GPIB0::1::INSTR";   % meter in series with PV+

DMM_R_ADDRESS = "GPIB0::1::INSTR";   % the one meter RUN "ohms" uses, on
                                     % ohms across J1 and J3. that mode
                                     % ignores DMM_ENABLED.


% Roughly what your cell does under the illumination you will run it at.
% Sizes the meter ranges and prints estimates only, never enters a result.
% Zero for both, the normal setting, means the sweep measures them itself
% before it starts; a number pins the range instead, which is worth doing
% only when the light will change mid-run and one range should span the
% family. The one place it is not advisory is the top of the ammeter: an
% ISC_FULL above the highest range the meter has is refused.
%
% Illumination is not this script's business. Set the lamp by hand, run the
% sweep, change the lamp, run it again; each run writes its own timestamped
% CSV and RUN_TAG is how you tell them apart afterwards.

ISC_FULL = 0;              % A, short-circuit current under that light
VOC_FULL = 0;              % V, open-circuit voltage under that light
CELL_AREA_CM2 = 0;         % cm2 of illuminated cell, or 0 if not known.
                           % decides whether output carries current or
                           % current density. labels only.


% A sweep costs about six minutes; RUN "plan" prints the estimate before
% anything is opened.

SETTLE_TIME  = 0.20;       % s per state with no meters. ignored once
                           % DMM_ENABLED, which computes the hold instead.
POINT_BUDGET = 1.0;        % s, the most one state may cost end to end. the
                           % hold is whatever is left after the conversion
                           % and the board, so this is the number the run is
                           % built to. it never truncates a conversion.
CODE_STEP    = 16;         % 1 visits all 769 states, 16 visits 50; the
                           % count is 767/step + 2. thins by wiper code and
                           % never by resistance. ignored when
                           % ADAPTIVE_SWEEP is on.
PRINT_STATUS = true;       % echo each state. off for long unattended runs.
SELF_TEST    = true;       % probe both pots over SPI first. false to test
                           % the flow on a bare Arduino with no board.
VERIFY_WIPER = true;       % read each wiper register back after writing
INCLUDE_SHORT = true;      % the Isc endpoint (K2 closed)
INCLUDE_OPEN  = true;      % the Voc endpoint (470 kohm in circuit)
MEASURE_SETTLE = true;     % watch the cell settle at the slowest state
                           % before the run and take its capacitance from
                           % that, rather than guessing C_LOAD for a
                           % junction nobody has characterised. guessing low
                           % does not add noise, it tilts the curve.


% The board-only bench modes.

RAMP_STEPS  = 769;         % states RUN "ramp" visits, spread evenly across
                           % the sweep. 2 to 769. pick a count whose stride
                           % is not a whole even number, or it locks onto
                           % one mode and shows no LOW states at all.
RAMP_DWELL  = 1.0;         % s each state is held, in "ramp" and "wiper"
                           % both. an autoranging handheld needs a second or
                           % two to re-range and you need longer than that to
                           % write the number down.
OHMS_SETTLE = 0.5;         % s each state is held in RUN "ohms" before the
                           % reading is triggered. the conversion follows it,
                           % so a state costs this plus about 0.4 s.
                           % autoranging needs most of this; a fixed
                           % DMM_R_RANGE runs happily at 0.1.
WIPER_CODES = [0 255];     % code sums RUN "wiper" compares at. past 255
                           % there is no LOW state to pair with, so those
                           % codes contribute a FULL row alone and walk U2
                           % by itself.


% The sweep can spend its states where the curve earns them instead of
% evenly along the ladder. A coarse pass measures the whole range first,
% then states are added between measured neighbours wherever the curve bends
% or a gap is wide enough to hide the knee, round after round, until neither
% is true. Every decision comes from the measured voltages and currents.
% SHORT and OPEN are always in the coarse pass, so Isc and Voc do not depend
% on any of this.

ADAPTIVE_SWEEP    = true;
ADAPT_COARSE_STEP = 32;    % wiper codes between coarse states, the same
                           % thinning CODE_STEP does. 32 makes the first
                           % pass 27 states.
ADAPT_GAP         = 0.12;  % fraction of the measured I-V span. a segment
                           % longer than this is split whether or not it
                           % looks bent, which is what stops a knee hiding
                           % between two coarse states that both read flat.
ADAPT_BEND        = 0.020; % fraction of the span a point may sit off the
                           % chord of its neighbours before the curve counts
                           % as bent there. has to sit above the
                           % illumination's own wobble: the 174402 run moved
                           % 1-2% in seconds, and a threshold below that
                           % spends rounds splitting straight segments the
                           % light bent.
ADAPT_MAX_POINTS  = 200;   % states the run may spend in total. reached, it
                           % stops refining; it never skips a state already
                           % queued or cuts a reading short.
ADAPT_MAX_ROUNDS  = 12;    % passes including the coarse one


% Meters. "196" is a Keithley 196, "34401A" an Agilent 34401A. The model is
% named per meter, so the voltmeter and the ammeter need not match and here
% they do not. These describe what is physically cabled; do not change them
% to suit the software. docs/METERS.md has the rest.

DMM_V_MODEL      = "34401A";
DMM_I_MODEL      = "196";
DMM_R_MODEL      = "196";
DMM_TIMEOUT      = 10;             % s, must exceed one conversion
DMM_ZERO_CORRECT = true;           % 34401A autozero. costs a second
                                   % conversion per reading; the 196 has
                                   % nothing equivalent and ignores it.
DMM_NPLC         = 10;             % 34401A only: 0.02, 0.2, 1, 10 or 100.
                                   % 10 is the 6.5 digit setting.
DMM_LINE_HZ      = 60;             % mains frequency, what turns NPLC into
                                   % seconds
DMM_V_RANGE      = 0;              % V, or 0 to size from the probe and then
                                   % follow the reading
DMM_I_RANGE      = 0;              % A, likewise
DMM_R_RANGE      = 0;              % ohm, or 0 for the meter's own
                                   % autorange. the sweep covers five
                                   % decades, so no fixed range holds it.
DMM_PARALLEL     = true;           % trigger both meters, then collect both
DMM_MAX_FAULTS   = 5;              % consecutive read failures before abort


% Output. RUN_TAG is where the illumination goes, since nothing else
% records it: e.g. "cell3_lamp60".

WRITE_CSV = true;
OUT_DIR   = "../data/sweep_data";
RUN_TAG   = "ILASER0p650";
CSV_CHUNK = 64;            % states written to disk at a time. writetable
                           % reopens the file per call, so a row at a time
                           % is far too slow and the whole run at the end
                           % loses everything on an abort.


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
    'SettleTime',    SETTLE_TIME, ...
    'CodeStep',      CODE_STEP, ...
    'PrintStatus',   PRINT_STATUS, ...
    'IncludeShort',  INCLUDE_SHORT, ...
    'IncludeOpen',   INCLUDE_OPEN, ...
    'VerifyWiper',   VERIFY_WIPER, ...
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
    'Enabled',    ADAPTIVE_SWEEP, ...
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
    case "k3",     pvload.Modes.runK3(cfg);
    case "verify", pvload.Modes.runVerify(cfg);
    case "ohms",   pvload.Modes.runOhms(cfg);
    case "meters", pvload.Modes.runMeters(cfg);
    case "sweep",  results = pvload.Modes.runSweep(cfg);
end
