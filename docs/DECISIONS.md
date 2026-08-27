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

`LOW` (K3 closed, one pot) starts at one wiper resistance, measured at 155 ohm.
`FULL` (both pots) starts at two. Both climb in ~19.6 ohm steps.

155 / 19.6 = 7.9, so the ladders do not align. The `FULL` rungs fall between the
`LOW` rungs, and 245 `FULL` points land inside the `LOW` range at resistances
neither ladder reaches alone. The margin is not large: the closest rungs sit
about 2 ohm apart, so a wiper resistance nearer a whole number of steps would
cost most of the benefit.

An earlier version deleted that overlap as redundant. The offset depends on wiper
resistance, which the datasheet does not characterise at a 24 V span, so the
duplicates were never confirmed to be duplicates. Resistance is read from the
meters, so extra points cost only run time.

What it buys is smaller than the state count suggests. The extra points do not
sit in the middle of the gaps, they sit next to points that already exist: the
sorted sequence is pairs about 2 ohm apart separated by gaps of about 17.6 ohm.
The number that matters is the largest gap, and it falls from 19.6 ohm to
17.6 ohm. That is 10%, not the factor of two that an evenly interleaved second
ladder would give.

The best case is a wiper resistance near half a step, 9.8 ohm, which splits every
gap in two. 155 ohm is 7.9 steps, close to a whole number, so the two ladders
nearly coincide. Nothing in software changes this: 19.6 ohm is 5 kohm over 255
steps and is fixed by the part. Finer steps need a lower-value pot, which costs
range, or more pots in series, each adding another offset.

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

## Illumination left the software

An earlier version drove a Thorlabs EDFA100P over a serial port, held a measured
current-to-power calibration in Part 1, and repeated the whole sweep at each of
several optical powers. All of it is gone: the driver, the calibration arrays,
the level planning and the per-level CSV.

The lamp is set by hand now, so one run of `"sweep"` is one curve at whatever
light the bench happens to be under. A family of curves is several runs. Nothing
in the script knows the illumination, which means nothing in the output records
it either; `RUN_TAG` goes into the file name and is the only place it lives.

That trade is worth naming. What was lost is that a run is no longer
self-describing, and that a mis-set lamp is now an operator error the software
cannot catch. What was gained is that the one Class 3B interlock in the project
is no longer software's problem, an abort has nothing to shut down but relays,
and roughly 700 lines of protocol parsing that had never been run against the
instrument stopped being a maintenance surface.

`ISC_FULL` and `VOC_FULL` survive, because meter ranges still have to be sized
from something. They are now the operator's estimate at the light they set,
rather than a value at a stated `POWER_FULL`.

## Ctrl-C requires onCleanup, which requires a function

The script previously wrapped the sweep in `try`/`catch` and called
`enterSafeState` from the catch block. That does not protect against Ctrl-C: in
MATLAB an interrupt is not an exception and does not run catch blocks. Only
`onCleanup` fires, and only when the workspace holding it is destroyed, which
does not happen to a script's base workspace.

The worst outcome is now a closed relay rather than a pump left at current, but
the argument survives the amplifier: a `SHORT` relay left closed across a lit
cell is exactly the case the power sequencing rules exist to prevent.
`runExperiment` exists to give the cleanup guard a function workspace.

## Isc from an intercept, not from the SHORT point

An ammeter costs the loop some voltage. Both meters on this bench read current
across a shunt: 5 ohm on the 34401A's 10 mA and 100 mA ranges, which is 80 mV at
16 mA. At `SHORT` the cell therefore sits at tens of millivolts rather than at
the 0.150 ohm relay contact alone.

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
`"sweep"` writes one CSV, timestamped so a second run cannot land on the first
and the directory sorts chronologically.

One file rather than two. The second file held what was constant across an
illumination level, and there are no levels any more; what was constant across a
run is now either in the file name or nowhere.

Rows are appended in blocks of 64 states rather than at the end. A sweep runs for
minutes, and an abort partway should not discard what it measured. A row at a
time would be correct and far too slow, `writetable` reopening the file on every
call.

`resistance_ohm` and `power_w` are computed from measured voltage and current,
never from the wiper code.

## No prompts, and independent run modes

