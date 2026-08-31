classdef Board

methods (Static)

function board = connect(cfg)
    board = connectBoard(cfg);
end

function mode(board, name)
    setMode(board, name);
end

function wipers(board, code1, code2)
    setWipers(board, code1, code2);
end

function apply(board, state, settle)
    applyState(board, state, settle);
end

function safeState(board)
    enterSafeState(board);
end

function selfTest(board)
    selfTestPotentiometers(board);
end

end
end

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

    configurePin(a, cfg.PinK1, "DigitalOutput");
    configurePin(a, cfg.PinK2, "DigitalOutput");
    configurePin(a, cfg.PinK3, "DigitalOutput");
end

function assertSpiPins(a, cfg)

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

    % K2 opens first, or the short stays closed into OPEN and Voc reads 0
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

    if ~isscalar(code) || code < 0 || code > 255 || mod(code, 1) ~= 0
        error("PVLoad:BadWiperCode", "Wiper code must be an integer 0-255.");
    end
    writeRead(dev, uint8([0, code]), 'uint8');
end

function code = readWiper(dev)

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

    % U2 is written even when K3 bypasses it, so it is never unknown
    writeWiper(board.U1, code1);
    writeWiper(board.U2, code2);

    verifyWiper(board.U1, code1, "U1");
    verifyWiper(board.U2, code2, "U2");
end

function selfTestPotentiometers(board)

    % a bad supply order silently forces the wiper to mid-scale
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
