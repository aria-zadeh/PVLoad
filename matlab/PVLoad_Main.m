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
%   "k3"      board only, four holds that say whether K3 closes
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
% illumination itself is not this script's business. set the lamp by hand,
% run the sweep, change the lamp, run it again; each run writes its own
% timestamped CSV and RUN_TAG is how you tell them apart afterwards.

ISC_FULL = 0.016;          % A, short-circuit current under that light
VOC_FULL = 9;              % V, open-circuit voltage under that light



% a sweep costs about six minutes; RUN "plan" prints the estimate before
% anything is opened.

SETTLE_TIME  = 0.20;       % s per state with no meters. ignored once
                           % DMM_ENABLED, which computes the hold instead.
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
RUN_TAG   = "";            % added to the file names. this is where the
                           % illumination goes, since nothing else records
                           % it. e.g. "cell3_lamp60"


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



% meters. Two instruments are on the bench and both are 6.5 digit DMMs
% rather than electrometers, so neither has zero check and both read
% current across a shunt:
%
%   "196"     Keithley 196 system DMM. Amps start at 300 uA, table 3-9,
%             and there is no integration time to set.
%   "34401A"  Agilent 34401A. Amps start at 10 mA. What it adds is an
%             integration time and a switchable high impedance input, which
%             is what makes it the better of the two as a voltmeter.
%
% The model is named per meter rather than once, because a bench is stocked
% with whatever it has and the voltmeter and the ammeter need not be the
% same instrument. Each meter carries its own profile from the moment it is
% opened, so a sweep can run a 196 on volts and a 34401A on amps.
%
% The 196 predates SCPI: a command is a letter and a number, several of
% them travel in one string, and none of them do anything until an X
% arrives. The 34401A is SCPI, so commands are words, one per line, and a
% reading is a bare number with no prefix in front of it. Nothing above the
% transport is shared between the two dialects, so each profile below
% carries a Dialect and the handful of functions that talk to the bus
% branch on it.

DMM_V_MODEL      = "34401A";       % "196" or "34401A", per meter.
DMM_I_MODEL      = "196";          % the sweep's two, and then the single
DMM_R_MODEL      = "196";          % meter RUN "ohms" opens
DMM_TIMEOUT      = 10;             % s, must exceed one conversion
DMM_ZERO_CORRECT = true;           % null the meter's own offset. 34401A
                                   % only, where it is autozero and costs a
                                   % second conversion per reading. the 196
                                   % has nothing equivalent and ignores it.
DMM_NPLC         = 10;             % power line cycles per conversion.
                                   % 34401A only: 0.02, 0.2, 1, 10 or 100.
                                   % 10 is the 6.5 digit setting. the 196
                                   % converts on a fixed schedule and
                                   % ignores this.
DMM_LINE_HZ      = 60;             % mains frequency, which is what turns
                                   % DMM_NPLC into seconds
DMM_V_RANGE      = 0;              % V, or 0 to pick the smallest range
                                   % that holds VOC_FULL
DMM_I_RANGE      = 0;              % A, or 0 to size it from ISC_FULL
DMM_R_RANGE      = 0;              % ohm, or 0 for the meter's own
                                   % autorange. the sweep covers five
                                   % decades, so no one fixed range holds
                                   % it and autorange is the default. a
                                   % fixed range is better where it fits,
                                   % autoranging costing a hunt at every
                                   % state that changes decade.
DMM_PARALLEL     = true;           % trigger both meters, then collect both
DMM_MAX_FAULTS   = 5;              % consecutive read failures before abort

% Keithley 196 system DMM, manual 196-901-01 Rev D, section 3.9. Every
% letter and range below is off a page of it: functions from 3.9.2, ranges
% from table 3-9, the rest from the device-dependent command summary,
% table 3-8.
%
% Amps is F3 rather than F1, F1 and F2 being the AC functions. There is no
% zero check, that being an electrometer facility, so DMM_ZERO_CORRECT does
% nothing on this meter.
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
    'Prefixes',   "DCV|ACV|OHM|OCO|DCI|ACI|dBV|dBI", ...
    'StatusMap',  struct('F', 3, 'K', 6, 'R', 18, 'S', 19, 'T', 20, 'Z', 27), ...
    'Common',     "Z0B0G0M0K2S2T5", ...
    'Machine',    "U0", ...
    'Error',      "U1", ...
    'Conversion', 0.024, ...
    'VRanges',    [0.3 3 30 300], ...
    'IRanges',    [3e-4 3e-3 3e-2 3e-1 3], ...
    'RRanges',    [300 3e3 3e4 3e5 3e6 3e7 3e8]);
