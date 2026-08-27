# Snipeit Inventory Agent - Change log v1.3.2

Released: 4 August 2026

## Accurate RAM speed presentation

Version 1.3.2 stopped deriving a so-called RAM clock by dividing a DDR value by
two and presenting that derived value as a hardware measurement. Windows reads
`ConfiguredClockSpeed` and `Speed` from SMBIOS; these values are reported as
`MT/s` exactly as supplied by firmware.

The agent uses `Win32_PhysicalMemory` directly and retains module capacity,
manufacturer, part number, memory type, form factor, locator, configured
speed, and module speed. No low-level SMBus driver or vendor-specific SPD API
is installed.

Examples:

```text
32 GB DDR5; 5600 MT/s; 2 x 16 GB; 2/2 SODIMM slots used

16 GB LPDDR5; configured 5200 MT/s; module 6400 MT/s; onboard
```

For soldered memory the agent explicitly reports that no user-replaceable
DIMM/SODIMM slots are available.

## Compatibility and deployment

- State schema remains `3`.
- Relay payload remains compatible with the 1.3.x line.
- Existing protected configuration remains valid; credentials and secrets do
  not need to be rotated for this update.
- The agent still does not create or overwrite `asset_tag`.
- SHA-256 based deployment updates only changed files. The transition creates
  one `install_update` event and one forced report; a repeated installer run is
  idempotent.

## Release validation

The release includes RAM-specific tests for unchanged `MT/s` values, absence of
fabricated MHz values, soldered memory, dual-SODIMM reporting, and a real RAM
collection run on a test device.
