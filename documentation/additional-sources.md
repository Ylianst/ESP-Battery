# Additional Information Sources

References for the SunGoldPower SG48100 battery family and BluePower SP6548
inverter, including monitoring software, owner discussions and protocol research.
Links were researched on November 1, 2026. Firmware and hardware revisions can
differ; a reference for a related product is not proof of compatibility.

## Local manuals

Use the supplied manuals first when checking settings or hardware interfaces.
The Markdown versions are searchable conversions; diagrams, graphical symbols
and wiring illustrations remain in the original PDFs.

| Equipment | Searchable manual | Original PDF |
| --- | --- | --- |
| SG48100 battery family; the supplied manual identifies SG48100P on its cover | [SG48100.md](SG48100.md) | [SG48100.pdf](SG48100.pdf) |
| BluePower SP6548 inverter / charger | [BluePower_SP6548-20231129.md](BluePower_SP6548-20231129.md) | [BluePower_SP6548-20231129.pdf](BluePower_SP6548-20231129.pdf) |

Useful sections:

- Battery [panel/interface descriptions](SG48100.md#pdf-page-6),
  [connector definitions](SG48100.md#pdf-page-14),
  [RS232/RS485 communication](SG48100.md#pdf-page-15) and
  [DIP switch addresses](SG48100.md#pdf-page-20).
- Inverter [output-source priorities](BluePower_SP6548-20231129.md#pdf-page-18),
  [charging-source priorities](BluePower_SP6548-20231129.md#pdf-page-22),
  [standby behavior](BluePower_SP6548-20231129.md#pdf-page-37) and
  [BMS communication appendix](BluePower_SP6548-20231129.md#pdf-page-62).

## Official SunGoldPower resources

### Monitoring software

[SunGoldPower monitoring software and manuals](https://sungoldpower.com/pages/monitoring-software)

The official page explicitly associates:

| Product | Software |
| --- | --- |
| BluePower SP6548 inverter | WatchPower |
| SG48100P / SG48100M batteries | PBMS Tools |
| Listed SPH-series inverters, including SPH6548P | iPower |

The page provides a WatchPower user manual and downloads for Windows, Linux
and macOS. Prefer this landing page over individual download links, which may
change. Download software only after checking the exact model and supported
operating system.

**SP6548 and SPH6548P are not interchangeable model names.** SunGoldPower lists
different software for them. Similarly, its SolarPower downloads for IP6048 and
TP6048 should not be assumed appropriate for SP6548.

WatchPower is a useful starting point for investigating the inverter's own
monitoring/control connection. Its availability does **not** by itself establish
support for remotely enabling/disabling AC output while retaining PV charging.
That capability and any corresponding command still need verification.

### Manuals

[SunGoldPower user-manual directory](https://sungoldpower.com/pages/user-manual)

Check for an updated manual matching the equipment label and firmware. The
local copies above remain the reference used for this project's current work.

## Owner forums

### DIY Solar Power Forum

[DIY Solar Power Forum](https://diysolarforum.com/)

Search-indexed discussions specifically naming SP6548:

- [Tech Support: Four SP6548 inverter settings](https://diysolarforum.com/threads/tech-support-four-sp6548-inverter-settings.72551/)
- [Sungold power SP6548 not charging battery bank](https://diysolarforum.com/threads/sungold-power-sp6548-not-charging-battery-bank.66278/)

**Verification limitation:** these thread titles and URLs were found through
web search, but direct automated access returned HTTP 403. Individual replies,
their recommendations and any claimed solutions have not been independently
verified. Open the threads in a browser before relying on them.

Useful search terms:

- `site:diysolarforum.com SP6548 WatchPower`
- `site:diysolarforum.com SP6548 standby remote on off`
- `site:diysolarforum.com SG48100 RS232 master battery`

When posting, include the full model name, firmware versions, battery type,
connection/interface used and relevant settings. Avoid treating instructions
for similarly named equipment as confirmed instructions for this inverter.

Example question for solar-triggered output control:

> Does the BluePower SP6548 support remotely enabling/disabling AC output while
> leaving PV battery charging active? Is this available through WatchPower or a
> documented USB/serial command? I want solar-triggered output with a manual
> override.

## Community battery-protocol references

These are community implementation/research sources, not SunGoldPower protocol
guarantees:

- [PACE ASCII protocol reference](https://github.com/SPDG/pace-bms-mqtt-bridge/blob/main/docs/PROTOCOL.md):
  framing, length/checksum calculations, command identifiers and example payload
  layouts. Useful for researching commands `42`, `44` and `90`.
- [PACE v25 implementation](https://github.com/nkinnan/esphome-pace-bms/blob/main/components/pace_bms/pace_bms_protocol_v25.cpp):
  another implementation with example frames and handling for protocol variants.
  Its pack-voltage decoding uses millivolts, consistent with the observed
  SG48100 traffic.
- [Pylontech Python project](https://github.com/Tomcat42/pylontech-python):
  related RS485 protocol research. Its documented supported batteries are
  Pylontech models; SG48100 compatibility is not established by that project.

Related protocols can differ in units, address conventions, temperature offsets,
pack-count fields and vendor extensions. Cross-check against actual validated
frames and the sum of cell voltages instead of copying a layout uncritically.
The project's [Node.js monitor](../tools/rs485-monitor.js) and
[Flutter dashboard](../tools/battery_dashboard/README.md) document their current
decoder scope and limitations.

## Open questions and practical boundaries

- **Missing master battery:** the SG48100 manual describes RS485 polling for
  addresses 2-63. The observed traffic contains replies for batteries 2, 3 and
  4, not battery 1. This is consistent with the master polling the others, but
  does not establish how to retrieve its local measurements on that bus.
- **Master monitoring:** the manual explicitly describes RS232 host monitoring
  at a default 9600 baud. Testing battery 1 through its dedicated RS232
  interface is a promising next step; query/address behavior and whether data
  is local or aggregated still need verification.
- **Separate RS485 port:** the panel distinguishes an RS485 connection from the
  parallel RS485B/RS485C connectors. Electrical independence and availability of
  the master's own readings are not established by the manual.
- **Solar-triggered AC output:** standby can retain solar battery charging
  without AC output. Solar First, SBU and Only Solar settings select source
  priorities; they do not establish an automatic PV-triggered output-enable
  function. A supported remote enable/standby interface must be verified before
  implementing automation.

Do not inject monitoring queries onto a bus already controlled by the master
without a verified arbitration strategy. RS232, RS485 and ESP32 UART/TTL are
different electrical interfaces; use the appropriate transceiver and verify
connector assignments against the original manual and hardware revision.
