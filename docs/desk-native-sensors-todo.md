# Todo soon: native Desk sensor view replacing HWiNFO64

Status: operator-requested investigation/plan, not an implementation commitment.
Priority: after the current Windows WMI/Event Log recovery.

## Goal

Replace the operator's reliance on HWiNFO64 with a focused sensor view in
`scripts\Show-DeskMenu.ps1`. Keep scope flexible until the actual hardware
access paths and required readings are known. Use REA for the investigation
rather than repeating the manual effort of the Dell Display Manager work.
REA is the operator-named tool; its exact setup and usable interfaces still
need to be checked before execution.

## Initial readings

- Relevant SVID/VID requests, clearly distinguished from measured rail voltage.
- CPU clocks; distinguish requested, reported and effective clocks where available.
- Actual Vcore when a suitable sensor exposes it.
- RAM voltages, power and temperatures.
- Memory-controller voltage and other useful rails identified during inventory.

This is the starting list, not a closed specification. Identify sensor names,
units, provenance, update rates and availability before designing the panel.

## Investigation and implementation outline

1. Inventory the existing ThrottleStop and board/DIMM sensor access paths.
   Use REA to identify supported interfaces and relevant register/sensor behavior.
   Do not assume one tool or driver exposes every requested measurement.
2. Select the smallest practical native C++ read-only implementation. Prefer an
   existing supported interface when its permissions and reuse terms allow it;
   do not assume undocumented IOCTLs or redistribute third-party code/drivers.
3. Keep hardware access behind a narrow, bounded telemetry interface for the
   existing Desk menu. No new web runtime, agent framework or second monitor app.
4. Prototype a few verified readings first, then expand only to sensors that
   provide useful, independently checked information.
5. Add asynchronous refresh and per-sensor failure/staleness indications.
   Missing WMI or one unavailable sensor must not block opening the panel.
6. Validate actual readings on this host against appropriate independent
   references. Exercise unavailable sensors, timeouts and resume. Do not equate
   VID with delivered Vcore or treat plausible numbers as verified telemetry.

## Boundaries and open questions

- Read-only sensors first: no voltage, clock, power-limit or firmware writes.
- A new kernel driver, altered driver policy or privileged execution boundary
  requires its own design and operator decision; this note does not authorize it.
- Do not require HWiNFO64 to run for normal use.
- Investigate safe sharing of sensor buses and existing drivers before polling.
- Determine which RAM/board readings are exposed on the actual hardware.
- Sampling rate, history/graphs, alerts and persistence remain undecided.
- No sensor implementation, hardware probing or host configuration change is
  authorized by saving this todo.