%   Common in order, table 3-8: relative off, so a REL left on the front
%   panel cannot offset every reading; readings from the A/D rather than
%   the buffer; send the prefix that flags an overflow; SRQ mask cleared;
%   EOI on and bus hold-off off, which is what lets the second meter be
%   triggered while this one is converting; 5.5 digit resolution; and
%   convert once per X.
%
%   Ranges are R1 upward by decades, table 3-9: volts 300 mV to 300 V,
%   amps 300 uA to 3 A, ohms 300 ohm to 300 Mohm. Note that amps starts a
%   decade below the 3 mA a 6.5 digit DMM is usually assumed to stop at.
%
%   Conversion is 24 ms, table 3-16, which is the trigger to reading-ready
%   time at S2. The integration period itself is one line cycle; the rest
%   is the bus. S3 would be 106 ms for one more digit.
%
%   Prefixes are the reading mnemonics of figure 3-6. DC amps is DCI, not
%   the DCA another Keithley uses, and a decoder that does not know that
%   turns every current reading into NaN once the meter is actually on
%   amps. The bench found this the slow way.
%
%   StatusMap is where each setting's digit sits in the U0 machine word,
%   counted after the 196 prefix. Mapped on the bench by toggling one
%   setting at a time and diffing the word, because the error word cannot
%   be trusted after a fresh session open (see primeDdc) and the machine
%   word is what setup verification reads instead.

% Agilent 34401A, manual 34401-90004. Ranges are chapter 1, the input
% resistance rule is chapter 3 under Measurement Configuration, and the
% shunt values are the DC Characteristics table in chapter 8.
%
% NOT RUN AGAINST THE INSTRUMENT YET. The commands are ordinary SCPI read
% off the manual, but no reading has come back from this meter. The
% SYST:ERR? query after every setup is what catches one it does not know.
%
% Volts, Amps and Ohms are the SCPI function nodes rather than letters.
% They serve twice: CONF:<node> <range> selects function and range in one
% command, and <node>:NPLC sets the integration time afterwards. Order
% matters, because CONF resets integration time, autozero and input
% impedance to that function's defaults, so Common has to follow it.
%
% Common in order: immediate trigger, so INIT starts a conversion rather
% than waiting on the bus; the settling delay the meter computes for the
% function and range, which is what a fixed 0 would throw away; one trigger
% and one sample, so a fetched reading is the reading and not the first of
% a burst.
%
% The delay is TRIG:DEL:AUTO ON and not TRIG:DEL AUTO. Manual page 80 gives
% TRIGger:DELay {<seconds>|MINimum|MAXimum} and TRIGger:DELay:AUTO {OFF|ON}
% as separate commands, so AUTO is a node rather than a parameter and the
% shorter form is -224, Illegal parameter value. The meter reported that on
% the bench before this line was corrected.
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
%   Volts 100 mV to 1000 V by decades, amps 10 mA to 3 A, ohms 100 ohm to
%   100 Mohm. Conversion is DMM_NPLC line cycles plus about 60 ms of
%   command and range overhead, doubled when autozero is on because the
%   meter takes a zero reading between every measurement.
%
%   HighZ is sent on the voltmeter only, and it has to be sent after the
%   CONF: the manual is explicit that CONFigure and MEASure? turn
%   INP:IMP:AUTO back off. The DC volts input is 10 Mohm until it is set,
%   and 10 Mohm across the 470 kohm OPEN path is a divider that reads Voc
%   about 4.5% low. AUTO ON raises it past 10 Gohm, but only on the
%   100 mV, 1 V and 10 V ranges: a VOC_FULL that pushes the meter onto
%   100 V puts the divider back. The setting is volatile, so it is sent
%   every time the meter is configured rather than once.

