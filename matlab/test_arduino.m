% test_arduino - bench test of the Arduino alone, before the PCB exists
%
% Checks that every pin PVLoad-R1 uses can drive and read. Arduino and USB
% cable only; two tests also want a multimeter, two want one jumper.
%
% Pins under test, matching the pin map in PVLoad_Main.m:
%   D6  K1 drive        D10  U1 CS#
%   D7  K2 drive        D11  SDI  (MOSI)
%   D8  K3 drive        D12  SDO  (MISO)
%   D9  U2 CS#          D13  SCK        (also drives the onboard LED)
%
%
% MULTIMETER SETTINGS
%
%   Dial on DC voltage (V⎓ or DCV, not V~), 20 V range if manual. Black in
%   COM on any GND pin, red in V/Ω on the pin under test. 4.7 to 5.2 V is
%   a healthy HIGH, a few tens of millivolts a healthy LOW.
%
%   Never use the current (A) or resistance (Ω) setting on a driven pin.
%   In current mode the meter is a piece of wire, so probing a HIGH pin
%   against GND shorts it to ground, past the Uno's 40 mA absolute maximum.
%
%
% TESTS
%
%   "dmm_high"      All eight pins HIGH and left there. Each reads ~5 V.
%
%   "dmm_low"       Same, all LOW. Run after dmm_high; a pin stuck at 5 V
%                   here is a dead pin.
%
%   "dmm_walk"      Walks a single HIGH across the eight pins. Leave the
%                   probe on one and watch it pulse on its turn.
%
%   "loopback"      No multimeter, four jumpers. Drives one side of each
%                   pair and reads the other, then swaps, proving each pin
%                   works as input and output, which a voltage cannot.
%
%   "spi_loopback"  No multimeter, one jumper D11 to D12. The only test
%                   that exercises the SPI peripheral the DigiPots hang off.
%
%   "one_pin"       Drives ONE_PIN HIGH and LOW slowly, to be followed
%                   downstream with a voltmeter. Meant to run with the PCB
%                   attached. D6, D7 and D8 are identical circuits, so a
%                   working channel is the reference for a broken one.
%
% Run the first five in that order. Each is independent.

clear;
clc;

%% ---- Configuration ----------------------------------------------------

SERIAL_PORT = "COM4";       % must match your machine
BOARD_TYPE  = "Uno";

TEST = "one_pin";           % dmm_high | dmm_low | dmm_walk | loopback |
                            % spi_loopback | one_pin

WALK_DWELL = 2.0;           % seconds each pin stays HIGH in dmm_walk
WALK_PASSES = 9;            % how many times dmm_walk goes round

ONE_PIN        = "D7";      % pin driven by one_pin. the relay drives are
                            % D6 = K1, D7 = K2, D8 = K3.
ONE_PIN_PERIOD = 3.0;       % seconds in each state
ONE_PIN_CYCLES = 20;        % HIGH/LOW pairs before it stops

% Pins the PVLoad board uses, in header order.
PINS = ["D6", "D7", "D8", "D9", "D10", "D11", "D12", "D13"];
ROLES = ["K1 drive", "K2 drive", "K3 drive", "U2 CS#", ...
         "U1 CS#", "SDI (MOSI)", "SDO (MISO)", "SCK + onboard LED"];

% Jumper pairs for the loopback test. Every listed pin appears once, so
% four jumpers cover all eight pins.
LOOPBACK_PAIRS = ["D6", "D9"; "D7", "D10"; "D8", "D11"; "D12", "D13"];

% SPI loopback needs MOSI tied to MISO. CS is left unconnected.
SPI_CS = "D10";

%% ---- Run --------------------------------------------------------------

a = arduino(SERIAL_PORT, BOARD_TYPE, "Libraries", "SPI");
fprintf("Connected to %s on %s.\n\n", a.Board, a.Port);

