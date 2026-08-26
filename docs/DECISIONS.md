# Design Decisions

Rationale for the control software. Hardware rationale is in
[HARDWARE.md](HARDWARE.md).

## Sweep the combined code, not each pot

The two potentiometers are in series, so only the sum of the two wiper codes
affects resistance. Codes (10,20) and (15,15) produce the same circuit.

An earlier version wrote the same code to both chips. That moved the total two
steps at a time and halved the available resolution. The sweep now walks the
combined code 0 to 510 and splits it across the chips, giving one wiper step
(~19.6 ohm) of resolution across the range.

## Keep both ladders

`LOW` (K3 closed, one pot) starts near 200 ohm. `FULL` (both pots) starts near
400 ohm. Both climb in ~19.6 ohm steps.

200 / 19.6 = 10.2, so the ladders do not align. The `FULL` rungs fall between the
`LOW` rungs, and 245 `FULL` points land inside the `LOW` range at resistances
neither ladder reaches alone.

An earlier version deleted that overlap as redundant. The offset depends on wiper
resistance, which the datasheet does not characterise at a 24 V span, so the
duplicates were never confirmed to be duplicates. Resistance is read from the
meters, so extra points cost only run time.

## Order by estimate, select by structure

The nominal resistance model sorts the sweep low to high and labels the progress
line. It does not determine membership. Uniqueness is guaranteed structurally:
one state per `LOW` code, one per `FULL` code-sum, one `SHORT`, one `OPEN`. That
holds regardless of the real resistances.

To shorten a sweep, raise `CODE_STEP`. It skips codes deliberately rather than
inferring which are redundant.

## Read the wiper back

The original script was write-only and could not distinguish a working board from
an unplugged one. Every wiper write is now read back over SPI and compared, and
both chips are self-tested across a spread of codes before the sweep starts. This
also detects the mid-scale power-on-reset condition that occurs when 24 V comes
up before 5 V.

Only the second returned byte is decoded. The command-error and high data bits in
the first byte are not, since comparing the code detects every failure those bits
would report.

## Illumination is the outer loop

The sweep runs at several optical powers, so one loop must contain the other.
Illumination is outside.

Inner-looping it would change pump current 769 times per sweep instead of once
per level. Each change requires a bounded ramp and a settling period for the cell
to reach thermal equilibrium, extending the run from minutes to hours. It would
also mean no complete I-V curve exists until the final point, so an aborted run
would yield nothing.

## Current, not power

The EDFA100P has no command that sets optical output power. Its keyword list is
`id`, `target`, `temp`, `current`, `enable`, `specs`, `step`, `save` and
`statword`; gain is adjusted by pump current only.

A measured current-to-power table is therefore the only mapping between the
quantity of interest and the quantity the device accepts. `LEVEL_MODE "power"`
requires the table; `"current"` does not. The table must be strictly monotonic
before inversion, since a non-monotonic column makes the inverse ambiguous and
indicates a bad measurement.

Requested powers outside the measured range are rejected rather than
extrapolated. Interpolation is linear rather than spline: the current-power curve
has a threshold knee, and a spline through it can overshoot non-monotonically and
invalidate the inverse.

## Read the amplifier back

Same policy as the wiper registers. Every `current=n` is followed by `current?`
and compared, since a write-only link cannot distinguish a working amplifier from
an unplugged one.

The parser is the fragile part, because the interface is a terminal for a human
rather than an instrument protocol. It emits a bare `<` prompt with no terminator,
so `readline` would block for the full timeout on every prompt; the reader polls
the byte count against a deadline instead. Replies arrive mixed with prompts and
possibly an echo of the command, both of which are stripped.

`edfaDecode`, `edfaParseNumber` and `edfaDecodeStatword` take strings rather than
a port so they can be tested against captured replies rather than against live
hardware.

`statword?` is documented as "a string representation of an 8-bit number" whose
rightmost bit is 1 when the device is on. That is ambiguous between `"10000001"`
and `"129"`. Both are decoded and they agree.

## Ctrl-C requires onCleanup, which requires a function

The script previously wrapped the sweep in `try`/`catch` and called
`enterSafeState` from the catch block. That does not protect against Ctrl-C: in
MATLAB an interrupt is not an exception and does not run catch blocks. Only
`onCleanup` fires, and only when the workspace holding it is destroyed, which
does not happen to a script's base workspace.

This was tolerable when the worst outcome was a closed relay. It is not tolerable
when an abort can leave a Class 3B pump at current. `runExperiment` exists to give
the cleanup guard a function workspace.

