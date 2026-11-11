#!/usr/bin/env node
'use strict';

const { CommandDecoder, parseFrame } = require('./rs485-decoder');
const { buildReadRequest, parseArgs: parsePaceArgs, poll: pollPace } = require('./rs485-poll');

const usage = `Usage: node tools/rs485-pylon-poll.js <host> [port] [options]

Read PYLON/Pylontech measurements (42) and warnings (44) over the ESP32 TCP bridge.
Node.js 18+; no npm dependencies. No write/control commands are sent.
Use ONLY as the sole polling master, not alongside the inverter on the same bus.
  host                  ESP32 IP address or hostname
  port                  TCP bridge port (default: 1234)
  --destination 2       Frame destination, decimal 0-15 (default: 2)
  --addresses FF        INFO selectors: decimal 0-15 or FF (default: FF)
                        FF reads all modules through the destination/master
  --timeout 2000        Response timeout, 1-60000 ms (default: 2000)
  --delay 250           Gap between requests, 1-60000 ms (default: 250)
  --once                One sweep; exit 1 on timeout/rejection/unsupported payload
  --raw                 Also show TX/RX ASCII with escaped CR/LF
  --help                Show help without connecting

Uses version 20, CID1 46, PYLON units/layouts, not the PACE payload decoder.
Destination 2 is a Pylontech reference default, not verified for SG48100.
Try the configured master address (for example --destination 0 or 1).
The port may expose aggregate data only. Module order is NOT a physical address.
Match UART settings to the battery; this tool does not change the bridge baud.
Ctrl-C stops. This is diagnostic polling, not an inverter BMS replacement.
`;

const hex = (value) => value.toString(16).toUpperCase().padStart(2, '0');
const payloadHex = (info) => info.toString('hex').toUpperCase() || '(empty)';

function parseArgs(args) {
  if (args.includes('--master-ff') || args.includes('--protocol')) {
    throw new Error('PYLON uses version 20; use --destination and --addresses for addressing');
  }
  const defaults = ['--protocol', '20'];
  if (!args.includes('--destination')) defaults.push('--destination', '2');
  if (!args.includes('--addresses')) defaults.push('--addresses', 'FF');
  return parsePaceArgs([...args, ...defaults]);
}

function buildPylonRequest(address, command, protocol = 0x20, selector = 0xff) {
  if (protocol !== 0x20) throw new Error('PYLON requests must use version 20');
  return buildReadRequest(address, command, protocol, selector);
}

function decodePayload(info, command, selector) {
  let offset = 0;
  const need = (count) => {
    if (offset + count > info.length) throw new Error('Truncated PYLON payload');
  };
  const byte = () => { need(1); return info[offset++]; };
  const word = (signed = false) => {
    need(2);
    const value = signed ? info.readInt16BE(offset) : info.readUInt16BE(offset);
    offset += 2;
    return value;
  };
  const longCapacity = () => {
    need(3);
    const value = info.readUIntBE(offset, 3) / 1000;
    offset += 3;
    return value;
  };
  const flag = byte();
  const countOrSelector = byte();
  const all = selector === 0xff;
  if (!all && countOrSelector !== selector) throw new Error('Reply INFO selector does not match request');
  const count = all ? countOrSelector : 1;
  if (count < 1 || count > 16) throw new Error(`Unsupported module count ${count}`);
  const modules = [];
  for (let index = 0; index < count; index++) {
    const cellCount = byte();
    if (cellCount < 1 || cellCount > 32) throw new Error(`Unsupported cell count ${cellCount}`);
    const cells = Array.from({ length: cellCount }, () => command === 0x42 ? word() / 1000 : byte());
    const temperatureCount = byte();
    if (temperatureCount > 16) throw new Error(`Unsupported temperature count ${temperatureCount}`);
    const temperatures = Array.from({ length: temperatureCount },
      () => command === 0x42 ? (word(true) - 2731) / 10 : byte());
    const module = { cells, temperatures };
    if (command === 0x42) {
      module.current = word(true) / 10;
      module.voltage = word() / 1000;
      module.remaining = word() / 1000;
      const userItems = byte();
      module.total = word() / 1000;
      module.cycles = word();
      // PYLON defines two legacy items, or four with 24-bit mAh capacities.
      if (userItems !== 2 && userItems !== 4) {
        throw new Error(`Unsupported PYLON user-defined item count ${userItems}`);
      }
      if (userItems === 4) {
        module.remaining = longCapacity();
        module.total = longCapacity();
      }
    } else {
      need(8);
      module.status = Array.from(info.subarray(offset, offset + 8));
      offset += 8;
    }
    modules.push(module);
  }
  if (offset !== info.length) throw new Error(`Unrecognized PYLON extension (${info.length - offset} bytes)`);
  return { flag, all, modules };
}