% One profile per meter rather than one for the bench. The two lists carry
% different fields, so they travel in a cell array rather than a struct
% array, and selectProfile matches on the Model field.
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
RC_TAU_COUNT  = 7;         % time constants. e^-7 is 0.09%.
C_LOAD        = 300e-12;   % F, dominated by the leads and the meter
                           % input.
CELL_SETTLE   = 0;         % s for the cell's own junction capacitance.

CSV_CHUNK     = 64;        % states written to disk at a time. writetable
                           % reopens the file per call, so a row at a time
                           % is far too slow and the whole run at the end
                           % loses everything on an abort.
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
    'OhmsSettle',    OHMS_SETTLE, ...
    'WiperCodes',    WIPER_CODES, ...
    'RabNominal',    R_AB_NOMINAL, ...
    'WiperSteps',    WIPER_STEPS, ...
    'RWiper',        R_WIPER, ...
    'RContact',      R_CONTACT, ...
    'ROpenPath',     R_OPEN_PATH);

cfg.Cell = struct( ...
    'IscFull', ISC_FULL, ...
    'VocFull', VOC_FULL);

% Each meter gets one spec holding everything about it: its profile, where
% it lives, which range list applies to the function it will be asked for,
% and how long a conversion takes. That is what travels down to the bus
% functions, so nothing below this line has to know which of the three
% meters it is holding, and the voltmeter and the ammeter can differ.
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
    'CellSettle',  CELL_SETTLE);

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
    case "k3",     runK3Check(cfg);
    case "verify", runVerify(cfg);
    case "ohms",   runOhmsSweep(cfg);
    case "meters", runMeterCheck(cfg);
    case "sweep",  results = runSweepAll(cfg);
end


%% =====================================================================
%  Run modes
%  =====================================================================

function runPlanOnly(cfg)

    plan = buildSweepPlan(cfg);
    reportPlan(cfg, plan);
    fprintf("\nNothing was opened. Set RUN to board, meters or sweep to " + ...
        "use hardware.\n");
end

function runBoardCheck(cfg)
% Arduino and PCB only, so SPI and the relays can be proved with no cell
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
% the 155 ohm measured on board 2 and R_AB is +/-20%, so a meter that
% disagrees at the low end is the model's tolerance rather than the board
% being wrong. A disagreement larger than that on a different board is
% worth keeping: it is what R_WIPER should be set to for that one.

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

function runOhmsSweep(cfg)
% Board and one meter, on ohms across J1 and J3 and with no cell in the
% loop. Every state in the sweep is visited once and the
% meter reads the load directly, so the resistance comes off an instrument
% instead of off the model.
%
% This does what "ramp" does without a human copying numbers off a
% handheld, which is the only reason it needs a meter at all. The reading
% carries the leads, the jacks and the traces the same way a handheld does,
% so a constant offset of a few ohms across every point is the wiring and
% not the board.
%
% One meter, so DMM_ENABLED stays out of it: that flag says whether the
% pair the sweep needs is attached, and this mode needs neither of them in
% particular.

    plan  = buildSweepPlan(cfg);

    % Two guards rather than one, because an onCleanup captures what exists
    % when it is built and the meter is opened second. A meter that will not
    % open then still leaves the board guarded.
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
% One meter, so there is nothing to overlap and this is the plain trigger
% and collect. A timeout comes back NaN and is counted rather than thrown,
% the same way the sweep treats a dropped point.

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
% CSV and plot share a stamped base name, so the two halves of one run stay
% together and a later run cannot overwrite either.
%
% The figure is drawn either way. WRITE_CSV decides what reaches the disk,
% and a mode whose whole output is a plot should not lose the plot as well.

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
% Linear axes, with the model plotted alongside because the interesting
% part is where the two part company.
%
% The sweep spans five decades, so a linear upper axes is set by the top of
% the range and everything below a kilohm sits on the x axis. The lower
% axes is what carries the bottom of the sweep. It is the ratio rather than
% a difference or a percentage because both of those are dominated by one
% end: the SHORT state models at 0.150 ohm, so any offset at all is
% thousands of a percent there, and R_AB's 20% at the top is tens of kohm.
% A ratio holds the whole range at once, and 1 is agreement.
%
% Two endpoints are left off the axes because each one sets a scale that
% hides the other 767 states. OPEN comes off both: it is the 470 kohm
% resistor rather than the ladders, and forty times the largest ladder
% state. SHORT comes off the ratio axes only: it models at 0.150 ohm, so
% the probe path alone puts its ratio near 3 while every other state sits
% within a percent of 1.
%
% Both stay in the CSV, and the labels say what is missing. This is a
% choice about the axes, not about what gets measured.
%
% Nothing else is clipped or blanked. A linear axes draws a zero or
% negative reading where a log axes would have dropped it, so the count
% below names only what the meter did not return at all.

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

