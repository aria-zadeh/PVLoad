# PVLoad-R1 Hardware Specification

Digitally controlled programmable resistive load for photovoltaic cell I-V characterization.
This document is the complete reference needed to write control software for the board.
It describes what the hardware is and how to drive it. It does not cover PCB layout or fabrication.

---

## 1. What the board does

Two high-voltage SPI digital potentiometers are wired in series to form a two-terminal load.
Three reed relays bypass parts of that load to extend the reachable range past what the
potentiometers alone can produce. An Arduino Uno sets the wiper codes and relay states.

The board is placed in a single series loop with a PV cell. Sweeping the load and recording
voltage and current at each step traces the cell's I-V curve, from which the maximum power
point, fill factor, and matched load resistance are computed.

**The board contains no measurement circuitry.** Voltage and current are read by two external bench
multimeters addressed over VISA. Software sets the load state, reads both meters at each point, and
writes the results to CSV.

### Design targets

| Parameter | Value |
|---|---|
| Device under test | PV cell, up to ~9 V open circuit, ~16 mA short circuit |
| Load range, both pots in circuit | ~400 Ω to 10 kΩ |
| Load range, DigiPot 2 bypassed | ~200 Ω to 5 kΩ |
| Step resolution | ~19.6 Ω per code (5000 Ω / 255) |
| Short circuit path | Relay contact, 0.150 Ω max |
| Open circuit path | 470 kΩ, ~19 µA at 9 V |
| Control interface | SPI from Arduino Uno, driven from the host PC |
| Analog supply | 24 V from bench supply |
| Logic supply | 5 V from the Arduino |

---

## 2. Topology

Five nodes carry the analog current. Every relay bridges exactly two of them.

```
PV+ ── R1 (470k) ── MID ── U1 (P0B→P0W) ── CHAIN ── U2 (P0B→P0W) ── RETURN ── GND
       [K1 bypasses R1]                    [K3 bypasses U2]
       [K2 bridges PV+ directly to RETURN, shorting the whole load]
```

| Node | Connections |
|---|---|
| PV+ | J1 (cell positive), R1 one end, K1 contact A, K2 contact A |
| MID | R1 other end, K1 contact B, U1 P0B |
| CHAIN | U1 P0W, U2 P0B, K3 contact A |
| RETURN | U2 P0W, K2 contact B, K3 contact B, GND |
| GND | J3 (shared return for cell and bench supply), Arduino GND, chip grounds |

Relays are always wired in parallel with an element, never in series. A relay in series could
only open the loop; in parallel it offers current a near-zero-ohm alternate path.

Both DigiPots are used as rheostats (two terminal). Current enters at P0B and leaves at P0W.
P0A is left unconnected on both chips.

---

## 3. Operating modes

| Mode | D6 (K1) | D7 (K2) | D8 (K3) | Load seen by the cell |
|---|---|---|---|---|
| `SHORT` | HIGH | HIGH | LOW | Near zero ohms. Yields Isc. |
| `LOW` | HIGH | LOW | HIGH | DigiPot 2 shorted. ~200 Ω to ~5 kΩ. |
| `FULL` | HIGH | LOW | LOW | Both pots in series, 470 kΩ shorted. ~400 Ω to ~10 kΩ. |
| `OPEN` | LOW | LOW | LOW | 470 kΩ in series. Yields Voc. |

K3 is a don't-care in `SHORT` because K2 already bypasses everything downstream of PV+. Drive it LOW
anyway so the state is fully defined.

**Note the inverted sense of D6.** K1 is normally open and sits across the 470 kΩ, so it must be
energized to hide that resistor during a sweep, and de-energized only for the Voc reading. Side
effect: if the Arduino resets or loses power, all three relays release and the cell settles near
open circuit, which is the safe state.

**Never close K2 during a Voc reading.** A 0.150 Ω contact in parallel with 470 kΩ collapses the
measurement to roughly 0 V.

---

## 4. Arduino pin map