The sweep free-runs. A keypress-per-point mode was added on the assumption of
manual reading and removed when that assumption changed. Two meters keep it that
way; one meter would require sweeping twice with a rewire between passes.

`RUN` exists because the bench was assembled in stages: Arduino, board, meters. A
script that could only run all of it at once would have been untestable for
months. Each mode opens only what it needs, and `plan` opens nothing, so a
configuration change can be checked with no hardware attached.

## Arduino bench test

`test_arduino.m` validates every pin the design uses with only an Arduino, a
meter and jumper wires. The jumper tests matter more than the voltage tests: a pin
can read 5 V and still fail as an input or fail to clock data. `spi_loopback` is
the only test that exercises the SPI peripheral, which is the hardest subsystem to
debug once two TSSOP packages are soldered down.

## Open questions

- Wiper resistance measured 155 ohm per device on board 2, with the two chips
  agreeing to 1%. `R_WIPER` carries that now. The datasheet does not specify the
  part at a 24 V span; its quoted range is 75 ohm typical to 200 ohm maximum.
- The 200 ohm gap between `SHORT` (0.150 ohm) and the lowest pot setting is a
  hardware floor. No relay or code combination reaches inside it.
- `CELL_SETTLE` is zero and unmeasured. The computed hold currently accounts for
  cable and meter capacitance only, about 1 ms at the 470 kohm `OPEN` point,
  small next to the 10 ms relay floor. Cell junction capacitance is the term
  likely to dominate.
- The `OPEN` point degrades as a Voc measurement under weak light. The 470 kohm
  path draws a fixed 19 uA at 9 V: 0.12% of a 16 mA Isc, and 5% of a 0.4 mA one.
  `reportPlan` warns above 5%, but it is checking `ISC_FULL`, which is an
  estimate typed in by hand rather than anything the software measured.
- The 196 profile is now read off the manual rather than inferred: functions from
  section 3.9.2, ranges from table 3-9, the setup string from table 3-8, the
  24 ms conversion from table 3-16. Two things that inference had wrong were the
  lowest amps range, which is 300 uA rather than 3 mA, and the conversion time,
  which was carrying 350 ms.
- Overlapped reads assume a one-shot 196 holds the talker off until the
  conversion it was just triggered for is finished. If it instead returns the
  previous reading, every point is lagged by one state and the curve is shifted
  rather than wrong-looking. Check it at bring-up by stepping between two widely
  separated load states; `DMM_PARALLEL = false` is the fallback.
- The 34401A profile is read off manual 34401-90004 but has not been run against
  the instrument. `RUN = "meters"` tests it, and `SYST:ERR?` after configuration
  is the guard. The one thing worth checking first is that `FETC?` waits for the
  conversion `INIT` started rather than returning stale data, which is what the
  overlapped read depends on.
- The 34401A's volts input is 10 Mohm unless `INP:IMP:AUTO ON` raises it, and
  the manual is explicit that `CONFigure` turns that back off, so it is sent
  after the range on every configuration rather than once. It only reaches the
  100 mV, 1 V, and 10 V ranges. Against the 470 kohm `OPEN` path, 10 Mohm reads
  Voc about 4.5% low, so a `VOC_FULL` above 10 V puts the divider back and
  nothing in the configuration warns about it.
- The 196 has the same divider and no way out of it. Its 30 V range, which is
  where a 9 V Voc lands, is 10 Mohm, and there is no input impedance command to
  raise it. So the 34401A is the better voltmeter and the 196 the better
  ammeter, which is the opposite of the way the two were first wired. The code
  does not enforce that; `DMM_V_MODEL` and `DMM_I_MODEL` describe what is
  physically cabled and are the operator's call.
- The profile is per meter rather than per bench because a lab is stocked with
  what it has. Nothing above the transport is shared between the Keithley
  dialect and SCPI, so the pair travels together: an open port and the profile
  that describes it. That is what lets one sweep trigger a 196 with a bare X and
  a 34401A with INIT in the same pass.

## Procedure requirements

Not open questions, but constraints on how the bench is wired:

- The voltmeter connects on the cell side of the ammeter. Downstream of the
  ammeter it reads low by the burden drop, about 80 mV at 16 mA through the
  5 ohm shunt either of these meters uses on its low current ranges.
- 24 V comes up before 5 V, and 5 V comes down first.