switch TEST
    case "dmm_high"
        holdAllPins(a, PINS, ROLES, 1);
    case "dmm_low"
        holdAllPins(a, PINS, ROLES, 0);
    case "dmm_walk"
        walkPins(a, PINS, ROLES, WALK_DWELL, WALK_PASSES);
    case "loopback"
        runLoopback(a, LOOPBACK_PAIRS);
    case "spi_loopback"
        runSpiLoopback(a, SPI_CS);
    case "one_pin"
        drivePin(a, ONE_PIN, PINS, ROLES, ONE_PIN_PERIOD, ONE_PIN_CYCLES);
    otherwise
        error("test_arduino:BadTest", ...
            "TEST must be dmm_high, dmm_low, dmm_walk, loopback, " + ...
            "spi_loopback or one_pin, not ""%s"".", TEST);
end


%% =====================================================================
%  Multimeter tests
%  =====================================================================

function holdAllPins(a, pins, roles, level)
% The pins keep the level after the script finishes, because the arduino
% object stays in the workspace. Clearing it loses the state.

    if level == 1
        expected = "about 5 V";
    else
        expected = "about 0 V";
    end

    for k = 1:numel(pins)
        configurePin(a, pins(k), "DigitalOutput");
        writeDigitalPin(a, pins(k), level);
    end

    fprintf("All eight pins driven %s. Each should read %s.\n\n", ...
        upper(string(logicalName(level))), expected);
    fprintf("  black probe on any GND pin, red probe on:\n\n");
    for k = 1:numel(pins)
        fprintf("    %-4s  %s\n", pins(k), roles(k));
    end
    fprintf("\nPins hold this state until you clear the workspace.\n");

    if level == 1
        fprintf("The onboard LED next to pin 13 should be lit.\n");
    else
        fprintf("The onboard LED next to pin 13 should be dark.\n");
    end
end

function drivePin(a, pin, pins, roles, period, cycles)
% Toggled rather than held: a floating probe point and a working one read
% alike until something moves.
%
% Three points to follow, black lead on any ground:
%
%   the pin itself      ~5 V HIGH, ~0 V LOW. Anything else is the Arduino
%                       or the wire to the header, not the board.
%   transistor base     ~0.7 V HIGH, ~0 V LOW. Stuck at 0 V means the base
%                       resistor or the header connection.
%   transistor collector  ~0.2 V HIGH, ~5 V LOW, backwards because the
%                       transistor pulls the coil down on HIGH. Stuck at
%                       5 V means it is not switching; following correctly
%                       while the relay stays silent means the coil.

    idx = find(pins == pin, 1);
    if isempty(idx)
        error("test_arduino:BadPin", ...
            "ONE_PIN is ""%s"". This board brings out %s.", ...
            pin, strjoin(pins, ", "));
    end

    fprintf("Driving %s, %s, for %d cycles at %g s per state.\n", ...
        pin, roles(idx), cycles, period);
    fprintf("Ctrl-C to stop early. The pin is left LOW either way.\n\n");

    configurePin(a, pin, "DigitalOutput");

    try
        for k = 1:cycles
            for level = [1 0]
                writeDigitalPin(a, pin, level);
                fprintf("  %2d/%2d  %s = %s\n", k, cycles, pin, ...
                    logicalName(level));
                drawnow;
                pause(period);
            end
        end
    catch stopped
        writeDigitalPin(a, pin, 0);
        rethrow(stopped);
    end

    writeDigitalPin(a, pin, 0);
    fprintf("\nDone. %s left LOW.\n", pin);
end

function walkPins(a, pins, roles, dwell, passes)
% Takes one pin HIGH at a time with everything else LOW.

    for k = 1:numel(pins)
        configurePin(a, pins(k), "DigitalOutput");
        writeDigitalPin(a, pins(k), 0);
    end

    fprintf("Walking a HIGH across %d pins, %.1f s each, %d passes.\n", ...
        numel(pins), dwell, passes);
    fprintf("Leave the red probe on one pin and watch it rise to 5 V " + ...
        "on its turn.\n\n");

    for pass = 1:passes
        fprintf("-- pass %d of %d --\n", pass, passes);
        for k = 1:numel(pins)
            writeDigitalPin(a, pins(k), 1);
            fprintf("  %-4s HIGH   (%s)\n", pins(k), roles(k));
            pause(dwell);
            writeDigitalPin(a, pins(k), 0);
        end
    end

    fprintf("\nWalk finished. All pins left LOW.\n");