Arduino Uno mounts off-board and connects through a 1x10 header.

| Header pin | Arduino pin | Function |
|---|---|---|
| 1 | 5 V | Logic supply and relay coil supply (~30 mA of coils max) |
| 2 | GND | Common reference |
| 3 | D6 | K1 drive, open circuit relay |
| 4 | D7 | K2 drive, short circuit relay |
| 5 | D8 | K3 drive, DigiPot 2 bypass |
| 6 | D9 | U2 CS# (DigiPot 2) |
| 7 | D10 | U1 CS# (DigiPot 1) |
| 8 | D11 | SPI MOSI, to SDI on both chips |
| 9 | D12 | SPI MISO, from SDO on both chips |
| 10 | D13 | SPI SCK, to both chips |

Relay drive is active high: pin HIGH turns on an NPN low-side switch through a 1 kΩ base
resistor, which energizes the coil.

D2 to D5 and all analog inputs are unused and not brought to the header.

---

## 5. SPI protocol

The device is Microchip MCP41HV51 (8-bit, 5 kΩ, SPI). Two chips, each with its own chip select.
The part does not support daisy chaining, so they are addressed independently.

- Chip select is active low.
- SPI mode 0,0 (also supports 1,1). Clock up to 10 MHz. MSB first.
- Assert CS# low, transfer the bytes, raise CS# high. Never leave both CS# low at once.

### Command format

Each command byte is `[4-bit address][2-bit command][2 data bits]`. For an 8-bit device the two
data bits in the command byte are zero and the data rides entirely in the second byte.

Volatile Wiper 0 register, address `0000`:

| Operation | Command byte | Bytes | Notes |
|---|---|---|---|
| Write wiper | `0x00` | 2 | Second byte is the 8-bit wiper code, 0 to 255 |
| Increment | `0x04` | 1 | |
| Decrement | `0x08` | 1 | |
| Read wiper | `0x0C` | 2 | Second byte clocked out on SDO |

TCON register is address `0100`, so its command byte for a write is `0x40`.

The sweep only needs the write command. Verify increment/decrement byte counts against the
datasheet if you use them.

### Resistance model

```
R_BW = R_ZS + n * (R_AB / 255)
```

where `n` is the 8-bit wiper code and `R_ZS` is the zero-scale (wiper) resistance that remains at
code 0. The denominator is 255 because an 8-bit ladder has 255 physical step resistors and 256
tap points.

**Do not compute resistance from the tap code in analysis.** R_AB tolerance is ±20% and wiper
resistance at a 24 V span is not characterized (treat 200 Ω per device as a worst case bound).
The code is a repeatable setting, not a known resistance. Always work from measured V and I.

---

## 6. Initialization requirements

Every script must do all of the following before taking any reading:

1. **Set all three relay pins to a defined output state.** On reset the Arduino leaves pins as
   high-impedance inputs, which releases all relays and puts the board in `OPEN`. That is safe,
   but it should be entered deliberately.
2. **Write a known wiper code to both chips.** If V+ comes up before VL, the wiper is forced to
   mid-scale rather than taking the register value. Since the bench supply and the Arduino power
   up independently, the reset state cannot be assumed.
3. **Re-write TCON if a non-default terminal configuration is needed.** TCON loads with all
   terminals connected after a reset. The default is correct for this board, so this is usually a
   no-op.

### Settling time

Relays specify 1.0 ms maximum operate and release. The DigiPot settles in about 1 µs. Use a
conservative 10 ms delay after any state change before reading.

---

## 7. Power and safety rules for software

| Rail | Source | Loads |
|---|---|---|
| +5 V | Arduino 5 V pin | VL and SHDN# on both chips, all three relay coils, flyback diode cathodes |
| +24 V | Bench supply | V+ on both chips |
| GND | Common | Arduino GND, cell negative, supply return, DGND/V-/NC/WLAT# on both chips |

