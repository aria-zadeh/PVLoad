# Troubleshooting

How to find a fault on an assembled board with a handheld meter and nothing else.
What has actually been found this way is in [BRINGUP.md](BRINGUP.md).

The last two sections cover the host instead of the board: getting MATLAB to see
the meter at all, and getting the first read off it.

---

## Measure differences, not readings

A handheld carries its probes, its clips and both banana jacks in every reading.
On one board that came to 0.004 ohm. On another it was 30 to 80 ohm and moved
between runs. Nothing below a few hundred ohms can be read off the display and
trusted.

Every diagnostic below is a subtraction between two board states. The probe path
is common to both and cancels. Design any new check the same way.

## The diagnostic modes

The first four open the board and nothing else. No cell, no bench meters.

| `RUN` | States | Answers |
|---|---|---|
| `"verify"` | 7 | Is this board sound? |
| `"k3"` | 4 | Does K3 close? |
| `"wiper"` | varies | What is the wiper resistance? |
| `"ramp"` | `RAMP_STEPS` | Does resistance track code across the whole range? |
| `"ohms"` | 769 | The same question, measured rather than eyeballed |

`"ohms"` is `"ramp"` without a person copying numbers off a handheld. It puts one
meter on ohms across J1 and J3, walks every state in the sweep, and writes
the readings to CSV with a plot. Still no cell. It takes one
meter rather than the pair, so it ignores `DMM_ENABLED` and takes its address
from `DMM_R_ADDRESS`. Around twelve minutes at the default `OHMS_SETTLE`.

The meter carries the leads, the jacks and the traces exactly as a handheld does,
so a constant offset of a few ohms across every point is the wiring and not the
board. Read the differences, as everywhere else here.

`"verify"` is the one to run first on anything freshly built. It touches both
chips over SPI, all three relays, both ladders and R1. Its pass conditions are
differences and orders of magnitude, so the probe path does not enter them.

`test_arduino.m` has a fifth, `TEST = "one_pin"`, which drives one pin high and
low on a slow cycle so it can be followed downstream with a voltmeter. Point it
at D6, D7 or D8 in turn. The three relay drives are identical circuits, so a
channel that works is the reference for one that does not.

## What each `"verify"` hold proves

| Hold | State | Pass |
|---|---|---|
| 1 | `OPEN` | about 470 kohm |
| 2 | `SHORT` | lowest of the seven, by far |
| 3 | `FULL` 0, 0 | |
| 4 | `FULL` 255, 0 | hold 4 minus hold 3 is about 5 kohm, the U1 ladder |
| 5 | `FULL` 255, 255 | hold 5 minus hold 4 is about 5 kohm, the U2 ladder |
| 6 | `LOW` 0, 0 | below hold 3 |
| 7 | `LOW` 0, 255 | equal to hold 6, to the ohm |

Hold 7 is the one that catches a dead K3, and no other test on the board can.
`LOW` shorts U2 out, so U2's code must not reach the terminals. A 5 kohm swing
between holds 6 and 7 means the relay never operated.

Wiper resistance falls out of the same seven numbers: hold 6 minus hold 2 is
U1's wiper, hold 3 minus hold 6 is U2's. Both should agree and both should sit
between 75 and 200 ohm.

---

## Traps

**A missing 24 V rail looks like series resistance.** The resistor string is
passive and measures correctly with V+ at zero, but the wiper switches have no
analog supply and read several hundred ohms to a kilohm. The symptom is a large
constant offset with correct ladder slopes. Check the supply's output button
before chasing it into the board.

**A relay that never closes looks like a component with no resistance.** `LOW`
and `FULL` differ only by whether K3 shorts U2 out. If K3 never closes they
contain the same parts and read alike, which presents as a wiper resistance of
zero rather than as a relay fault. Hold 7 of `"verify"` is the only thing that
separates the two.

**`SHDN#` low flattens the sweep silently.** Pulling it low ties the wiper to
P0B. Every software check still passes and every reading is plausible. The tell
is that resistance stops tracking code: check the slope, which should be about
19.6 ohm per step.

**An even `RAMP_STEPS` stride can lock onto one mode.** `LOW` and `FULL` states
alternate through the sorted plan, so a stride that is a whole even number visits
the same mode every time. `RAMP_STEPS = 25` gives a stride of exactly 32 and
shows no `LOW` states at all. Pick a count whose stride is not a whole number.

---

## Localising a relay that will not close

The drive chain for K3, and the same for K1 on D6 and K2 on D7:

```
D8  ->  header pin 5  ->  base resistor  ->  Q3 base
                                            Q3 emitter  ->  GND
                                            Q3 collector -> K3 coil -> +5 V
                              D3 across the coil, band toward +5 V
```

Run `TEST = "one_pin"` with `ONE_PIN = "D8"`, then follow it with a voltmeter
against ground. Probe the same points on a working channel first.

| Point | Pin high | Pin low | If it does not follow |
|---|---|---|---|
| the pin | 5 V | 0 V | Arduino, or the wire to header pin 5 |
| Q base, middle leg | 0.7 V | 0 V | base resistor, or the header connection |
| Q collector, right leg | 0.2 V | 5 V | the transistor |

The collector runs backwards: it goes low when the pin goes high, because the
transistor pulls the coil down to energise it.

Two things are ruled out by those numbers alone. A collector that reaches 0.2 V
means D3 is the right way round, because a reversed flyback conducts as soon as
the transistor turns on and clamps the collector near 4.3 V. A clean 5 V with the
pin low means the coil is continuous, because an open coil leaves the collector
floating and a voltmeter reads near zero.

If the drive follows correctly and the relay still does not close, the coil is
getting its full 4.96 V and the fault is past it. Probe the relay's own legs:
with the board unpowered, one pair reads about 500 ohm and is the coil, the other
pair is COM and NO. Energise the coil and measure COM to NO.

