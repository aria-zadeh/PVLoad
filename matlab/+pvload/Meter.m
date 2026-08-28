classdef Meter
% Both bench multimeters, as a self-contained driver. Nothing in here calls
% anything else in pvload: the caller decides which range to ask for and
% passes it in, and everything about talking to an instrument stays behind
% this file. Profiles.m holds what each instrument speaks.
%
% A meter is an open port bundled with its profile. Every function below
% takes that pair, so none of them knows which instrument it is holding,
% and one sweep can run a 196 on volts and a 34401A on amps.
%
% docs/METERS.md is the reference. The comments here record only what a
% line cannot be changed to.

methods (Static)

% ---- session -----------------------------------------------------------

function meas = connect(dmm, vRange, iRange)
% Both sweep meters, opened, identified and configured. Every port opened
% here is closed again unless all of them come up: the caller's guard is
% built from the returned struct, so it does not exist while this runs, and
% a meter that opens and then fails to identify would otherwise be left to
% whenever MATLAB collects it. Closing on the way out makes the next run's
% open a fresh session rather than a race against the last one.
%
% The ranges are the caller's decision. Settled once here rather than per
% state: a range change costs a fresh configuration, and on a Keithley each
% one leaves another triggered reading behind.

    meas = struct('Enabled', false, 'V', [], 'I', [], ...
                  'VId', "", 'IId', "", ...
                  'VAdaptive', false, 'VRangeNow', 0, 'VRanges', [], ...
                  'VChanges', 0, ...
                  'IAdaptive', false, 'IRangeNow', 0, 'IRanges', [], ...
                  'IChanges', 0);

    if ~dmm.Enabled
        return
    end

    meas.V = openMeter(dmm.V, "voltage");

    try
        meas.I = openMeter(dmm.I, "current");

        meas.VId = identifyMeter(meas.V, "voltage");
        meas.IId = identifyMeter(meas.I, "current");
        fprintf("Voltage meter: %s\n", meas.VId);
        fprintf("Current meter: %s\n", meas.IId);

        configureMeter(meas.V, "voltage", vRange);
        configureMeter(meas.I, "current", iRange);
    catch setupError
        hush(@() closeMeters(meas));
        rethrow(setupError);
    end

    meas.Enabled = true;
end

function m = openPort(spec, role)
    m = openMeter(spec, role);
end

function word = identify(m, role)
    word = identifyMeter(m, role);
end

function configure(m, role, range)
    configureMeter(m, role, range);
end

function closeBoth(meas)
    closeMeters(meas);
end

function closeOne(m)
    closePort(m);
end

% ---- reading -----------------------------------------------------------

function [volts, amps, fault, meas] = readPoint(meas, parallel)
% Both meters are triggered before either reply is collected, so the two
% conversions overlap. On the 196 that works because T5 makes the trailing
% X the trigger and K2 stops the meter holding the bus off while it
% converts; on the 34401A INIT and FETC? are separate commands already.
%
% A timeout returns NaN rather than throwing: one dropped reading in 769 is
% a lost row, and aborting an hour-long sweep over a bus hiccup is worse.

    volts = NaN;
    amps  = NaN;
    fault = false;

    if ~meas.Enabled
        return
    end

    [volts, amps, fault] = readPair(meas, parallel, volts, amps);

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

    % An ammeter that changed range inside this point was on the wrong
    % range while the voltmeter converted, and an overloaded 196 clamps
    % over a volt of burden across its terminals, in series with the cell
    % and so into the voltage reading. The recovered current is then real
    % and the voltage is not, and their product is a power the cell never
    % made: every run's first state after OPEN read about 1.5 V high this
    % way, and at 0.7 A of laser drive the fake point outbid the true
    % maximum. Take the pair again now both meters sit on ranges that fit.
    if meas.IChanges > iChangesBefore && ~isnan(amps)
        [volts, amps, reread] = readPair(meas, parallel, volts, amps);
        fault = fault || reread;
    end

    fault = fault || isnan(volts) || isnan(amps);
end

function value = readOnce(m)
    value = meterReadOnce(m);
end

% ---- ranging -----------------------------------------------------------