Two supplies exist because the chip has two power domains. Logic (VL to DGND) must sit between
2.7 V and 5.5 V. The resistor network terminals must stay between V- and V+, and the cell reaches
about 9 V, above what a 5 V rail could contain.

**Power sequencing is an operator procedure, not enforced by the board.**

```
Up:    24 V  ->  5 V  ->  run the script  ->  illuminate the cell
Down:  darken the cell  ->  5 V  ->  24 V
```

A Schottky diode (D4) across the rails clamps a wrong rail order, but the board is non-functional on
5 V alone, has no overvoltage protection, and has a reverse-polarity current path if the bench
supply is connected backwards.

### The cell is part of the sequence

The cell is a supply too, and it lands on U1's P0B, through R1 always and directly through K1's
contacts whenever K1 is energized. The datasheet limits those pins to
`-0.3 V to V+ + 0.3 V` with respect to V-, so with the board unpowered and V+ at 0 V, an
illuminated cell at 9 V sits about 8.7 V outside absolute maximum and conducts into the internal
clamp. Two cases, three orders of magnitude apart:

| State | What limits the current | Severity |
|---|---|---|
| Board unpowered, cell lit | All relays released, so R1 (470 kΩ) is in circuit. ~19 µA into the clamp. | Outside abs max on paper. Against a ±20 mA clamp rating that is 1000x margin, so harmless. It does pull V+ up through the die. |
| 5 V up, K1 energized, 24 V absent or dropped out | Nothing. K1 shorts R1, so the only limit is the cell's Isc, ~16 mA, into the clamp with V+ at 0 V. | 80% of the ±20 mA absolute maximum clamp current, which is a damage threshold rather than an operating rating. This is the case that destroys a chip. |

Losing 24 V while 5 V is still up and K1 is closed is the failure window, which is why the cell is
darkened before either rail comes down.

**D4 does not protect against this.** It sits between the two rails and does nothing for the PV
input path.

The jacks do not have to be unplugged each cycle. A dark cell sources almost nothing, so blocking
the light is equivalent and spares the connectors. To connect a lit cell to a live board, put the
board in `OPEN` first so R1 is in circuit.

Relevant absolute maximum ratings, MCP41HVX1 datasheet DS20005207:

| Rating | Value |
|---|---|
| Voltage on PxA, PxW, PxB with respect to V- | -0.3 V to V+ + 0.3 V |
| Input clamp current, I_IK | ±20 mA |
| Continuous current into PxA, PxW, PxB (R_AB = 5 kΩ) | ±25 mA |

Software should assume nothing about the power state and always initialize as in section 6.

---

## 8. Measurement procedure

At every sweep point the operation is two-part: software sets the state, the operator reads the
meters.

1. Set the mode (relay pins) and the wiper codes over SPI.
2. Wait 10 ms for settling.
3. Read voltage and current from the external meters, record against the tap code.

Current is measured by breaking the PV+ lead outside the board and putting the ammeter in series
ahead of J1. Voltage is measured across the cell itself, on the cell side of the ammeter, **not**
across J1 and J3: a voltmeter placed at the jacks sits downstream of the ammeter's internal shunt
and reads low by the burden drop. See the note at the end of this section.

Two meters are needed to capture the same operating point. With one meter each point must be
visited twice, which assumes illumination has not changed between readings.

### Sweep order

Sweep from lowest resistance to highest, so the cell is walked monotonically from short circuit to
open circuit rather than jumping between the two endpoints:

1. `SHORT`, one state. Isc endpoint.
2. `LOW`, one state per U1 code, 0 to 255. 256 states.
3. `FULL`, one state per *combined* code, 0 to 510, split across the two chips. 511 states.
4. `OPEN`, one state. Voc endpoint.

769 states, each a distinct circuit. In `FULL` only the sum of the two codes affects resistance, so
`(10, 20)` and `(15, 15)` are the same circuit and only one of them is visited.

