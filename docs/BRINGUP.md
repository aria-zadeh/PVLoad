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

## K3 does not close

Confirmed with `RUN = "k3"`, which holds `LOW` and writes U2 to 0 and 255
alternately. With K3 closed U2 is shorted out and its code cannot reach the
terminals, so all four holds must read alike. They did not:

| Hold | U2 code | Measured |
|---|---|---|
| A | 0 | 308 Ω |
| B | 255 | 5.27 kΩ |
| C | 0 | 308 Ω |
| D | 255 | 5.27 kΩ |

U2's whole ladder appears and disappears with its code, so U2 is in the path in
`LOW` as well as in `FULL` and K3 never operates. Repeatable, and the two pairs
match exactly.

The software side is not at fault: `setMode` drives D8 high for `LOW`, matching
section 4 of HARDWARE.md. The fault is in D8 → R4 → Q3 → the K3 coil.

This one failure explains the two readings that made no sense on their own.
`LOW` and `FULL` read alike at every code because they contain the same
elements, and the 242 Ω between `SHORT` and the lowest pot setting is not one
wiper plus a mystery, it is **two wipers at about 121 Ω each** — inside the
datasheet's 75 Ω typical to 200 Ω maximum.

Nothing else on the board can see this failure. It only makes two modes agree,
which reads as a component with no resistance rather than a relay that never
moved.

Effect on a sweep: the range is unchanged at 0.150 Ω to 470 kΩ, but `LOW`
duplicates `FULL` instead of interleaving with it, so 769 states collapse to 511
distinct ones and the lowest load rises from about 121 Ω to about 242 Ω. Usable,
but half the resolution the board was designed for.

## Open

**`R_WIPER` is still the 200 Ω placeholder.** About 121 Ω per device is the
figure the measurements imply, but it should be confirmed on a board where K3
works before it goes into the file, since the `LOW` states it also describes are
not behaving as modelled right now.

**`CELL_SETTLE` is zero and unmeasured.**

**`ISC_FULL`, `VOC_FULL` and `POWER_FULL` are the values the file shipped with.**
The cell is a power-over-fiber receiver for a SiC MOSFET gate driver. Its Voc and
Isc have not been entered.