function runMeterCheck(cfg)
% Meters only, so the command dialect and the wiring can be checked before
% a sweep depends on them.

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
        [v, i, fault] = readPoint(meas, cfg);
        fprintf("  %2d  V = %11.6f   I = %11.6f A%s\n", k, v, i, ...
            ternary(fault, "   (fault)", ""));
    end

    closeMeters(meas);
    clear guard;
    fprintf("\nMeters OK.\n");
end

function results = runSweepAll(cfg)
% One sweep at whatever illumination the bench happens to be under. The
% lamp is set by hand and the script never touches it, so a family of
% curves is several runs of this rather than one run of several levels.
% RUN_TAG is the only record of which was which.

    plan = buildSweepPlan(cfg);
    reportPlan(cfg, plan);

    board = connectBoard(cfg);
    fprintf("Board connected.\n");

    % runExperiment's guard is built from the board and the meters
    % together, so it does not exist while the meters are coming up. A
    % meter that will not open would otherwise leave the board
    % energised behind nothing.
    try
        meas = connectMeters(cfg);
        log  = openLog(cfg, numel(plan));
    catch openError
        quietly(@() enterSafeState(board));
        rethrow(openError);
    end

    results = runExperiment(board, meas, plan, cfg, log);

    fprintf("\nRun complete. %d states.\n", numel(plan));
    if strlength(log.Readings) > 0
        fprintf("Readings: %s\n", log.Readings);
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
%  Validation and planning
%  =====================================================================