end


%% =====================================================================
%  Jumper tests, no multimeter needed
%  =====================================================================

function runLoopback(a, pairs)
% A voltage reading only shows a pin can push 5 V out. This shows the level
% arrives and that the receiving pin senses it, which is what SPI and chip
% select need.

    fprintf("Wire these four jumpers before continuing:\n\n");
    for k = 1:size(pairs, 1)
        fprintf("    %-4s  <---->  %s\n", pairs(k, 1), pairs(k, 2));
    end
    fprintf("\nStarting in 5 seconds.\n\n");
    pause(5);

    failures = 0;
    for k = 1:size(pairs, 1)
        failures = failures + testPair(a, pairs(k, 1), pairs(k, 2));
        failures = failures + testPair(a, pairs(k, 2), pairs(k, 1));
    end

    fprintf("\n");
    if failures == 0
        fprintf("Loopback passed. All eight pins drive and read correctly.\n");
    else
        fprintf("Loopback FAILED on %d of 8 directions.\n", failures);
        fprintf("Check the jumper seating before suspecting the board.\n");
    end
end

function failed = testPair(a, driver, listener)
% Drives one pin low then high and confirms the other follows.

    configurePin(a, driver, "DigitalOutput");
    configurePin(a, listener, "DigitalInput");

    failed = 0;
    for level = [0, 1]
        writeDigitalPin(a, driver, level);
        pause(0.05);
        seen = readDigitalPin(a, listener);
        if seen ~= level
            failed = 1;
            fprintf("  FAIL  %s driven %s, %s read %s\n", ...
                driver, logicalName(level), listener, logicalName(seen));
        end
    end

    if failed == 0
        fprintf("  ok    %s -> %s\n", driver, listener);
    end

    writeDigitalPin(a, driver, 0);
end

function runSpiLoopback(a, csPin)
% With D11 tied to D12 the SPI peripheral talks to itself, so what is
% clocked out comes straight back. Matching bytes mean the clock, the shift
% register and both data lines work. All zeros or all 0xFF mean the jumper
% is off or a data pin is dead.

    fprintf("Wire one jumper before continuing:\n\n");
    fprintf("    D11 (SDI/MOSI)  <---->  D12 (SDO/MISO)\n\n");
    fprintf("Starting in 5 seconds.\n\n");
    pause(5);

    dev = device(a, "SPIChipSelectPin", csPin, "SPIMode", 0);

    patterns = {uint8([165, 90]), uint8([0, 255]), uint8([1, 2, 4, 8]), ...
                uint8([255, 255])};

    failures = 0;
    for k = 1:numel(patterns)
        sent = patterns{k};
        got  = uint8(writeRead(dev, sent, 'uint8'));
        if isequal(got, sent)
            fprintf("  ok    sent %s\n", byteList(sent));
        else
            failures = failures + 1;
            fprintf("  FAIL  sent %s, got %s\n", byteList(sent), byteList(got));
        end
    end

    fprintf("\n");
    if failures == 0
        fprintf("SPI loopback passed. Clock and both data lines work.\n");
    else
        fprintf("SPI loopback FAILED on %d of %d patterns.\n", ...
            failures, numel(patterns));
        fprintf("All zeros or all 255 usually means the jumper is not " + ...
            "seated.\n");
    end
end


%% =====================================================================
%  Helpers
%  =====================================================================

function name = logicalName(level)
    if level == 1
        name = "high";
    else
        name = "low";
    end
end

function text = byteList(bytes)
    text = "[" + strjoin(compose("%3d", double(bytes)), " ") + "]";
end