function meas = setRanges(meas, vRange, iRange)
% Configure both meters and let them follow the reading from here on.
%
% The voltmeter follows for resolution: the 34401A's 0.0005% of range is
% 50 uV at 10 mV on the 10 V range against 0.35 uV of reading error, so the
% bottom of a ladder crossing three decades would be almost all range
% floor. The ammeter follows for survival: a pinned range cannot track
% illumination that drifts, and run 20260828_163338 climbed from 125 uA to
% 197 uA in fourteen minutes and aborted on six overflows.

    configureMeter(meas.V, "voltage", vRange);
    configureMeter(meas.I, "current", iRange);

    meas.VAdaptive = true;
    meas.VRangeNow = vRange;
    meas.VRanges   = meas.V.Ranges;

    meas.IAdaptive = true;
    meas.IRangeNow = iRange;
    meas.IRanges   = meas.I.Ranges;
end

function code = checkRange(range, ranges, name, label)
    code = rangeCode(range, ranges, name, label);
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

function checkNplc(spec, lineHz)
% Only a SCPI meter reads DMM_NPLC and DMM_LINE_HZ, so this runs once per
% meter and stays quiet for the Keithleys.

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

end
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
    if m.ZeroCorrect
        zero = "ON";
    else
        zero = "OFF";
    end
    meterTell(m, sprintf(D.AutoZero, zero));

    if role == "voltage"
        % Ammeter and ohmmeter have no use for it, and on the current
        % function the volts input is not the one being read.
        meterTell(m, D.HighZ);
    end
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

    % A range of zero means autorange. RUN "ohms" uses it for a sweep of
    % five decades that no fixed range holds, and the probe that sizes the
    % sweep's own ranges uses it for the two readings it takes before the
    % range is known.
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

function [value, rangeNow, changes] = followRange(m, role, ranges, ...
                                                 rangeNow, value, changes)
% Keeps a meter on the smallest range its reading fits, one state at a
% time. Both meters use it, for different reasons.
%
% On volts it is resolution. A 34401A carries 0.0035% of reading plus
% 0.0005% of range, and at 10 mV on the 10 V range that second term is
% 50 uV against 0.35 uV from the first, so the points near the bottom of a
% ladder crossing three decades are almost entirely range floor.
%
% On amps it is survival. A pinned ammeter cannot follow illumination that
% moves, and a range it has run off the top of returns overflow, which is
% a NaN, which after five in a row aborts the run.
%
% Two rules with hysteresis between them, so a reading parked near a
% boundary cannot oscillate: widen at 90% of range or on overflow, narrow
% under 8%, and narrow straight to the range that fits rather than one
% step at a time, because the state after SHORT falls from volts to
% millivolts in a single move.
%
% Overflow is recovered rather than logged. The alternative is a NaN at
% exactly the state where the curve turns, that being where the reading
% climbs fastest.

    % Widened one range at a time until the reading fits or the meter has
    % nothing wider, because an overflow says nothing about how far over
    % it is. An adaptive sweep makes multi-decade jumps routine: a
    % refinement round ends near OPEN with the meter narrowed to its
    % floor, and the next one starts back at the bottom of the ladder.
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
% Range alone, without the function and without everything else the
% configuration carries. On the 34401A that matters: CONF resets the
% integration time, the autozero and the input impedance to that
% function's defaults, so re-configuring mid-sweep to change a range would
% quietly drop the meter back to 10 NPLC defaults and no high impedance
% input. RANGe leaves all of it alone.

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

function closePort(m)
    if isstruct(m)
        delete(m.Port);
    end
end


%% =====================================================================
%  Timing
%  =====================================================================

function closeMeters(meas)
% Closed without a reset, so an abort does not wipe the front panel setup.
    if ~isstruct(meas)
        return
    end
    hush(@() closePort(meas.V));
    hush(@() closePort(meas.I));
end

function hush(fn)
% Util.quietly, kept local so the meter library depends on nothing outside
% itself.
    try
        fn();
    catch
    end
end

function [volts, amps, fault] = readPair(meas, parallel, volts, amps)
% One trigger-and-collect of both meters. The values already held are
% passed in and returned unchanged if the exchange throws partway, so a
% fetch that succeeds on volts and fails on amps keeps the volts it got.

    fault = false;

    try
        if parallel
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
