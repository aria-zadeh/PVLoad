% test_arduino - bench test of the Arduino alone, before the PCB exists
%
% Checks that every pin PVLoad-R1 uses can actually drive and read.
% Nothing but the Arduino and a USB cable is required. Two of the tests
% additionally use a multimeter, and two use a single male-to-male jumper.
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
%   Dial:   DC voltage. Marked V with a straight line and dashes above it
%           (V⎓), or DCV. Not V~, which is AC.
%   Range:  20 V if the meter is manual-ranging. Autoranging meters pick it
%           themselves.
%   Black:  into COM, probe on any Arduino GND pin.
%   Red:    into the V/Ω socket, probe on the pin being tested.
%
%   Expect about 5 V for HIGH and about 0 V for LOW. Anything from 4.7 to
%   5.2 V is a healthy HIGH. A few tens of millivolts is a healthy LOW.
%
%   Do not use the current (A) or resistance (Ω) setting on a pin that is
%   being driven. In current mode the meter is a piece of wire, so probing
%   a HIGH pin against GND shorts that pin straight to ground. An Uno pin
%   is rated 40 mA absolute maximum and that connection exceeds it.
%
%
% TESTS
%
%   "dmm_high"      Drive all eight pins HIGH and leave them there. Probe
%                   each one at your own pace. Every one should read ~5 V.
%
%   "dmm_low"       Same, all LOW. Every one should read ~0 V. Run this
%                   after dmm_high; a pin stuck at 5 V here is a dead pin.
%
%   "dmm_walk"      Walk a single HIGH across the eight pins, one at a
%                   time, printing which one is live. Leave the probe on
%                   one pin and watch it pulse when its turn comes round.
%
%   "loopback"      No multimeter. Jumper the pins in pairs as printed,
%                   and the script drives one side and reads the other,
%                   then swaps. This proves each pin works as both an
%                   output and an input, which a voltage reading cannot.
%
%   "spi_loopback"  No multimeter. One jumper from D11 to D12. The script
%                   sends bytes over the real SPI peripheral and checks
%                   they come back. This is the only test that exercises
%                   the SPI hardware itself, which is what the DigiPots
%                   will hang off.
%
% Run the tests in that order. Each is independent.

clear;
clc;

%% ---- Configuration ----------------------------------------------------

SERIAL_PORT = "COM4";       % must match your machine
BOARD_TYPE  = "Uno";

TEST = "spi_loopback";          % dmm_high | dmm_low | dmm_walk | loopback |
                            % spi_loopback

WALK_DWELL = 2.0;           % seconds each pin stays HIGH in dmm_walk
WALK_PASSES = 9;            % how many times dmm_walk goes round

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
    otherwise
        error("test_arduino:BadTest", ...
            "TEST must be dmm_high, dmm_low, dmm_walk, loopback or " + ...
            "spi_loopback, not ""%s"".", TEST);
end


%% =====================================================================
%  Multimeter tests
%  =====================================================================

function holdAllPins(a, pins, roles, level)
% Drives every pin to one level and leaves it there.
%
% The pins keep that level after the script finishes, because the arduino
% object stays in the workspace. Probe at whatever pace suits you. The
% state is lost when you clear the workspace or unplug the board.

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
% Drives one pin of each pair and reads the other, then swaps roles.
%
% A voltage reading only shows that a pin can push 5 V out. This shows the
% level actually arrives somewhere and that the receiving pin can sense it,
% which is what SPI and chip select need.

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
% Sends bytes out of MOSI and checks they arrive back on MISO.
%
% With D11 tied to D12 the SPI peripheral is talking to itself, so whatever
% is clocked out is clocked straight back in. If the returned bytes match,
% the clock, the shift register and both data lines are working. If they
% come back as all zeros or all 0xFF, the jumper is off or a data pin is
% dead.

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
