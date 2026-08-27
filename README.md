# PVLoad

Automated I-V curve measurement for photovoltaic cells. A programmable resistive load steps through
769 load states while two bench multimeters record voltage and current at each one.

Hardware is a 2-layer PCB carrying two SPI digital potentiometers and three reed relays. Control is
MATLAB, over an Arduino Uno.

![PCB 3D render](docs/img/pcb-3d.png)

## Overview

A cell's operating point depends on its load, so characterizing one means sweeping the load and
recording voltage and current at each step. This board replaces a manually adjusted resistor with
two MCP41HV51 digital potentiometers in series and three reed relays, giving 769 distinct load
states from 0.150 Ω to 470 kΩ under software control.

Relays reconfigure the topology to reach the ends of the curve, which the potentiometers cannot:

| Mode | Relay action | Region |
|---|---|---|
| `SHORT` | Bypass the whole load | Short-circuit current |
| `LOW` | Bypass the second potentiometer | ~155 Ω to 5.2 kΩ |
| `FULL` | Both potentiometers in series | ~310 Ω to 10.3 kΩ |
| `OPEN` | 470 kΩ in series | Open-circuit voltage |

`LOW` and `FULL` start from one and two wiper resistances respectively. The offset is not an integer
number of steps, so the two ladders interleave and resolve finer than the 19.6 Ω step size.

An I-V curve is only defined at a stated illumination, but the illumination is set by hand and the
software does not touch it. One run of the sweep is one curve at whatever light the bench is under;
a family of curves is several runs, told apart by `RUN_TAG`.

The board contains no measurement circuitry. Voltage and current come from two bench multimeters
addressed over VISA: a Keithley 196 and an Agilent 34401A.

![Schematic](docs/img/schematic.png)

## Specifications

| Parameter | Value |
|---|---|
| Load range, both potentiometers | ~310 Ω to 10.3 kΩ |
| Load range, one potentiometer bypassed | ~155 Ω to 5.2 kΩ |
| Step size | ~19.6 Ω |
| Load states per sweep | 769 |
| Short-circuit path | 0.150 Ω relay contact |
| Open-circuit path | 470 kΩ |
| Cell under test | ≤9 V open circuit, ≤16 mA short circuit |
| Illumination | Set by hand, not by this software |
| Control | SPI from an Arduino Uno, driven from MATLAB |
| Supplies | 24 V bench supply (analog), 5 V from the Arduino (logic) |
| Board | 2-layer, hand-assembled |

## Design notes

**Two potentiometers.** A single MCP41HV51-502 is 5 kΩ end to end. Two in series reach 10 kΩ and
produce the interleaved ladders described above.

**High-voltage potentiometer.** The MCP41HV51 separates its resistor-network supply from its logic
supply, so the network runs at 24 V while logic runs at 5 V. A cell reaching 9 V would clip a
part powered from the logic rail alone. This is why the board takes two supplies and why power
sequencing matters.

**Reed relays.** At 16 mA, contacts operate in dry-circuit conditions where silver-alloy power
contacts can develop surface films and read as intermittent opens. A sealed reed capsule avoids
this and holds contact resistance to 0.150 Ω, which sets the short-circuit endpoint. Coils draw
10 mA each and run from the Arduino's 5 V pin.

**Relay topology.** Every relay is wired in parallel with an element, never in series, since a
series relay could only break the loop. The open-circuit end is therefore a 470 kΩ resistor that K1
shorts out for the rest of the sweep, passing ~19 µA at 9 V.

**Coil drivers.** Each coil is switched by a 2N3904 low-side NPN through a 1 kΩ base resistor, with
a 1N4148 flyback diode across the coil. The relay has no internal diode.

**No on-board ADC.** An integrated converter would require calibration against a bench meter, so
the meters are used directly.

**Two meters.** Current is measured in series and voltage in parallel; one instrument cannot do
both simultaneously. Both are triggered before either reply is read, so their conversions overlap
and the readings describe the same instant. They need not be the same model, and on this bench they
are not: the voltmeter and the ammeter carry separate command profiles.

## Repository layout