function assertConfig(cfg)
% Catches a mistyped config block before anything is energised.

    mustBeOneOf(cfg.Run, ...
        ["plan" "board" "ramp" "wiper" "k3" "verify" "ohms" "meters" ...
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
    % Checked per meter, and not gated on D.Enabled, for the same reason
    % DMM_R_RANGE is not: RUN "ohms" opens one meter and configures it
    % through the same path. An NPLC the meter does not have is rejected at
    % the bus with nothing to say which of these two numbers caused it.
    assertNplc(D.V, D.LineHz);
    assertNplc(D.I, D.LineHz);
    assertNplc(D.R, D.LineHz);

    if D.Enabled && D.V.Range > 0
        % Every range is named, so one that does not exist is a config
        % error here rather than something the meter sorts out later. A
        % zero means the range is sized from VOC_FULL or ISC_FULL instead,
        % which is what keeps one configuration working on any of them.
        rangeCode(D.V.Range, D.V.Ranges, "DMM_V_RANGE", D.V.Label);
    end
    if D.Enabled && D.I.Range > 0
        rangeCode(D.I.Range, D.I.Ranges, "DMM_I_RANGE", D.I.Label);
    end
    % Not gated on D.Enabled: RUN "ohms" uses one meter and that flag is
    % about the pair the sweep needs.
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
% DMM_NPLC and DMM_LINE_HZ are shared, but only a SCPI meter reads them, so
% the check runs once per meter and stays quiet for the Keithleys.

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
% Resolved against this file's folder, so the current directory does not
% matter.
    if isfile(relative) || isfolder(relative)
        path = char(relative);
        return
    end
    here = fileparts(mfilename("fullpath"));
    path = fullfile(here, char(relative));
end

function reportPlan(cfg, plan)
% Everything needed to decide whether to let it run, before anything opens.

    perPoint = estimatePointTime(cfg, plan);
    total    = perPoint * numel(plan);

    fprintf("Sweep plan: %d load states, %g ohm to %g ohm.\n", ...
        numel(plan), plan(1).Resistance, plan(end).Resistance);

    % The 470 kohm path draws a fixed current at the OPEN point while Isc
    % scales with light, so under weak illumination that point stops being
    % an open-circuit measurement. Nothing here can see the lamp, so this
    % is checked against ISC_FULL and is only as good as that number.
    openFraction = (cfg.Cell.VocFull / cfg.ROpenPath) / cfg.Cell.IscFull;
    fprintf("Cell at the light you will run it under: Isc about %g mA, " + ...
        "Voc about %g V.\n", 1e3 * cfg.Cell.IscFull, cfg.Cell.VocFull);
    if openFraction > 0.05
        warning("PVLoad:OpenPointWeak", ...
            "The 470 kohm path draws %.1f%% of ISC_FULL. The OPEN point " + ...
            "is not a Voc measurement at this illumination.", ...
            100 * openFraction);
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

    fprintf("About %.0f ms per point. Estimated run time %.1f minutes.\n", ...
        1e3 * perPoint, total / 60);
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
        % Overlapped, the pair costs the slower of the two; one at a time it
        % costs both. Two different instruments make that a real difference
        % rather than a doubling.
        if cfg.Dmm.Parallel
            reading = max(cfg.Dmm.V.Conversion, cfg.Dmm.I.Conversion);
        else
            reading = cfg.Dmm.V.Conversion + cfg.Dmm.I.Conversion;
        end
        t = t + reading + 0.02;
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
%  Multimeters
%  =====================================================================

function meas = connectMeters(cfg)
% Every port opened here is closed again unless all of them come up. The
% caller's guard is built from the returned struct, so it does not exist
% while this is running, and a meter that opens and then fails to identify
% would otherwise be left to whenever MATLAB gets around to collecting it.
% Closing on the way out makes the next run's open a fresh session rather
% than a race against the last one.

    meas = struct('Enabled', false, 'V', [], 'I', [], ...
                  'VId', "", 'IId', "", 'Faults', 0, 'Cfg', cfg.Dmm);

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

        % Both ranges are settled here and never touched again. A range
        % change costs a fresh configuration, and 769 of those would be
        % absurd; the range that fits is already known from ISC_FULL and
        % VOC_FULL. Doing it twice is worse than redundant on a Keithley,
        % where each configuration leaves another triggered reading behind.
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
% Everything one meter needs, in one place. The range list is the one for
% the function this meter will be asked for and nothing else, so a caller
% holding a spec never has to work out which of the three lists applies.

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
% The profiles carry different fields, so they arrive as a cell array and
% are matched on Model rather than indexed by position.

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
% The one place a transport is chosen. On a 196 there is only the one: the
% rear panel carries an IEEE-488 connector and nothing else. The 34401A
% also has an RS-232 port, which VISA reaches as an ASRL resource, so an
% address is not necessarily GPIB any more.
%
% The open port and its profile leave here together. Everything below takes
% that pair rather than a port and a bench-wide model, which is what lets
% one sweep run two different instruments.
%
% The terminator comes from the profile because the dialects disagree about
% it. A Keithley reply ends CR LF; a 34401A ends LF alone, and waiting on a
% pair that never arrives is a timeout on every read.

    m = spec;
    D = spec.Ddc;

    try
        m.Port = visadev(spec.Address);
        m.Port.Timeout = spec.Timeout;
        configureTerminator(m.Port, D.ReadTerm, D.WriteTerm);
        % A meter can be mid-reading when a fresh session opens, and the
        % first query then waits on a terminator that has already gone past.
        % Without this every first read times out.
        flush(m.Port, "input");
        if D.Dialect == "scpi"
            if startsWith(upper(string(spec.Address)), "ASRL")
                % Over RS-232 the meter comes up in local and ignores the
                % bus until this arrives. Over GPIB the addressing does it
                % and the command is not one the meter accepts, so it is
                % sent only here.
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
% visadev sends *IDN? to whatever it opens and offers no way to turn that
% off (MathWorks support, MATLAB Answers 2118301). The 196 predates SCPI:
% none of those characters execute without a trailing X, so the fragment
% sits in its parser and the next real command is concatenated onto it.
% The X that command ends with then executes the combined garbage. That is
% the whole family of session-open faults this bench measured: the first
% command that vanishes, the IDDCO that latches with no invalid command
% ever sent, and both surfacing an exchange or two late. The error word is
% therefore unreliable near an open, which is why setup verification reads
% the machine word instead (ddcVerifySetup).
%
% The bare X below is the terminator visadev never sent. It executes the
% stranded fragment at a time of our choosing, as the only command in the
% parser, and whatever that latches is drained here before anything is
% asked in earnest.
%
% T5 must land before the first question because power-on is T0,
% continuous on talk, table 3-8: being addressed to talk is itself a
% trigger, so every read manufactures a fresh reading and a query comes
% back "NDCI-00.00079E-3" instead of its answer. A drain that keeps
% answering with readings or nothing means the T5 was itself swallowed, so
% the attempt loop sends it again. One write per attempt: two writes in
% quick succession into a fresh session get mangled into one string,
% measured here as an IDDCO with every individual command valid.

    pause(0.5);
    ddcTell(m.Port, "");
    pause(0.3);
    % The fragment has a D in it, the 196's display-message command, so
    % executing it paints the tail of *IDN? onto the front panel, where it
    % reads n7. A painted message stays until a bare D restores the
    % display, so one is sent every open. The TRIG ERROR the display
    % flashes at the same moment is the same execution and just as
    % cosmetic; it clears when the first real reading lands.
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

function word = identifyMeter(m, role)
% The 196 has no *IDN?. Its U0 query returns the machine status word, which
% opens with the model number and then spells out the front panel setup, so
% one query identifies the instrument and reports its state. The 34401A
% does have *IDN?, whose reply is maker, model, serial and firmware, so the
% model sits in the middle rather than at the front.
%
% Either way the model check is what catches a DMM_*_MODEL naming one meter
% while the address reaches the other. That matters more now the two need
% not be the same instrument: the wrong profile would otherwise show up as
% a range number meaning something different from what was intended.

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
% Function and range travel together in both dialects, for the same reason
% in each: an R number means a different range in every function, and CONF
% takes the two as one command. Then the setup is checked, each dialect its
% own way: the 34401A by draining its error queue, the 196 by reading the
% machine status word back and comparing digits, because visadev poisons
% the 196's error word at every open (see primeDdc) and a latched phantom
% bit can surface commands later. The machine word is the setup; the error
% word is only history.

    if m.Ddc.Dialect == "scpi"
        scpiConfigure(m, role, range);
        assertMeterHappy(m, role);
    else
        sent = ddcConfigure(m, role, range);
        ddcVerifySetup(m, role, sent);
        % The queries above each triggered one more conversion. Left in
        % the buffer it would become the sweep's first reading, and every
        % point after it would carry the previous state's value: a curve
        % shifted by one rather than an obviously broken one.
        flush(m.Port, "input");
    end
end

function name = rangeSetting(role)
% Which Part 1 setting a rejected range came from, for the message.

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

    % Ohms is the only place autorange is used. A sweep of five decades has
    % no fixed range that holds it, and unlike the ammeter in a sweep there
    % is no cell being loaded while the meter hunts.
    if role == "ohms" && range <= 0
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
% One command per line, and the order is not cosmetic: CONF resets
% integration time, autozero and input impedance to the defaults for the
% function it selects, so everything that follows has to follow it.
%
% The error queue is cleared first so that the SYST:ERR? at the end of
% configureMeter reports this setup rather than whatever the front panel
% did before the script opened the port.

    D    = m.Ddc;
    node = functionFor(D, role);
    auto = role == "ohms" && range <= 0;

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
% Whatever a command the meter did not understand cost, it is cheaper to
% find here than in the CSV. SYST:ERR? pops one entry off a queue and a
% clean one reads +0. SCPI only; the 196's setup is checked against the
% machine word in ddcVerifySetup, because its error word is not
% trustworthy near a session open.
%
% The queue is drained rather than sampled. A setup that sends nine
% commands can have several rejected, and popping one entry per run turns
% bringing up a profile into one round trip per mistake.

    faults = scpiErrorQueue(m);
    if isempty(faults)
        return
    end
    error("PVLoad:MeterRejectedSetup", ...
        "The %s meter (%s) answered %s with %s.", ...
        role, m.Label, m.Ddc.Error, strjoin("""" + faults + """", "; "));
end

function ddcVerifySetup(m, role, sent)
% The machine word is read back and every setting the setup string carried
% is compared digit by digit, positions from the profile StatusMap. This
% checks what the meter is actually in, not what it complained about,
% which matters because a phantom IDDCO from the session open (see
% primeDdc) can surface in the error word commands after the fact. A
% setting the meter refused shows up here as a digit that did not move.
%
% R0, the ohms autorange, is skipped: under autorange the word reports
% whichever range the meter has chosen, which is information rather than
% disagreement.

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
% Pop until the queue reports empty. The 34401A holds 20 entries and
% returns +0,"No error" once it is drained, so the loop is bounded twice
% over; the counter is there for a meter that never says +0 rather than as
% the real limit.

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
% On the Keithleys R1 is the most sensitive range of a function and they
% climb by decades, so the R number is a position in the list, table 3-12.
% The 34401A names the range as a number instead and has no use for the
% position, but it still wants the same check: a range the instrument does
% not have is a configuration error here rather than something the meter
% quietly rounds up later.

    code = find(abs(ranges - range) <= 1e-9 * ranges, 1);
    if isempty(code)
        error("PVLoad:BadMeterRange", ...
            "%s is %g. The %s has %s.", ...
            name, range, label, strjoin(string(ranges), ", "));
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
        range = max(I.Ranges);
        return
    end

    fits = I.Ranges(I.Ranges >= 1.2 * iscExpected);
    if isempty(fits)
        range = max(I.Ranges);
    else
        range = min(fits);
    end
end

function range = pickVoltageRange(cfg)
% Sizing the range from VOC_FULL rather than naming a number keeps one
% configuration working on either meter, whose ranges do not line up: a
% 9 V Voc lands on 30 V on a 196 and 10 V on a 34401A.

    V = cfg.Dmm.V;

    if V.Range > 0
        range = V.Range;
        return
    end

    fits = V.Ranges(V.Ranges >= cfg.Cell.VocFull);
    if isempty(fits)
        range = max(V.Ranges);
    else
        range = min(fits);
    end
end

function [volts, amps, fault] = readPoint(meas, cfg)
% Both meters are triggered before either reply is collected, so the two
% conversions overlap. Each dialect gets there its own way, and with two
% different instruments on the bench both ways are in use at once. On the
% 196, T5 makes the X that ends a command the trigger and K2 stops the
% meter holding the bus off until that conversion finishes, which is what
% lets the second trigger leave while the first is running. On the 34401A
% the two are separate commands to begin with: INIT starts a conversion
% into memory and returns, and FETC? collects it afterwards.
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

    fault = fault || isnan(volts) || isnan(amps);
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
% Trigger and collect as one exchange, for the path where nothing is
% overlapped.

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
% A reading carries its own status: N for normal or O for overflow, then
% three letters for the function, then the mantissa and exponent. An
% overflow comes back as NaN so the caller counts it as a fault, because it
% is a full-scale number that would otherwise sit in the CSV looking like a
% measurement.
%
% The prefix is required rather than optional. G0 in the setup string asks
% for it, so a reply arriving without one is not a reading this code asked
% for, and a status word left unread would otherwise parse as a perfectly
% plausible number.
%
% The tags come from the profile because they belong to the instrument, not
% to the dialect. The 196 sends DCI for amps, figure 3-6; a decoder holding
% another meter's list accepts the volts reading and rejects the current
% one, which is the worst of both.
%
% Takes strings, not a port, so captured replies can drive it offline.

    text   = extractBefore(strtrim(string(reply)) + ",", ",");   % G2 suffix
    prefix = regexp(text, "^[NO](" + prefixes + ")", "match", "once");

    if ismissing(prefix) || startsWith(prefix, "O")
        value = NaN;
        return
    end

    value = str2double(extractAfter(text, strlength(prefix)));
end

function value = scpiDecode(reply, overflow)
% A 34401A reading is the number and nothing else, so unlike the 196
% decoder there is no prefix to demand and anything unparseable has to
% carry the whole check. str2double gives NaN for that, which is what the
% caller counts as a fault.
%
% Overflow is not a status letter here either: the meter returns 9.9E37 for
% a reading past full scale, which is a perfectly valid number and would
% otherwise land in the CSV as one.
%
% Takes a string, not a port, so captured replies can drive it offline.

    value = str2double(strtrim(string(reply)));

    if abs(value) >= overflow
        value = NaN;
    end
end

function meterTell(m, command)
% Send a command that produces no reply, in whichever dialect this meter
% speaks.

    if m.Ddc.Dialect == "scpi"
        writeline(m.Port, command);
    else
        ddcTell(m.Port, command);
    end
end

function reply = meterAsk(m, command)
% Send a command that does produce one, and insist on it. Both meters
% answer a setting command with nothing at all, so routing a set through
% here turns every successful write into a timeout.

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
% A status query whose answer must be the status word, not a reading. The
% flush in ddcAsk clears the host buffer, but a stale reading can be
% sitting in the meter itself: every command string ends in an X, under T5
% every X is a trigger, and the reading that leaves is handed out on the
% next talk even when a query has been answered since. Seen on the bench as
% U1 answering "NDCI-00.00084E-3" after a clean identify. A reading is
% recognisable, N or O and then a function tag, so up to two of them are
% read past rather than mistaken for the word; anything else is returned
% for the caller to judge.

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
% Flushed first, because under T5 every command string this code sends ends
% in an X and every X is a trigger. A setup string therefore leaves a
% reading in the meter's output that nobody asked for, and the next query
% reads that instead of its own answer. It is one behind from then on, and
% it fails in the worst way: a status word query comes back with something
% that parses as a plausible number.
%
% This is what U1 answering "NDCI-00.00009E-3" was, on the bench, at the
% second configuration of the ammeter. The first configuration's X had
% triggered a conversion and nothing had collected it.
%
% Discarding here rather than counting X's is deliberate. Whether a given
% command string produces a reading depends on the trigger mode it is
% itself setting up, so the count is not knowable from this side; what is
% knowable is that a query's answer is the next thing the meter sends after
% the query goes out.

    flush(m.Port, "input");
    ddcTell(m.Port, command);
    reply = strtrim(string(readline(m.Port)));
    if strlength(reply) == 0
        error("PVLoad:MeterNoReply", ...
            "No reply to ""%sX"" within %g s.", command, m.Timeout);
    end

    % The query's own X started a conversion, K2 means the bus is not held
    % off while it runs, and a command following too closely is a TRIGGER
    % OVERRUN, latched and lit on the display. The conversion is waited out
    % before the caller can send anything. The overlapped sweep path goes
    % through meterTrigger and meterFetch, never through here, so this
    % costs the setup a few tenths and a non-overlapped reading 0.1 s.
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

    results = runSweep(board, meas, plan, cfg, log);

    enterSafeState(board);
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

    for k = 1:total
        settle = settleFor(plan(k), prev, cfg);
        applyState(board, plan(k), settle);
        prev = plan(k).Mode;

        [volts, amps, fault] = readPoint(meas, cfg);

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
            appendPoints(log, results, (written + 1):k, written == 0);
            written = k;
        end
    end

    fprintf("\n%d read fault(s).\n", faults);
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

function log = openLog(cfg, nStates)
% One file per run, named for when it started. Never overwritten: the
% timestamp is what stops a second run landing on the first, and RUN_TAG is
% what tells two runs at different illumination apart afterwards, since
% nothing in the script knows what the lamp was doing.

    log = struct('Readings', "");

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

    fprintf("Logging to %s\n", log.Readings);
    fprintf("  %d states, written in blocks of %d.\n", nStates, cfg.Out.Chunk);
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
% Every step is guarded separately and none rethrow, because this runs
% during an interrupt and an error raised here would mask whatever caused
% the abort.
%
% The cell is a supply and the board is what stands between it and a
% short, so returning the board to OPEN is the whole job. Darkening the
% cell is the operator's, the same as lighting it was.

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