## Isc from an intercept, not from the SHORT point

An ammeter measures current across an internal shunt, 5 ohm on a 34401A's 10 mA
and 100 mA ranges. That shunt is in series with the load, so at `SHORT` the cell
sits near 80 mV rather than at the 0.150 ohm relay contact alone.

This does not invalidate the Isc endpoint, because voltage is measured at every
point rather than assumed. `SHORT` is the lowest-voltage point on the curve and
carries its own measured voltage. Isc is obtained by extrapolating to V = 0 from
the lowest points, which is the correct extraction method regardless of series
resistance.

The 1 A range would reduce the shunt to 0.1 ohm and was rejected. Meter error
includes a percent-of-range floor fixed in absolute terms, so reading 16 mA on a
1 A range costs roughly an order of magnitude more than the 100 mA range. The
operating-point offset from the larger shunt is small and correctable; the meter
error is neither.

An external series shunt was considered and dropped. It was only relevant to the
single-meter design, where the voltage and current passes saw different circuits.
Two meters removed the need.

## The script writes the data

The original rule was that the script writes no files. That applied while a human
read the meters: the script changed the load and the readings were recorded
elsewhere.

The script now reads the meters, so it holds data that exists nowhere else.
`"sweep"` writes two CSVs.

Two files rather than one, because the data has two shapes. Per-point rows are
measurements. Per-level rows hold values constant across 769 points: pump current
readback, temperature, meter range, fault count. Flattening those into every row
would duplicate each 769 times. Both share a timestamp prefix so a run stays
together and the directory sorts chronologically.

Rows are appended per level rather than at the end. A sweep can run for half an
hour, and an interlock trip in the last level should not discard the earlier ones.

`resistance_ohm` and `power_w` are computed from measured voltage and current,
never from the wiper code.

## No prompts, and independent run modes

The sweep free-runs. A keypress-per-point mode was added on the assumption of
manual reading and removed when that assumption changed. Two meters keep it that
way; one meter would require sweeping twice with a rewire between passes.

`RUN` exists because the bench was assembled in stages: Arduino, board, amplifier,
meters. A script that could only run all of it at once would have been untestable
for months. Each mode opens only what it needs, and `plan` opens nothing, so a
configuration change can be checked with no hardware attached.

## Arduino bench test

`test_arduino.m` validates every pin the design uses with only an Arduino, a
meter and jumper wires. The jumper tests matter more than the voltage tests: a pin
can read 5 V and still fail as an input or fail to clock data. `spi_loopback` is
the only test that exercises the SPI peripheral, which is the hardest subsystem to
debug once two TSSOP packages are soldered down.

## Open questions

- Wiper resistance at a 24 V span is not characterised. 200 ohm is a worst-case
  bound. Measure it on the assembled board and update `R_WIPER`. It affects sweep
  ordering only.
- The 200 ohm gap between `SHORT` (0.150 ohm) and the lowest pot setting is a
  hardware floor. No relay or code combination reaches inside it.
- `EDFA_LEVEL_SETTLE` is an estimate at 10 s. It represents the cell reaching
  thermal equilibrium at a new illumination, not the amplifier's response.
  Measure and replace.
- `CELL_SETTLE` is zero and unmeasured. The computed hold currently accounts for
  cable and meter capacitance only, about 1 ms at the 470 kohm `OPEN` point,
  small next to the 10 ms relay floor. Cell junction capacitance is the term
  likely to dominate.
- The `statword?` bit convention is decoded both ways because the manual is
  ambiguous. Confirm the actual convention at bring-up and remove the branch.
- The `OPEN` point degrades as a Voc measurement at low illumination. The 470 kohm
  path draws a fixed 19 uA at 9 V: 0.12% of Isc at full power, ~5% around 2.4 mW.
  `reportPlan` warns above 5%.
- The SCPI dialect is written for a 34401A and has not been run against one.
  `RUN = "meters"` tests it cheaply. `SYST:ERR?` is checked after configuration so
  a wrong keyword fails at setup rather than producing readings from a meter in
  the wrong mode.

## Procedure requirements

Not open questions, but constraints on how the bench is wired:

- The voltmeter connects on the cell side of the ammeter. Downstream of the
  ammeter's internal shunt it reads low by the burden drop, ~80 mV at 16 mA
  through 5 ohm, which is the entire signal at the Isc end.
- 24 V comes up before 5 V, and 5 V comes down first.