```
docs/
  HARDWARE.md      Topology, pin map, SPI protocol, BOM
  DECISIONS.md     Design rationale and open questions
  BRINGUP.md       What has been measured on the assembled board
  TROUBLESHOOTING.md  Finding a fault with a handheld meter
  PVLoad_BenchCard.pdf   One-page printable bench reference
  benchcard.html   Source for the bench card
  img/             Schematic and PCB renders
hardware/
  altium/          Altium project, footprint and symbol libraries, STEP model
  gerbers/         Gerber X2 and NC drill files
  bom.pdf          Bill of materials
matlab/
  PVLoad_Main.m    Sweep controller and meter drivers
  test_arduino.m   Pin-by-pin bench test of the Arduino alone
data/
  sweep_data/      CSV output
```

[`docs/HARDWARE.md`](docs/HARDWARE.md) is the hardware reference: node-by-node topology, Arduino pin
map, SPI command format, initialization requirements, timing, and BOM with part selection reasoning.
[`docs/DECISIONS.md`](docs/DECISIONS.md) covers software design rationale and unresolved items.

## Requirements

| Component | Requires |
|---|---|
| Board | MATLAB R2019a+, MATLAB Support Package for Arduino Hardware, Arduino Uno, 24 V bench supply |
| Meters | A Keithley 196 and an Agilent 34401A, in either role. USB-GPIB adapter, Instrument Control Toolbox, vendor VISA runtime |
| Illumination | Whatever lights the cell. Set and recorded by hand |

No firmware to compile. The support package ships its own, and SPI transactions are issued from the
host over USB.

Instrument Control Toolbox does not include a VISA implementation. Install NI-VISA or Keysight IO
Libraries separately, matching the vendor to your GPIB adapter. Without one, `visadevlist` reports
`Unable to find VISA installations`; with one and no instruments attached it reports `Unable to
find any VISA resources`.

`DMM_V_MODEL`, `DMM_I_MODEL`, and `DMM_R_MODEL` select the instrument for each meter, from `"196"`
and `"34401A"`. The model is named per meter rather than once for the bench, so the voltmeter and
the ammeter can be different instruments, and here they are. One profile per model at the top of
Part 2 holds what differs: which command selects which function, what ranges exist, and how a
reading is decoded. Each meter carries its own profile from the moment it is opened.

The two speak different languages. On the 196 a command is a letter and a number, several travel in
one string, and nothing takes effect until an `X` arrives. The 34401A is SCPI, so its commands are
words, one per line, and a reading is a bare number with no prefix. Each profile carries a dialect
and the functions that talk to the bus branch on it, so both are in use at once during a sweep.

The 196 profile is read off Keithley 196-901-01 Rev D: functions from §3.9.2, ranges from table 3-9,
the setup string from table 3-8, the 24 ms conversion from table 3-16, and the reading tags from
figure 3-6. The 34401A profile is read off 34401-90004. Both have now been opened, identified and
configured on the bench; neither has been run against a cell. Either way the setup is followed by
the error query, so a command the meter does not know fails at configuration rather than producing a
wrong number. [docs/BRINGUP.md](docs/BRINGUP.md) records what the bench actually said, including the
three faults that took getting there.

The 196 has an IEEE-488 interface and nothing else, so it requires a USB-GPIB adapter. Match the
adapter to the installed VISA: NI-VISA drives National Instruments hardware, Keysight IO Libraries
drive Keysight hardware. The 34401A also has an RS-232 port, which VISA reaches as an `ASRL`
resource; the script sends `SYST:REM` on that transport only, because GPIB addressing does the same
job and the command is not valid there.

On Windows, Keysight VISA can fail inside MATLAB while working in every other program. MATLAB loads
the copy of `MSVCP140.dll` it ships in `bin\win64` in preference to the system copy, and if that copy
is older than the runtime Keysight IO Libraries was built against, the Keysight VISA library fails to
initialise. `instrhwinfo('visa')` then omits `keysight` and `visadevlist` finds nothing.
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) has the diagnosis and the fix.

## Setup