- Under 1 ohm: the relay works and its COM and NO joints are not reaching the
  board. Reflow them.
- About 120 ohm or open: the contact is not closing. The relay is dead. The part
  is obsolete, so a substitute is needed.

## Q pinout

2N3904 in TO-92. Flat face toward you, legs pointing down: left is emitter,
middle is base, right is collector. Confirm without trusting that: the emitter
has continuity to ground, the base is the leg with the 1 kohm resistor, the
collector runs to the relay.

---

## MATLAB cannot see a meter that Connection Expert can

The symptom is a clean split. Keysight Connection Expert lists the instrument
and reads it. MATLAB reports no VISA resources at all:

```
instrhwinfo('visa')            {'ni'}
visadevlist                    Unable to find any VISA resources ...
visadev('GPIB0::1::INSTR')     Resource string is invalid or resource was not found
```

The cause is not VISA configuration. The conflict manager, the preferred
implementation, `ConflictTbl.xml`, the registry and repeated reboots were all
ruled out, and every Keysight DLL loads and is the right architecture.

The cause is the C++ runtime. `MATLAB.exe` lives in `bin\win64`, and Windows
searches a program's own directory first, so the `MSVCP140.dll` that MATLAB
ships there is the one every MATLAB process loads. Keysight IO Libraries is
built against a newer runtime than MATLAB carries. `ktvisa32.dll` then fails its
initialisation with Win32 error 1114, `mwagilentvisa.dll` fails with it, and
MATLAB concludes Keysight VISA is not installed. Connection Expert is a separate
program and loads the system runtime, which is why it works.

Confirm it in three steps.

Compare the two copies. The one under MATLAB will be older:

```
C:\Program Files\MATLAB\R2022a\bin\win64\MSVCP140.dll
C:\Windows\System32\MSVCP140.dll
```

Ask MATLAB to load the adaptor directly. The message names the failure mode,
which the toolbox otherwise hides behind "not installed properly":

```matlab
java.lang.System.load(fullfile(matlabroot, 'toolbox', 'instrument', ...
    'instrumentadaptors', 'win64', 'mwagilentvisa.dll'))
```

A dependency that is merely absent gives "module could not be found". This gives
"A dynamic link library (DLL) initialization routine failed", which means the
library was found, mapped, and refused to start.

Reproduce it outside MATLAB. In a plain PowerShell window, `LoadLibrary` on
`ktvisa32.dll` succeeds. Do it again after loading MATLAB's `MSVCP140.dll` first
and it fails with 1114.

The fix is to replace the eight VC++ 14.x files in `bin\win64` with the System32
copies: `msvcp140`, `msvcp140_1`, `msvcp140_2`, `msvcp140_codecvt_ids`,
`vcruntime140`, `vcruntime140_1`, `concrt140` and `vccorlib140`. Back the
originals up first. This changes no MATLAB code and no licensing; the files are
Microsoft's, and Microsoft states that a program built against an older 14.x
runtime runs against a newer one.

It worked when `instrhwinfo('visa')` lists `keysight` and `visadevlist` shows the
instrument. A MATLAB repair or reinstall puts the old files back and returns the
fault.

## The first read after opening a meter times out

Both meters talk continuously, so `visadev` can open partway through a reading.
The first `readline` then waits for a line ending that has already gone past, and
times out however long the timeout is. Every read after that is fine, which makes
it look intermittent when it is not.

`flush` the session immediately after opening it. `openMeter` does this. The
write terminator is not involved: `CR/LF` and `LF` behave identically, with and
without the flush.

## The 196 misbehaves for the first few exchanges of every session

One fault with many faces, and the faces were chased separately before the
cause was found: the first command of a session vanishing, `U0` answered with a
reading instead of the status word, `TRIGGER ERROR` on the display, and an
IDDCO latching into the error word with every command sent being valid, often
surfacing an exchange or two after whatever caused it.

The cause is MATLAB. `visadev` sends `*IDN?` to whatever it opens and offers no
way to turn that off (confirmed by MathWorks support, MATLAB Answers 2118301;
the suppression flag added in R2025a is on `visadevlist`, not `visadev`). The
196 predates SCPI and executes nothing without a trailing `X`, so the `*IDN?`
sits half-parsed in its input. The next real command is concatenated onto that
fragment, and the `X` it ends with executes the combined garbage: the command
is consumed, IDDCO latches for a string nobody knowingly sent, and both appear
late because nothing runs until that `X` arrives. Two writes in quick
succession into a fresh session make it worse, mangling into one string.

Separately, a power-cycled 196 wakes in `T0`, continuous on talk: being
addressed to talk is itself a trigger, so every read manufactures a fresh
reading and no query can be answered with anything else. No flush wins that
race.

`primeDdc` handles all of it at open: a bare `X` to execute and discard the
stranded fragment, one `T5` per attempt to leave trigger-on-talk, and the error
word read until clean, retrying the `T5` if the drain keeps collecting
readings. Because latched phantom bits can still surface later, setup
verification does not trust `U1` at all: `ddcVerifySetup` reads the `U0`
machine word back and compares the digits against what was sent, positions
mapped on this bench by toggling one setting at a time. The error word says
what the meter has been through; the machine word says what it is in.

The fragment also paints the front panel. `*IDN?` contains a `D`, the 196's
display-message command, so executing it leaves the tail of the query on the
display, where it reads `n7`, and a painted message stays until a bare `D`
restores the display. `primeDdc` sends that too. The `TRIG ERROR` the panel
flashes at the moment the fragment executes is the same event and clears when
the first real reading lands.

The 34401A is immune: `*IDN?` is exactly what it expects.
