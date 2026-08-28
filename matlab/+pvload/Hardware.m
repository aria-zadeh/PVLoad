classdef Hardware
% What the board is, as opposed to how it is run. Changes only when the
% hardware does, and docs/HARDWARE.md changes with it.

methods (Static)

function p = pins()
% docs/HARDWARE.md section 4. SCK/SDI/SDO are fixed by the Uno's hardware
% SPI peripheral and cannot be reassigned; Board.connect checks them.
%
% K1 bypasses the 470 kohm path, K2 shorts the whole load, K3 bypasses U2.
% All three are active high; CS# on both pots is active low.

    p = struct( ...
        'BoardType', "Uno", ...
        'SCK',  "D13", 'SDI',  "D11", 'SDO', "D12", ...
        'CsU1', "D10", 'CsU2', "D9", ...
        'K1',   "D6",  'K2',   "D7",  'K3',  "D8");
end

function m = model()
% Orders the sweep and labels output, and never enters a result: R_AB is
% +/-20% and R_WIPER is measured on one board, so resistance always comes
% off the meters. RWiper is the 155 ohm board 2 showed at a 24 V span,
% docs/BRINGUP.md; RContact is the reed maximum; ROpenPath is R1.

    m = struct( ...
        'RabNominal', 5000, ...     % ohms, one MCP41HV51-502 end to end
        'WiperSteps', 255, ...      % an 8-bit ladder has 255 step resistors
        'RWiper',     155, ...
        'RContact',   0.150, ...
        'ROpenPath',  470e3);
end

function t = timing()
% settle = max(RELAY, SAFETY * (switch + TAUS * R * C_LOAD + CELL)).
% The conversion is deliberately absent: the trigger goes out after this
% pause and the reply blocks for it, so counting it here would only slow
% the sweep.
%
% Overhead is seven USB round trips per state, measured off the clock and
% the term that made the old estimate too low. CLoad covers leads and
% meter input; Ranging.probe raises it if the cell measures slower.

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
