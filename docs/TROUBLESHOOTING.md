# Troubleshooting

How to find a fault on an assembled board with a handheld meter and nothing else.
What has actually been found this way is in [BRINGUP.md](BRINGUP.md).

---

## Measure differences, not readings

A handheld carries its probes, its clips and both banana jacks in every reading.
On one board that came to 0.004 ohm. On another it was 30 to 80 ohm and moved
between runs. Nothing below a few hundred ohms can be read off the display and
trusted.

Every diagnostic below is a subtraction between two board states. The probe path
is common to both and cancels. Design any new check the same way.

## The diagnostic modes

The first four open the board and nothing else. No laser, no bench meters.

| `RUN` | States | Answers |
|---|---|---|
| `"verify"` | 7 | Is this board sound? |
| `"k3"` | 4 | Does K3 close? |
| `"wiper"` | varies | What is the wiper resistance? |
| `"ramp"` | `RAMP_STEPS` | Does resistance track code across the whole range? |
| `"ohms"` | 769 | The same question, measured rather than eyeballed |

`"ohms"` is `"ramp"` without a person copying numbers off a handheld. It puts one
electrometer on ohms across J1 and J3, walks every state in the sweep, and writes
the readings to CSV with a plot. Still no cell and no amplifier. It takes one
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
