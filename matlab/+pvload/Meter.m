classdef Meter

methods (Static)

function meas = connect(dmm, vRange, iRange)

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

function [volts, amps, fault, meas] = readPoint(meas, parallel)

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

    if meas.IChanges > iChangesBefore && ~isnan(amps)
        [volts, amps, reread] = readPair(meas, parallel, volts, amps);
        fault = fault || reread;
    end

    fault = fault || isnan(volts) || isnan(amps);
end

function value = readOnce(m)
    value = meterReadOnce(m);
end

function meas = setRanges(meas, vRange, iRange)

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

    D    = m.Ddc;
    node = functionFor(D, role);
    auto = range <= 0;

    if auto
        select = "CONF:" + node;
    else
        rangeCode(range, m.Ranges, rangeSetting(role), m.Label);
        select = sprintf("CONF:%s %g", node, range);
    end

    % CONF resets NPLC, autozero and input impedance, so everything
    % below has to come after it
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

        % voltmeter only
        meterTell(m, D.HighZ);
    end
end

function m = openMeter(spec, role)

    m = spec;
    D = spec.Ddc;

    try
        m.Port = visadev(spec.Address);
        m.Port.Timeout = spec.Timeout;
        configureTerminator(m.Port, D.ReadTerm, D.WriteTerm);

        % first read times out otherwise: the meter can be mid-reading
        flush(m.Port, "input");
        if D.Dialect == "scpi"
            if startsWith(upper(string(spec.Address)), "ASRL")

                % ASRL only. GPIB addressing does this, and rejects the command
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

    % visadev sends *IDN? and cannot be told not to. The 196 executes
    % nothing without a trailing X, so it sits in the parser and the next
    % command gets concatenated onto it. The bare X below flushes it out.
    % T5 leaves trigger-on-talk; a drain still returning readings means it
    % was swallowed, hence the retry.
    pause(0.5);
    ddcTell(m.Port, "");
    pause(0.3);

    % *IDN?'s tail is painted on the display. A bare D clears it.
    ddcTell(m.Port, "D");
    pause(0.3);

    % every command ends in X and every X triggers, so the last one left
    % a reading nobody collected
    flush(m.Port, "input");

    for attempt = 1:3
        ddcTell(m.Port, "T5");

        % visadev sends *IDN? and cannot be told not to. The 196 executes
        % nothing without a trailing X, so it sits in the parser and the next
        % command gets concatenated onto it. The bare X below flushes it out.
        % T5 leaves trigger-on-talk; a drain still returning readings means it
        % was swallowed, hence the retry.
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

    if m.Ddc.Dialect == "scpi"
        scpiConfigure(m, role, range);
        assertMeterHappy(m, role);
    else
        sent = ddcConfigure(m, role, range);
        ddcVerifySetup(m, role, sent);
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

    D  = m.Ddc;
    fn = functionFor(D, role);

    if range <= 0
        command = fn + D.AutoRange;
    else
        command = fn + sprintf(D.Range, ...
            rangeCode(range, m.Ranges, rangeSetting(role), m.Label));
    end

    % the X in this string is also a trigger
    sent = command + D.Common;
    ddcTell(m.Port, sent);

    pause(0.2);
end

function assertMeterHappy(m, role)

    % drained, not popped: a setup can have several rejects
    faults = scpiErrorQueue(m);
    if isempty(faults)
        return
    end
    error("PVLoad:MeterRejectedSetup", ...
        "The %s meter (%s) answered %s with %s.", ...
        role, m.Label, m.Ddc.Error, strjoin("""" + faults + """", "; "));
end

function ddcVerifySetup(m, role, sent)

    % checked against the machine word, not the error word, which is
    % unreliable near a session open
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

    % R numbers are positions in the list, table 3-12
    code = find(abs(ranges - range) <= 1e-9 * ranges, 1);
    if isempty(code)
        error("PVLoad:BadMeterRange", ...
            "%s is %g. The %s has %s.", ...
            name, range, label, strjoin(string(ranges), ", "));
    end
end

function [value, rangeNow, changes] = followRange(m, role, ranges, ...
                                                 rangeNow, value, changes)

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

    D = m.Ddc;

    if D.Dialect == "scpi"
        meterTell(m, sprintf(D.RangeOnly, functionFor(D, role), range));
        return
    end

    meterTell(m, sprintf(D.RangeOnly, ...
        rangeCode(range, m.Ranges, rangeSetting(role), m.Label)));

    % so does this one
    pause(0.15);
    flush(m.Port, "input");
end

function meterTrigger(m)

    if m.Ddc.Dialect == "scpi"
        writeline(m.Port, m.Ddc.Trigger);
    else
        ddcTell(m.Port, "");
    end
end

function value = meterFetch(m)

    if m.Ddc.Dialect == "scpi"
        value = meterDecode(m, meterAsk(m, m.Ddc.Fetch));
    else
        value = meterDecode(m, readline(m.Port));
    end
end

function value = meterReadOnce(m)

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

    % G0 asks for the prefix, so a reply without one is not our reading.
    % The 196 tags DC amps DCI, not DCA.
    text   = extractBefore(strtrim(string(reply)) + ",", ",");   % G2 suffix
    prefix = regexp(text, "^[NO](" + prefixes + ")", "match", "once");

    if ismissing(prefix) || startsWith(prefix, "O")
        value = NaN;
        return
    end

    value = str2double(extractAfter(text, strlength(prefix)));
end

function value = scpiDecode(reply, overflow)

    % 9.9e37 is overflow and otherwise a perfectly valid number
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

    % a stale reading can still be inside the meter, so read past up to two
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

    % nothing happens on a 196 until an X arrives
    writeline(port, command + "X");
end

function reply = ddcAsk(m, command)

    flush(m.Port, "input");
    ddcTell(m.Port, command);
    reply = strtrim(string(readline(m.Port)));
    if strlength(reply) == 0
        error("PVLoad:MeterNoReply", ...
            "No reply to ""%sX"" within %g s.", command, m.Timeout);
    end

    % the query's own X started a conversion; let it finish
    pause(0.1);
end

function closePort(m)
    if isstruct(m)
        delete(m.Port);
    end
end

function closeMeters(meas)
    if ~isstruct(meas)
        return
    end
    hush(@() closePort(meas.V));
    hush(@() closePort(meas.I));
end

function hush(fn)
    try
        fn();
    catch
    end
end

function [volts, amps, fault] = readPair(meas, parallel, volts, amps)

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