function formatPayload(data, selector) {
  const lines = [`  INFO flag=0x${hex(data.flag)}; ${data.modules.length} module(s)`];
  data.modules.forEach((module, index) => {
    const label = data.all ? `Module ${index + 1} (reply order, not battery address)` : `Battery selector ${selector}`;
    lines.push(`  ${label}:`);
    if (module.status) {
      lines.push(`    Cell warning codes: ${module.cells.map(hex).join(' ')}`,
        `    Temperature warning codes: ${module.temperatures.map(hex).join(' ') || '(none)'}`,
        `    Status/alarm registers (raw): ${module.status.map(hex).join(' ')}`);
    } else {
      const soc = module.total > 0 ? `; calculated SOC=${(module.remaining / module.total * 100).toFixed(1)}%` : '';
      lines.push(
        `    Pack: ${module.voltage.toFixed(3)} V; current=${module.current.toFixed(1)} A; capacity=${module.remaining.toFixed(3)}/${module.total.toFixed(3)} Ah${soc}; cycles=${module.cycles}`,
        `    Cells (${module.cells.length}, V): ${module.cells.map((v) => v.toFixed(3)).join(', ')}; spread=${((Math.max(...module.cells) - Math.min(...module.cells)) * 1000).toFixed(0)} mV`,
        `    Temperatures (${module.temperatures.length}, C): ${module.temperatures.map((v) => v.toFixed(1)).join(', ') || '(none)'}`);
    }
  });
  return lines.join('\n') + '\n';
}

class PylonDecoder extends CommandDecoder {
  decode(frame) {
    const parsed = parseFrame(frame);
    if (parsed.error) return `Invalid PYLON frame: ${parsed.error}; ASCII=${JSON.stringify(frame)}\n`;
    const { version, address, type, code, info } = parsed;
    const prefix = `PYLON destination ${address}, version ${hex(version)}`;
    if (version !== 0x20 || type !== 0x46) {
      return `${prefix}: unsupported protocol; payload=${payloadHex(info)}\n`;
    }
    if (code === 0x42 || code === 0x44) {
      if (info.length !== 1) return `${prefix}: invalid read request; payload=${payloadHex(info)}\n`;
      this.pending.set(address, { code, selector: info[0], time: Date.now() });
      return `${prefix}: REQUEST ${hex(code)}; INFO=${hex(info[0])}; checksum OK\n`;
    }
    const pending = this.pending.get(address);
    if (!pending || Date.now() - pending.time > this.responseTimeout) {
      return `${prefix}: unmatched response; return code=0x${hex(code)}; payload=${payloadHex(info)}\n`;
    }
    this.pending.delete(address);
    let output = `${prefix}: RESPONSE ${hex(pending.code)}; return code=0x${hex(code)}; checksum OK\n`;
    if (code === 0) {
      let data;
      try {
        data = decodePayload(info, pending.code, pending.selector);
      } catch (error) {
        output += `  ${error.message}; payload=${payloadHex(info)}\n`;
        // A protocol success with an unknown payload is not a successful data read.
        if (this.onInvalidPayload) this.onInvalidPayload(error);
      }
      if (data) output += formatPayload(data, pending.selector);
    } else {
      output += `  Request rejected; payload=${payloadHex(info)}\n`;
    }
    if (this.onResponse) this.onResponse(parsed, pending.code);
    return output;
  }

  constructor(options = {}) {
    super(options);
    this.onInvalidPayload = options.onInvalidPayload;
  }
}

function poll(options) {
  return pollPace(options, { Decoder: PylonDecoder, buildRequest: buildPylonRequest });
}

if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
    process.stdout.write(usage);
  } else {
    let options;
    try {
      options = parseArgs(args);
    } catch (error) {
      process.stderr.write(`Invalid arguments: ${error.message}\n\n${usage}`);
      process.exitCode = 1;
    }
    if (options) poll(options);
  }
}

module.exports = { buildPylonRequest, decodePayload, parseArgs, poll, PylonDecoder };
