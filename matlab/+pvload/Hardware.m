classdef Hardware

methods (Static)

function p = pins()

    p = struct( ...
        'BoardType', "Uno", ...
        'SCK',  "D13", 'SDI',  "D11", 'SDO', "D12", ...
        'CsU1', "D10", 'CsU2', "D9", ...
        'K1',   "D6",  'K2',   "D7",  'K3',  "D8");
end

function m = model()

    m = struct( ...
        'RabNominal', 5000, ...     % ohms, one MCP41HV51-502 end to end
        'WiperSteps', 255, ...      % an 8-bit ladder has 255 step resistors
        'RWiper',     155, ...
        'RContact',   0.150, ...
        'ROpenPath',  470e3);
end

function t = timing()

    t = struct( ...
        'RelaySettle', 0.010, ...   % s. HARDWARE.md s6; the relays spec 1.0 ms
        'WiperSettle', 0.001, ...   % s. the pot settles in ~1 us; SPI round trip
        'Safety',      1.5, ...     % USB jitter and pause() granularity
        'Overhead',    0.08, ...
        'TauCount',    7, ...       % e^-7 is 0.09%
        'CLoad',       300e-12, ...
        'CellSettle',  0.020);      % flat hold on top of the RC term
end

end
end
