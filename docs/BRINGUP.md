# Bring-up log, PVLoad-R1

What has actually been measured on the assembled board. Design rationale is in
[DECISIONS.md](DECISIONS.md) and the hardware reference is
[HARDWARE.md](HARDWARE.md); neither is repeated here.

---

## Bench

No cell attached. A handheld meter in ohms across J1 and J3 stands in for the
cell, so every reading is the load a cell would see. 24 V bench supply on J2 and
J3. Arduino Uno on COM4 through the 1x10 header. MATLAB drives it and `RUN`
selects the mode.

`RUN = "ramp"` walks the whole sweep slowly enough to follow on a handheld.
`RUN = "wiper"` parks on pairs of states whose difference isolates one element.
Both touch the board only, with no laser and no bench meters involved.

## Power order

Up: 24 V, then the Arduino. The Arduino's 5 V pin is the board's logic and coil
supply, so plugging it in is what raises the 5 V rail.

Down: Arduino, then 24 V.

The first session ran with the 24 V output switched off. The ladders still
measured correctly, because the resistor string is passive and needs no rail,
but the wiper switches had no analog supply and read several hundred ohms to a
kilohm. Every wiper figure from that session was discarded. A reading that looks
like a large unexplained series resistance is worth checking against the supply
before it is chased into the board.

## Confirmed

| Element | Measured | Expected |
|---|---|---|
| SPI, both chips | registers read back at codes 0, 85, 170, 255 | — |
| U1 ladder | 5133 Ω, 20.13 Ω/step | 5 kΩ ±20% |
| U2 ladder | 4960 Ω, 19.45 Ω/step | 5 kΩ ±20% |
| R1, the `OPEN` path | 470 kΩ | 470 kΩ |
| K1, K2 | operate | — |

## Measuring with a handheld

A handheld carries its probes, its clips and both banana jacks in every reading.
Here that came to 30–80 Ω and moved between runs, with the supply return and the
meter's black lead sharing J3. It is hundreds of times a reed contact and it
drifts, so absolute readings are not usable for anything small.

Every figure above is a difference between two states, which cancels it. That is
what `RUN = "wiper"` is for.

## Open

**K3 may not be closing.** `LOW` and `FULL` read alike at every code tried, which
taken at face value means U2 contributes no wiper resistance. The datasheet puts
R_W at 75 Ω typical and 200 Ω maximum, and the 242 Ω measured between `SHORT` and
the lowest pot setting is close to two of those. Both observations are explained
at once if K3 never closes, leaving U2 in the path in `LOW` as well as `FULL`.

`RUN = "wiper"` ends with a check for exactly this. It holds `LOW` while writing
U2 to 0 and 255 alternately. With K3 closed, U2's code cannot reach the
terminals and all four readings match; a 5 kΩ swing is K3 failing to close.

This failure is invisible to every other test on the board. It does not affect
the range, it makes `LOW` and `FULL` collapse onto one ladder and costs the
sweep the 256 states `LOW` contributes.

**`R_WIPER` is still the 200 Ω placeholder.** The figure implied above is about
121 Ω per device, which is inside the datasheet range. Pending the K3 result.

**`CELL_SETTLE` is zero and unmeasured.**

**`ISC_FULL`, `VOC_FULL` and `POWER_FULL` are the values the file shipped with.**
The cell is a power-over-fiber receiver for a SiC MOSFET gate driver. Its Voc and
Isc have not been entered.
