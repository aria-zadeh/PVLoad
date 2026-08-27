# Bring-up log, PVLoad-R1

What has actually been measured on the assembled boards. Design rationale is in
[DECISIONS.md](DECISIONS.md) and the hardware reference is
[HARDWARE.md](HARDWARE.md); neither is repeated here.

Two boards were built to the same design. **Board 2 is sound and is the one to
use.** Board 1 has two faults, recorded at the end.

---

## Bench

No cell attached. A handheld meter in ohms across J1 and J3 stands in for the
cell, so every reading is the load a cell would see. 24 V bench supply on J2 and
J3. Arduino Uno on COM4 through the 1x10 header. MATLAB drives it and `RUN`
selects the mode.

`RUN = "verify"` is the seven-hold check for a freshly assembled board. `"ramp"`
walks the whole sweep slowly enough to follow on a handheld. `"wiper"` and `"k3"`
isolate single elements. All four touch the board only, with no cell and no
bench meters involved.

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

---

## Host and meter link

MATLAB reaches the meter. The adapter is a Keysight 82357B and the bus runs on
Keysight IO Libraries, so `instrhwinfo('visa')` lists `agilent`, `keysight` and
`ni`, and `visadevlist` returns one instrument at `GPIB0::1::INSTR`. Getting
there needed the C++ runtime fix in [TROUBLESHOOTING.md](TROUBLESHOOTING.md);
none of it was a VISA setting.

The instrument answers, and it is the 196:

| Query | Reply |
|---|---|
| `U0X` | `1961000000010000000043600000000` |
| `U1X` | `196000000000000000000000000` |
| bare read | `NDCV-000.0001E+0` |

`U0` opens with the model number, which agrees with `DMM_R_MODEL = "196"` and with
`DMM_R_ADDRESS`. `U1` is all zeros after the prefix, so nothing is latched. The
reading is DC volts at −0.1 mV, which is the meter sitting on its own leads.

What that does not prove: only `U0` and `U1` have been sent. The rest of the 196
profile, `F2` for ohms and the setup string `Z0B0G0M0K2S2T5`, has never reached
the instrument. The first `RUN = "ohms"` is what tests it, and the `U1` query
that follows the setup string is what catches a letter the 196 does not take.

A fresh session has to be flushed before the first read or that read times out.
Reproduced on every run, both write terminators. `openMeter` flushes.

---

## Board 2, `RUN = "verify"`

| Hold | State | Measured | Proves |
|---|---|---|---|
| 1 | `OPEN` | 470 kΩ | R1, K1 releasing |
| 2 | `SHORT` | 0.004 Ω | K2 closing |
| 3 | `FULL` 0, 0 | 310 Ω | K1 closing, both wipers |
| 4 | `FULL` 255, 0 | 5.27 kΩ | U1 ladder |
| 5 | `FULL` 255, 255 | 10.22 kΩ | U2 ladder |
| 6 | `LOW` 0, 0 | 155.8 Ω | K3 closing |
| 7 | `LOW` 0, 255 | 155.8 Ω | K3 closing, proved |

The SPI self-test passes on both chips, reading wiper registers back at codes 0,
85, 170 and 255.

Everything derived from those seven numbers:

| Quantity | Value | Note |
|---|---|---|
| U1 ladder | 4960 Ω | hold 4 − hold 3 |
| U2 ladder | 4950 Ω | hold 5 − hold 4 |
| U1 wiper | 155.8 Ω | hold 6 − hold 2 |
| U2 wiper | 154.2 Ω | hold 3 − hold 6 |
| Probe and jack offset | 0.004 Ω | hold 2 |

Both ladders land within 1% of each other and about 1% under the 5 kΩ nominal,
comfortably inside the ±20% tolerance, so `R_AB_NOMINAL` stays at 5000. Both
wipers agree to 1% and sit between the datasheet's 75 Ω typical and 200 Ω
maximum. `R_WIPER` is now 155, measured rather than assumed.

Hold 7 is the one that matters for K3. `LOW` shorts U2 out, so U2's code cannot
reach the terminals and hold 7 has to equal hold 6. It does.

## Measuring with a handheld

A handheld carries its probes, its clips and both banana jacks in every reading.
On board 2 with a stacking plug at J3 that came to 0.004 Ω, which is negligible.
On board 1 it was 30–80 Ω and drifted between runs.

Prefer differences anyway. Every derived figure above is one, so none of them
depend on the probe path being good.

---

## Board 1 faults

**K3 does not close.** Confirmed with `RUN = "k3"`, which holds `LOW` and writes
U2 to 0 and 255 alternately. With K3 closed U2 is shorted out and all four holds
must read alike. They did not:

| Hold | U2 code | Measured |
|---|---|---|
| A | 0 | 308 Ω |
| B | 255 | 5.27 kΩ |
| C | 0 | 308 Ω |
| D | 255 | 5.27 kΩ |

U2's whole ladder appears and disappears with its code, so U2 is in the path in
`LOW` as well as in `FULL` and K3 never operates.

The drive is not at fault. `setMode` raises D8 for `LOW`, matching section 4 of
HARDWARE.md, and Q3's collector swings 5 V to 0.04 V with the pin. A collector
that reaches 0.04 V rules out a reversed flyback diode, which would clamp it near
4.3 V, and a clean 5 V when off means the coil is continuous. So the coil is
driven at about 4.96 V and the contact still does not close: either the relay
itself, or its COM and NO pins not reaching the board.

This failure is invisible to every other test. It only makes `LOW` and `FULL`
read alike, which looks like a component with no resistance rather than a relay
that never moved.

**About 60 Ω in the `SHORT` path.** Board 1 reads 30–80 Ω at `SHORT` and drifts
between runs; board 2 reads 0.004 Ω through the same leads and the same meter.
The leads are therefore not the cause and it is on the board — K2, its joints, or
the jacks.

---

## Open

**The 196 command profile past `U0` and `U1` is unverified.** `F2`, the range
codes and `Z0B0G0M0K2S2T5` were inferred from the Keithley command family rather
than read off the 196 manual. The first `RUN = "ohms"` exercises them.

**`CELL_SETTLE` is zero and unmeasured.**

**`ISC_FULL` and `VOC_FULL` are the values the file shipped with.**
The cell is a power-over-fiber receiver for a SiC MOSFET gate driver. Its Voc and
Isc have not been entered.