Keeping `LOW` as well as `FULL` is what makes the sweep finer than one wiper step. `LOW` starts at
one wiper resistance and `FULL` at two, both climbing in the same ~19.6 Ω steps. The offset between
them is not a whole number of steps, so `FULL`'s points land between `LOW`'s rather than on top of
them, and the pair reaches resistances neither reaches alone.

### Analysis

Maximum power point is the maximum of V x I over all sampled points. Matched load resistance is
V/I at that point. It cannot be estimated as Voc/Isc, because both endpoints deliver zero power.
The maximum sits at the knee, typically 70% to 80% of Voc for a silicon cell.

### Log format

One row per sampled point:

| Column | Content |
|---|---|
| `u1_code` | Tap code written to DigiPot 1 |
| `u2_code` | Tap code written to DigiPot 2 |
| `mode` | `SHORT`, `LOW`, `FULL`, or `OPEN` |
| `voltage_v` | Measured, external meter |
| `current_a` | Measured, external meter |
| `timestamp` | ISO 8601 |

Illumination conditions must be recorded once per sweep. An I-V curve is only meaningful at a
stated illumination. The control software now sets illumination itself, with a Thorlabs EDFA100P
fiber amplifier, and repeats the whole sweep at each of several optical powers. The amplifier is
not part of this board and is documented in its own manual, Thorlabs TTN118382-D02 Rev C. What
matters here is that each logged row belongs to a stated pump current, so the log gains
`level_current_ma` and `level_power_mw` columns ahead of the ones above.

Two notes on putting bench meters in this circuit. Neither is a board problem, and neither needs a
board change.

**Put the voltmeter on the cell side of the ammeter.** This is the one that matters. Any ammeter
measures current by dropping it across an internal shunt; on an Agilent 34401A that shunt is 5 ohm
on the 10 mA and 100 mA ranges and 0.1 ohm on the 1 A and 3 A ranges. With the ammeter ahead of J1,
a voltmeter across J1 and J3 sits *downstream* of that shunt and therefore reads short of the
cell's terminal voltage by the burden drop, about 80 mV at 16 mA. That is a small error at the Voc
end and the entire signal at the Isc end. Clipping the voltmeter directly to the cell leads,
upstream of the ammeter, removes it. It costs nothing.

**The shunt shifts where `SHORT` lands, and that is all.** With 5 ohm inline the cell sits at about
80 mV at the `SHORT` state rather than at the 0.150 ohm contact alone. That does not corrupt the
measurement, because voltage is measured at every point rather than assumed: `SHORT` is simply the
lowest-voltage point on the curve, not a point defined to be at zero. Isc is the V -> 0 intercept
extrapolated from the lowest few points, which is how it should be extracted in any case.

Prefer the 100 mA range over the 1 A range for a ~16 mA cell despite the larger shunt. Meter error
carries a "percent of range" floor that is fixed in absolute size, so reading 16 mA on a 1 A range
scales that floor to 1 A and swamps the reading; the 100 mA range keeps it an order of magnitude
smaller. The operating-point offset the 5 ohm causes is systematic and correctable, and the meter
error is not.

---

## 9. Bill of materials