Order matters. The cell is a supply, so it goes in last and comes out first — see
[Safety](#safety).

1. Connect the Arduino to the board through the 1x10 header.
2. Connect the bench supply to J2 (+24 V) and J3 (GND).
3. Connect the cell to J1 (PV+) and J3 (GND), with the ammeter in series on the PV+ lead, and
   keep it dark for now. Current goes into the ammeter's own terminal, `AMPS` on the 196 and the
   fused current terminal on the 34401A, never the volts terminal.
4. Connect the voltmeter across the cell terminals, upstream of the ammeter. Not across J1 and J3 —
   see [Measurement notes](#measurement-notes).
5. Power up 24 V first, then the Arduino.
6. Set `RUN`, the port and address settings, and `RUN_TAG` in Part 1 of `matlab/PVLoad_Main.m`,
   then start it.
7. Illuminate the cell once the script is running and the relays are in a defined state.

Shut down in reverse: darken the cell, then the Arduino's 5 V, then 24 V.

## Usage

`RUN` selects the mode. Each opens only the hardware it needs, so subsystems can be brought up
independently.

| `RUN` | Opens | Purpose |
|---|---|---|
| `"plan"` | nothing | Validate configuration, print time estimate |
| `"board"` | Arduino | Safe state, potentiometer self-test, walk a spread of load states |
| `"ramp"` | Arduino | Climb the resistance range slowly enough to follow on a handheld meter |
| `"wiper"` | Arduino | Park at the state pairs whose difference is one wiper resistance |
| `"k3"` | Arduino | Four holds that say whether K3 closes |
| `"verify"` | Arduino | Seven holds that exercise every part of a freshly built board |
| `"ohms"` | Arduino, one meter | Measure every state in the sweep on ohms, write a CSV and save a plot |
| `"meters"` | both sweep meters | Identify, configure, take ten readings |
| `"sweep"` | Arduino, both meters | Full experiment, written to CSV |

`"sweep"` enters the safe state, self-tests both potentiometers over SPI, sizes the ammeter range
once, then steps through every load state:

```
[  42/ 769] LOW    U1= 41  U2=  0  ~   1004.1 ohm   V=  6.21180  I=   9.8340 mA
```

Press Ctrl-C once and wait ~3 seconds to abort. The cleanup handler returns the board to `OPEN` and
closes the meters. Darkening the cell is yours, the same as lighting it was.

`SELF_TEST = false` skips potentiometer readback, allowing the control flow to run on a bare Arduino
with the board disconnected.

## Configuration

`PVLoad_Main.m` is split into two parts. Part 1 holds the settings intended to be changed. Part 2
describes the pin map and the meter command sets, and changes only with the hardware.

| Setting | Description |
|---|---|
| `RUN` | Mode, per the table above |
| `SERIAL_PORT` | Arduino COM port; enumerate with `serialportlist("available")` |
| `DMM_V_ADDRESS`, `DMM_I_ADDRESS` | VISA resource strings; enumerate with `visadevlist` |
| `DMM_R_ADDRESS` | VISA resource string of the single meter `"ohms"` uses; that mode ignores `DMM_ENABLED` |
| `DMM_V_MODEL`, `DMM_I_MODEL`, `DMM_R_MODEL` | `"196"` or `"34401A"` per meter; selects the command profile and range lists. They need not match |
| `DMM_V_RANGE`, `DMM_I_RANGE`, `DMM_R_RANGE` | Fixed meter ranges, or 0 to size from `VOC_FULL`, `ISC_FULL`, and autorange |
| `DMM_ENABLED` | Whether both sweep meters are attached |
| `ISC_FULL`, `VOC_FULL` | Approximate cell behavior under the light you will run it at; sizes meter ranges and prints estimates. Past a range they are errors |
| `RAMP_STEPS`, `RAMP_DWELL` | States visited by `"ramp"` and how long each state is held |
| `DMM_NPLC`, `DMM_LINE_HZ` | Integration time in power line cycles, and the mains frequency that turns it into seconds. 34401A only |
| `WIPER_CODES` | Codes `"wiper"` compares at |
| `OHMS_SETTLE` | Per-state hold in `"ohms"` before the reading is triggered |
| `SETTLE_TIME` | Per-state hold when no meters are attached |
| `WRITE_CSV`, `OUT_DIR`, `RUN_TAG` | Output. `RUN_TAG` is the only record of the illumination |

The two meters are not the same speed. The 196 has a resolution setting rather than an integration
time; its profile asks for 5.5 digits, which is one line cycle of integration and 24 ms from trigger
to reading-ready. The 34401A integrates for `DMM_NPLC` power line cycles, doubled when
`DMM_ZERO_CORRECT` is set because autozero takes a zero reading between measurements: about 390 ms
at the default 10 NPLC. Both are triggered before either reply is read, so a point costs the slower
of the two rather than their sum, and a 769-state sweep takes about six minutes. `RUN = "plan"`
prints the estimate for a given configuration.

### Checking the load with a handheld meter

`RUN = "ramp"` needs no cell and no bench meters. Bring up 24 V, then the Arduino,
clip a handheld meter across J1 and J3 in ohms, and run it. The board climbs from the `SHORT` relay
contact to the 470 kΩ `OPEN` path in `RAMP_STEPS` stages, holding each for `RAMP_DWELL` seconds so
an autoranging meter has time to settle.

The printed ohms come from the resistance model, not from the board. `R_WIPER` is a worst-case
bound rather than a measurement and `R_AB` is ±20%, so expect the meter to disagree.

`RUN = "wiper"` turns that disagreement into a number. Probe, jack and trace resistance is common
to every reading a handheld takes, so it is removed by subtracting two readings rather than by
trusting either one. Writing `s` for the ladder step, and noting that a `FULL` state at code sum
`n` puts `U1` at `n` and `U2` at zero:

```
SHORT   = K2
LOW(n)  = K1 + Rw1 + n·s + K3
FULL(n) = K1 + Rw1 + n·s + Rw2
```

`LOW(0) − SHORT` is `Rw1` and `FULL(n) − LOW(n)` is `Rw2`, each to within a 0.150 Ω reed contact.
Neither difference contains the leads, the jacks or K1. `Rw2` is a switch rather than a resistor,
so the same value should come back at every code in `WIPER_CODES`; one that tracks the code is
`R_AB` being wrong instead.

### Measuring the load with one meter

`RUN = "ohms"` is `"ramp"` with the copying down done by an instrument. It needs the Arduino and a
single meter on ohms across J1 and J3, with no cell and no second meter, so
`DMM_ENABLED` stays out of it and `DMM_R_ADDRESS` says which meter to open. Bring up 24 V before the
Arduino as usual: the potentiometer resistor networks run from that rail, and a board without it
reads as series resistance rather than as a ladder. Every one of the 769 states is visited once,
held for `OHMS_SETTLE`, and read.

The output is two files under `OUT_DIR`, sharing one timestamp: `pvload_<stamp>_ohms.csv` with a row
per state, and `pvload_<stamp>_ohms.png` plotting measured resistance against the model on log axes,
with the ratio of the two below it. A ratio of 1 is agreement.

Neither meter reaches the bottom of the sweep: the lowest ohms range is 300 Ω on the 196 and 100 Ω
on the 34401A, against a 0.150 Ω `SHORT` contact. `DMM_R_RANGE` therefore defaults to the instrument's own
autorange, and the low end is measured on the coarsest part of the most sensitive range. Points the
meter returns as zero or negative stay in the CSV and are counted on the console rather than plotted.
A reading carries the leads, the jacks and the traces exactly as a handheld does, so a constant few
ohms across every point is the wiring.

`R_WIPER` is 155 Ω per device, measured with `RUN = "verify"` on the assembled board and recorded
in [docs/BRINGUP.md](docs/BRINGUP.md). `CELL_SETTLE` is still a placeholder at zero, and it is the
settle-model term that matters most at high resistance. Measure and replace it.

## Output

`"sweep"` writes one timestamped CSV to `data/sweep_data/`, `pvload_<stamp>.csv`, with a row per
point: `timestamp`, `state_index`, `mode`, `u1_code`, `u2_code`, `r_nominal_ohm`, `voltage_v`,
`current_a`, `resistance_ohm`, `power_w`, `settle_s`.

`resistance_ohm` and `power_w` are derived from measured voltage and current. `r_nominal_ohm` is the
model estimate used to order the sweep and is not a measurement.

Nothing in the file records the illumination, because nothing in the script knows it. Set `RUN_TAG`
before the run; it goes into the file name and is what tells two runs at different light apart.

Rows are appended in blocks of 64 states, so an aborted run retains everything up to the last block
boundary. The timestamp is what stops a second run overwriting the first.

## Measurement notes

Neither instrument here is an electrometer. Both are 6.5 digit DMMs, and both of the arguments
below follow from that.

**Burden voltage.** Connect the voltmeter across the cell terminals, upstream of the ammeter, rather
than across J1 and J3. A voltmeter downstream of the ammeter reads low by the ammeter's burden drop,
and both of these meters read current across a shunt. On the 34401A the shunt is 5 Ω for the 10 mA
and 100 mA ranges, so a 16 mA cell on the 100 mA range costs 80 mV. That is large enough to change
the shape of the curve, not just its offset.

**Input impedance, and which meter to put on volts.** Both meters present megohms rather than
hundreds of teraohms, and against the 470 kΩ `OPEN` path that is a divider rather than a rounding
error: a 10 MΩ input reads Voc about 4.5% low.

The 34401A can be told otherwise. `INP:IMP:AUTO ON` raises its input past 10 GΩ, and the script
sends that command to whichever meter is the voltmeter. It only applies on the 100 mV, 1 V, and
10 V ranges, so a `VOC_FULL` that pushes the meter onto 100 V puts the divider back. The setting is
volatile and `CONFigure` clears it, which is why it is sent after the range on every configuration.

The 196 has no equivalent command. Its 30 V range, where a 9 V Voc lands, is 10 MΩ.

So put the **34401A on volts and the 196 on amps**. On current the two are close enough not to
matter; on voltage they are not. Nothing in the configuration warns about this, because nothing in
the configuration knows the source impedance of the cell.

**Current range.** A ~16 mA cell lands on the 196's 30 mA range and the 34401A's 100 mA range. The
range is chosen once per run from `ISC_FULL` and never autoranged, because a range hunt inside a
settled point spends conversions on the wrong range. An `ISC_FULL` above the meter's top range is
refused at configuration time; one far below its lowest range is a warning, not an error.

**Isc.** The burden drop and the 0.150 Ω relay contact put the `SHORT` state at millivolts rather
than at 0 V. Voltage is measured at every point, so `SHORT` is the lowest-voltage point on the curve
rather than a point defined to be at zero. Isc is obtained by extrapolating to V = 0.

Instrument commands are collected in one profile per model in Part 2, selected per meter by
`DMM_V_MODEL`, `DMM_I_MODEL`, and `DMM_R_MODEL`. Two dialects are supported: Keithley's own
device-dependent command language, which does not port beyond that family, and SCPI.

## Safety

- 24 V must come up before 5 V, and 5 V must come down first. D4, a Schottky from +5 V to +24 V,
  clamps the rails if the sequence is wrong, but it does not make the board usable on 5 V alone:
  V+ then sits about 0.35 V below VL, far below the 10 V the resistor network needs. There is no
  overvoltage protection, and a bench supply connected backwards gives the Arduino's 5 V rail a
  current path through D4.
- **The cell is a supply, so it belongs in the sequence too: illuminate it last, darken it first.**
  PV+ reaches U1's P0B, through R1 normally and directly through K1's contacts once K1 is energized.
  The datasheet limits those pins to `V+ + 0.3 V`, so a lit cell on an unpowered board is roughly
  8.7 V past absolute maximum. With all relays released, R1 holds that to ~19 µA against a ±20 mA
  clamp rating, which is harmless. But if 24 V drops out while 5 V is still up and K1 is closed, R1
  is shorted and the cell's full ~16 mA goes into the clamp — 80% of the absolute maximum, and the
  case that destroys a chip. D4 does not protect this path; it sits between the rails. Blocking the
  light is equivalent to unplugging and easier on the jacks. Since the illumination is set by hand,
  this sequence is entirely yours to get right; nothing in the software can enforce it.
  `docs/HARDWARE.md` §7 has the ratings.
- Never close the short-circuit relay during an open-circuit reading. A 0.150 Ω contact in parallel
  with 470 kΩ collapses the reading to roughly 0 V.
- Do not calculate resistance from the wiper code. The potentiometers carry ±20% tolerance and
  wiper resistance at a 24 V span is not characterized. Work from measured voltage and current.

## Testing without the board

`matlab/test_arduino.m` verifies that every pin the design uses can drive and read, using only the
Arduino, a USB cable, a multimeter, and jumper wires. It includes an SPI loopback test.

## License

MIT. See [LICENSE](LICENSE).
