# Meters

Two instruments on one GPIB bus, and they speak different languages. This is
what the software knows about each and why. Bring-up history is in
[BRINGUP.md](BRINGUP.md); faults and their symptoms are in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## The pair

A Keithley 196 and an Agilent 34401A. `DMM_V_MODEL`, `DMM_I_MODEL` and
`DMM_R_MODEL` pick the profile per meter and need not match; the bench runs the
34401A on volts and the 196 on amps.

A meter is an open port bundled with its profile, built by `meterSpec` and
opened by `openMeter`. Every bus function takes that bundle, so nothing below
the configuration block knows which instrument it is holding. Each profile
carries a `Dialect`, and the functions that touch the bus branch on it:
`openMeter`, `identifyMeter`, `configureMeter`, `meterTrigger`, `meterFetch`,
`meterDecode`, and the setup check.

There is no Keithley 617 in this project. An earlier version supported one and
none of it survives.

## Which meter goes where

**The 34401A belongs on volts and the 196 on amps.** `INP:IMP:AUTO ON` raises
the 34401A's input past 10 GΩ, but only on the 100 mV, 1 V and 10 V ranges, and
`scpiConfigure` sends it on the voltmeter alone. The 196 has no equivalent, and
its 30 V range is 10 MΩ. On current the two are close enough that the choice
does not matter.

`DMM_V_MODEL` and `DMM_I_MODEL` describe what is physically cabled. Do not
change them to suit the software.

**Neither meter is an electrometer, and that is the whole measurement story.**
Both read current across a shunt, so an ammeter in series adds burden voltage:
about 9.4 Ω total was measured at the `SHORT` state, leads and jacks included.
Both present megohms on volts, which is why the `OPEN` state is a divider
against R1 rather than an open circuit.

## Keithley 196

On the bus at `GPIB0::1::INSTR`, `U0` answering with the prefix `196`. Front
panel address default is 7.

It **predates SCPI**: a command is a letter and a number, several travel in one
string, and nothing happens until an `X` arrives. No `*IDN?` (use `U0`), no
`*RST`, no `SYST:ERR?` (use `U1`).

The profile is read off manual 196-901-01 Rev D, not inferred:

| | |
|---|---|
| Functions, section 3.9.2 | `F0` volts, `F2` ohms, `F3` DC amps |
| Ranges, table 3-9 | volts 300 mV to 300 V, amps **300 µA** to 3 A, ohms 300 Ω to 300 MΩ, `R1` upward by decades |
| Setup string, table 3-8 | `Z0B0G0M0K2S3T5` |
| Conversion, table 3-16 | 106 ms at `S3`, 6.5 digits |
| Reading tags, figure 3-6 | `DCV` `ACV` `OHM` `OCO` **`DCI`** `ACI` `dBV` `dBI` |

Inference had two of those wrong before the manual was read, and both are worth
remembering: it put the lowest amps range at 3 mA, and the conversion at 350 ms.

`S3` rather than `S2` because the readings are overlapped and the 34401A beside
it takes 393 ms, so the 196 finishes inside that window either way. The extra
digit is free.

The setup letters in order: relative off, so a REL left on the front panel
cannot offset every reading; readings from the A/D rather than the buffer; send
the prefix that flags an overflow; SRQ mask cleared; EOI on and bus hold-off
off, which is what lets the second meter be triggered while this one is
converting; 6.5 digit resolution; convert once per `X`.

### The status words

`U0` returns the machine status word: `196` and then one digit per programmed
setting. The digit positions, counted after the prefix, were mapped on this
bench by toggling one setting at a time and diffing the reply. They live in the
profile as `StatusMap`:

| setting | digit |
|---|---|
| `F` function | 3 |
| `K` EOI and hold-off | 6 |
| `R` range | 18 |
| `S` resolution | 19 |
| `T` trigger | 20 |
| `Z` relative | 27 |

`U1` returns the error condition word, and reading it is what clears the bits.
Bit 1 is TRIG ERROR and bit 11 is IDDC, measured with `F9X` and `Q9X`.

**Setup is verified against the machine word, not the error word.** A phantom
error bit can surface an exchange or two after whatever caused it, so
`ddcVerifySetup` reads `U0` back and compares digits against what was sent. The
error word says what the meter has been through; the machine word says what it
is in.

## Agilent 34401A

SCPI rather than the Keithley letter dialect, so the profile carries
`Dialect = "scpi"`. Read off manual 34401-90004. Ranges are 100 mV to 1000 V,
10 mA to 3 A, 100 Ω to 100 MΩ. Front panel address default is 22.

- `openMeter` uses an LF read terminator, not CR LF, and sends `SYST:REM` on an
  `ASRL` resource only.
- `identifyMeter` uses `*IDN?`, whose reply carries the model in the middle
  rather than at the front.
- `assertMeterHappy` drains `SYST:ERR?` until it reads `+0`, rather than popping
  one entry, so a setup with several rejected commands reports all of them in
  one run.
- `meterTrigger` and `meterFetch` are `INIT` then `FETC?`, which is what makes
  the two conversions overlap.
- `scpiDecode` takes a bare number; overflow is 9.9e37 and must not reach the
  CSV.

**`CONF` resets integration time, autozero and input impedance to that
function's defaults**, which the manual is explicit about. Everything in
`scpiConfigure` is therefore sent after the `CONF`, never concatenated before
it, and a mid-sweep range change uses `RANGe` alone so the setup survives.

`DMM_NPLC` and `DMM_LINE_HZ` are 34401A only. 10 NPLC at 60 Hz is 167 ms, and
`DMM_ZERO_CORRECT` maps to `ZERO:AUTO`, which costs a second conversion, so a
reading is about 393 ms against the 196's 106 ms.

`TRIG:DEL AUTO` is not a command. `TRIGger:DELay` takes seconds, `MINimum` or
`MAXimum`; the automatic delay is the separate node `TRIGger:DELay:AUTO
{OFF|ON}`. The short form is `-224, Illegal parameter value`, manual page 80.

## Ranges

Ranges are measured rather than assumed. `probeRanges` reads the `OPEN` and
`SHORT` states on autorange before the run: those two states bound the whole
sweep, since every other state is one of them with resistance added. `ISC_FULL`
and `VOC_FULL` default to zero, meaning measure it, and a number pins the range
instead.

During the sweep both meters follow the reading, `followRange`. It widens at
90% of range or on an overflow and narrows under 8%, jumping straight to the
range that fits; the gap between those thresholds is the hysteresis that stops a
reading parked on a boundary from re-ranging at every state. An overflow is
recovered by widening and reading again rather than logged as a fault.

The voltmeter follows for resolution: a 34401A carries 0.0035% of reading plus
0.0005% of range, so at 10 mV on the 10 V range the floor term is 50 µV against
0.35 µV of gain error. The ammeter follows for survival: a pinned range cannot
track illumination that drifts, and five overflows in a row abort the run.

`assertConfig` warns when `ISC_FULL` sits far below the ammeter's lowest range
and refuses when it sits above the highest.
