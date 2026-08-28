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

## Both meters, `RUN = "meters"`

The bench runs an Agilent 34401A on volts at `GPIB0::22::INSTR` and a Keithley
196 on amps at `GPIB0::1::INSTR`, through one Keysight 82357B. `visadevlist`
names the 34401A and leaves the 196's columns empty, which is what a meter with
no `*IDN?` looks like.

Both identify:

| Query | Reply |
|---|---|
| `*IDN?` | `HEWLETT-PACKARD,34401A,0,11-5-2` |
| `U0X` | `1961000000010000000043600000000` |

Three faults came out of getting from there to ten readings. All three were in
the script rather than on the bench, and the order they surfaced in matters,
because two of them cancelled.

**`TRIG:DEL AUTO` is not a 34401A command.** `SYST:ERR?` answered
`-224,"Illegal parameter value"`. Manual page 80 gives `TRIGger:DELay
{<seconds>|MINimum|MAXimum}` and `TRIGger:DELay:AUTO {OFF|ON}` as separate
commands, so `AUTO` is a node and not a parameter. Corrected to
`TRIG:DEL:AUTO ON`.

**Under `T5` every command string leaves a reading behind.** The trailing `X`
that executes a setup string is also the trigger, so the conversion it starts is
never collected and the next query reads it instead of its own answer. This
showed up as `U1` answering `NDCI-00.00009E-3`, a current reading where the
error word should have been. Queries now flush the input first, and
`configureMeter` flushes again when it is done, so the sweep starts on an empty
buffer. The duplicate call that configured the ammeter twice is gone as well.

**The 196 tags DC amps `DCI`.** Figure 3-6: `DCV`, `ACV`, `OHM`, `OCO`, `DCI`,
`ACI`, `dBV`, `dBI`. The decoder had been matching `DCA`, which this meter never
sends, so a current reading would have decoded to NaN. The tag list now lives in
the profile.

The run that produced ten clean readings did so with two of these still
outstanding, which is worth remembering. A `flush` that cleared the output buffer
as well as the input had discarded the `F3R3...` setup string, so the 196 was
still in its power-on DC volts; `U1` then came back clean because no bad command
had reached it, and the volts reading decoded because `DCV` was in the old tag
list. The console read `I = -0.000400 A` and the number was a few hundred
microvolts of float on an open input. **It was caught by looking at the front
panel, which said volts on both meters.** Nothing in the software noticed.

---

## Open

**The 196 command profile is now read off manual 196-901-01 Rev D**, not
inferred: functions from section 3.9.2, ranges from table 3-9, the setup string
from table 3-8, the 24 ms conversion from table 3-16, the reading tags from
figure 3-6. Inference had the lowest amps range at 3 mA where it is 300 uA, and
the conversion at 350 ms where it is 24 ms.

**The first sweep on a cell ran clean and the cell is far dimmer than the board
was sized for.** Run `20260828_145929`, tagged `ILASER0p42`, 0.42 A of laser
drive: 769 of 769 states, no dropped readings, current drift −0.011 %/min over
10.6 minutes. The instrument chain is finished. What it measured:

| | measured | the board wants |
|---|---|---|
| Isc | 64.8 µA | ~1 mA and up |
| V at the top of the ladder | 0.683 V | most of Voc |
| OPEN state current | 7.07 µA, 10.9 % of Isc | under 5 % |

Three consequences, none of them software faults. The ladder stops at 10.3 kΩ
and this cell needs about 36.5 kΩ to reach 70 % of Voc, so the sweep never
leaves the current-source plateau and the knee falls in the gap between the top
of the ladder and R1. The `OPEN` state is not open at this light: 470 kΩ draws
11 % of Isc, so its 3.384 V is a floor under Voc rather than Voc. Fill factor
inherits both errors and means nothing on this run.

More light is the whole fix; the board cannot make a load between 10.3 kΩ and
470 kΩ. Isc of roughly 270 µA puts the knee at the very top of the ladder and
1–2 mA puts it where the sampling is dense, which is 4× to 30× the
illumination of this run.

`ISC_FULL` is now 100 µA, which also moves the 196 off its 30 mA range, where
the cell was living in the bottom 0.2 %, onto 300 µA. `summariseCurve` decides
both of the above from the measurement and says so, and the figure no longer
draws a line from the top of the ladder to the `OPEN` point across the region
nothing was measured in.

**The input-only flush and the `DCI` tag passed on the bench.** Repeated
`RUN = "meters"` with both instruments attached and nothing connected to their
inputs: both identify, both configure, and ten readings sit at noise, volts
around a hundred microvolts and current at one count on the 30 mA range. The
196 read amps on its face and the 34401A volts.

**Every session-open fault traced to one cause: `visadev` sends `*IDN?` on
open.** It cannot be suppressed in R2022a, the 196 cannot execute it without a
trailing `X`, and the stranded fragment eats the next command and latches
IDDCO late. Chased as three separate faults before that: a first command that
vanished, `U0` answered with readings after a power cycle (power-on `T0`,
trigger on talk), and `TRIGGER ERROR` on the display with every command sent
being valid. `primeDdc` absorbs it at open and `ddcVerifySetup` now checks the
`U0` machine word digit against what was sent instead of trusting `U1`; the
word positions were mapped on this bench by toggling one setting at a time
(`F` at 3, `K` at 6, `R` at 18, `S` at 19, `T` at 20, `Z` at 27, counted after
the prefix). Error-word bits measured while at it: `F9X` latches the first
digit, `Q9X` the eleventh. `docs/TROUBLESHOOTING.md` has the full story.

**Overlapped reads are still assumed rather than shown.** Both meters have been
triggered and collected together, but never against a source that would make a
one-state lag visible. Step between two widely separated load states and see
whether the reading follows.

**`CELL_SETTLE` is zero and unmeasured.**

**`ISC_FULL` and `VOC_FULL` are the values the file shipped with.**
The cell is a power-over-fiber receiver for a SiC MOSFET gate driver. Its Voc and
Isc have not been entered.