| Ref | Qty | Part | Description |
|---|---|---|---|
| U1, U2 | 2 | Microchip MCP41HV51-502E/ST | 5 kΩ 8-bit SPI digital potentiometer, TSSOP-14 |
| K1, K2, K3 | 3 | Littelfuse HE3621A0540 | Reed relay, SPST-NO, 5 V / 500 Ω coil, shielded, 4-pin SIL |
| Q1, Q2, Q3 | 3 | onsemi 2N3904BU | NPN transistor, TO-92, relay coil driver |
| D1, D2, D3 | 3 | onsemi 1N4148 | Switching diode, DO-35, coil flyback clamp |
| D4 | 1 | Diodes Inc. 1N5819HW-7-F | Schottky, SOD-123, rail sequencing protection. Anode +5 V, cathode +24 V. |
| R1 | 1 | Yageo RC0805FR-07470KL | 470 kΩ, 1%, 0805. Open circuit path. |
| R2, R3, R4 | 3 | Yageo RC0805FR-071KL | 1 kΩ, 1%, 0805. Transistor base current limit. |
| C1 to C4 | 4 | Samsung CL21B104KBCNNNC | 0.1 µF, 50 V, X7R, 0805. One per chip power pin. |
| C5 | 1 | Samsung CL32B106KBJNNNE | 10 µF, 50 V, X7R, 1210. Bulk on +24 V, non-polarized. |
| C6 | 1 | Samsung CL32B106KBJNNNE | 10 µF, 50 V, X7R, 1210. Bulk on +5 V. |
| C7, C8 | 0 | Samsung CL32B106KBJNNNE | Not fitted. Optional footprints paralleling C5 and C6. |
| J1, J2 | 2 | Cal Test CT3151-2 (red) | 4 mm banana jack. J1 = PV+, J2 = +24 V. |
| J3 | 1 | Cal Test CT3151-0 (black) | 4 mm banana jack. GND, shared return. |
| MCU1 | 1 | Sullins PRPC010SAAN-RC | 1x10 vertical header, 2.54 mm, off-board Arduino Uno |

Selection notes that affect behavior:

- **MCP41HV51-502E/ST**: 502 = 5 kΩ. Two in series give the 10 kΩ ceiling. Max wiper current
  25 mA against 16 mA here. R_AB tolerance ±20%, so the pair is nominally 10 kΩ but legitimately
  8 kΩ to 12 kΩ.
- **HE3621A0540**: the -40 suffix means external shield and no internal coil diode, which is why
  D1 to D3 are fitted externally. The part is obsolete and will not be restocked.
- **Reed contacts over armature**: 16 mA is dry-circuit territory where a silver-alloy power
  contact can develop a surface film and read as an intermittent open. The reed capsule is
  hermetically sealed. Contact resistance 0.150 Ω max.
- **10 mA coils**: three relays draw about 30 mA total, low enough to run off the Arduino 5 V rail.
- **C5 is Class II ceramic** and loses capacitance under DC bias. A 50 V X7R part at 24 V retains
  roughly half its nominal value. Do not quote 10 µF as the effective value.

---

## 10. Chip pin reference

Both chips are wired identically except for chip select.

| Pin | Connects to | Reason |
|---|---|---|
| NC (8) | GND | Datasheet asks for this pin tied to DGND or VL to reduce noise coupling |
| DGND | GND | Digital ground reference |
| V- | GND | Negative rail of the resistor network |
| P0B | U1: MID. U2: CHAIN | Current enters the ladder here |
| P0W | U1: CHAIN. U2: RETURN | Wiper, current leaves here |
| P0A | Not connected | Only needed in divider mode. Connecting it would create a parallel path. |
| V+ | +24 V | Positive rail of the resistor network |
| SHDN# | +5 V | Held high to keep the part active. Pulling it low ties the wiper to P0B, which silently flattens the sweep while every software check still passes. |
| WLAT# | GND | Held low so wiper writes take effect immediately |
| SDO | D12 | Serial data out |
| SDI | D11 | Serial data in |
| CS# | U1: D10. U2: D9 | Active low chip select |
| SCK | D13 | Serial clock |
| VL | +5 V | Logic supply |

---

## 11. Known limitations affecting software

1. Wiper resistance at a 24 V span is not characterized in the datasheet. The 200 Ω per device
   figure is a worst case bound, not a measured value. Measure it on the assembled board and
   replace the estimate.
2. No on-board sensing means the measured columns of any log come from an operator or an
   instrument that the control script does not own. Design the logger to accept them after the
   fact rather than assuming it can read them.
3. If a host-side SPI API is used (for example a MATLAB Arduino support package), the exact
   read/write call signature is version dependent. Verify the byte order and transaction framing
   on a scope or logic analyzer before trusting it against live hardware.
