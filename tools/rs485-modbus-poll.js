#!/usr/bin/env node
'use strict';

const net = require('node:net');

const usage = `Usage: node tools/rs485-modbus-poll.js <host> [port] [options]

Read PACE Modbus holding registers over the ESP32 transparent RS485 TCP bridge.
This sends binary Modbus RTU with CRC, NOT Modbus TCP or ASCII PACE commands.
Use ONLY as the sole polling master on a bus configured for PACE_MODBUS.
No settings, charging controls or write commands are sent.
  host                  ESP32 IP address or hostname
  port                  TCP bridge port (default: 1234)
  --addresses 1,2,3,4    Unique decimal slave addresses, 1-247 (default: 1,2,3,4)
  --timeout 2000        Response timeout in ms, 1-60000 (default: 2000)
  --delay 250           Gap between requests in ms, 5-60000 (default: 250)
  --once                One sweep; exit 1 if any request times out or is rejected
  --raw                 Also show TX/RX bytes in hexadecimal
  --help                Show this help

Reads function 03, registers 0-7, 9-12 and 15-36, for each slave.
Address 0 is Modbus broadcast and cannot be polled; FF is not an all-pack query.
An ASCII PACE reply does not establish Modbus support. Check the battery's
inverter protocol, UART settings and RS485 direction control. Ctrl-C stops.
`;

const blocks = [
  { start: 0, count: 8 },
  { start: 9, count: 4 },
  { start: 15, count: 22 },
];

const exceptions = new Map([
  [1, 'Illegal function'],
  [2, 'Illegal data address'],
  [3, 'Illegal data value'],
  [4, 'Slave device failure'],
  [5, 'Acknowledge'],
  [6, 'Slave device busy'],
  [8, 'Memory parity error'],
  [10, 'Gateway path unavailable'],
  [11, 'Gateway target failed to respond'],
]);

const hexBytes = (data) => Array.from(data, (byte) => byte.toString(16).padStart(2, '0')).join(' ');
const hexWord = (value) => value.toString(16).toUpperCase().padStart(4, '0');

function parseArgs(args) {
  const options = { addresses: [1, 2, 3, 4], timeout: 2000, delay: 250, once: false, raw: false };
  const positional = [];
  const seen = new Set();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith('-')) {
      positional.push(arg);
      continue;
    }
    if (seen.has(arg)) throw new Error(`Duplicate option: ${arg}`);
    seen.add(arg);
    if (arg === '--once' || arg === '--raw') {
      options[arg.slice(2)] = true;
    } else if (arg === '--addresses' || arg === '--timeout' || arg === '--delay') {
      const value = args[++i];
      if (arg === '--addresses') {
        if (!value || !/^\d+(,\d+)*$/.test(value)) throw new Error('Invalid address list');
        const addresses = value.split(',').map(Number);
        if (addresses.some((address) => address < 1 || address > 247) ||
            new Set(addresses).size !== addresses.length) {
          throw new Error('Slave addresses must be unique decimal values from 1 to 247; no broadcast reads');
        }
        options.addresses = addresses;
      } else {
        const minimum = arg === '--delay' ? 5 : 1;
        if (!value || !/^\d+$/.test(value) || Number(value) < minimum || Number(value) > 60000) {
          throw new Error(`${arg} must be an integer from ${minimum} to 60000`);
        }
        options[arg.slice(2)] = Number(value);
      }
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }
  const [host, portText = '1234'] = positional;
  if (!host || !host.trim() || positional.length > 2 || !/^\d+$/.test(portText) ||
      Number(portText) < 1 || Number(portText) > 65535) {
    throw new Error('Expected a host and an optional TCP port from 1 to 65535');
  }
  return { ...options, host, port: Number(portText) };
}

function crc16(data) {
  let crc = 0xffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc & 1) ? (crc >>> 1) ^ 0xa001 : crc >>> 1;
    }
  }
  return crc;
}

function buildReadRequest(address, start, count) {
  if (!Number.isInteger(address) || address < 1 || address > 247 ||
      !Number.isInteger(start) || start < 0 || start > 65535 ||
      !Number.isInteger(count) || count < 1 || count > 125 || start + count > 65536) {
    throw new Error('Expected slave 1-247 and a valid holding-register range of 1-125 words');
  }
  const request = Buffer.alloc(8);
  request[0] = address;
  request[1] = 3;
  request.writeUInt16BE(start, 2);
  request.writeUInt16BE(count, 4);
  request.writeUInt16LE(crc16(request.subarray(0, 6)), 6);
  return request;
}

class RtuDecoder {
  constructor({ onFrame, onDiagnostic }) {
    this.onFrame = onFrame;
    this.onDiagnostic = onDiagnostic;
    this.buffer = Buffer.alloc(0);
    this.request = undefined;
  }

  expect(request) {
    this.finish();
    this.request = request;
  }

  push(data) {
    const bytes = Buffer.concat([this.buffer, data]);
    let offset = 0;
    let noiseStart = 0;
    let incomplete;
    const noise = (end) => {
      if (end > noiseStart) {
        this.onDiagnostic(`Discarded unframed RTU bytes: ${hexBytes(bytes.subarray(noiseStart, end))}`);
      }
    };
    while (offset < bytes.length) {
      const remaining = bytes.length - offset;
      if (this.request) {
        const prefixLength = Math.min(remaining, this.request.length);
        if (bytes.subarray(offset, offset + prefixLength).equals(this.request.subarray(0, prefixLength))) {
          if (remaining < this.request.length) {
            if (incomplete === undefined) incomplete = offset;
            offset++;
            continue;
          }
          noise(offset);
          this.onDiagnostic(`Ignored echoed request: ${hexBytes(this.request)}`);
          offset += this.request.length;
          noiseStart = offset;
          incomplete = undefined;
          continue;
        }
      }
      if (bytes[offset] < 1 || bytes[offset] > 247) {
        offset++;
        continue;
      }
      if (remaining < 2) {
        if (incomplete === undefined) incomplete = offset;
        break;
      }
      const fn = bytes[offset + 1];
      if (fn !== 3 && fn !== 0x83) {
        offset++;
        continue;
      }
      if (remaining < 3) {
        if (incomplete === undefined) incomplete = offset;
        break;
      }
      const byteCount = bytes[offset + 2];
      if (fn === 3 && (byteCount < 2 || byteCount > 250 || byteCount % 2 !== 0)) {
        offset++;
        continue;
      }
      const length = fn === 0x83 ? 5 : byteCount + 5;
      if (remaining < length) {
        // A false header in noise must not hide a later complete, valid frame.
        if (incomplete === undefined) incomplete = offset;
        offset++;
        continue;
      }
      const frame = bytes.subarray(offset, offset + length);
      if (frame.readUInt16LE(length - 2) !== crc16(frame.subarray(0, length - 2))) {
        if (incomplete === undefined) this.onDiagnostic(`CRC mismatch: ${hexBytes(frame)}`);
        offset++;
        continue;
      }
      noise(offset);
      this.onFrame({
        address: frame[0],
        exception: fn === 0x83 ? frame[2] : undefined,
        data: fn === 3 ? frame.subarray(3, length - 2) : Buffer.alloc(0),
      });
      offset += length;
      noiseStart = offset;
      incomplete = undefined;
    }
    const keepFrom = incomplete === undefined ? bytes.length : incomplete;
    noise(keepFrom);
    this.buffer = Buffer.from(bytes.subarray(keepFrom));
  }

  finish() {
    if (this.buffer.length) {
      this.onDiagnostic(`Incomplete RTU data: ${hexBytes(this.buffer)}`);
    }
    this.buffer = Buffer.alloc(0);
    this.request = undefined;
  }
}

function formatRegisters(address, start, data) {
  const block = blocks.find((item) => item.start === start);
  if (!block || data.length !== block.count * 2) {
    throw new Error('Unexpected PACE holding-register block or response length');
  }
  const unsigned = (register) => data.readUInt16BE((register - start) * 2);
  const signed = (register) => data.readInt16BE((register - start) * 2);
  const header = `Battery ${address}: holding ${start}-${start + block.count - 1}; CRC OK\n`;
  if (start === 0) {
    const current = signed(0) / 100;
    const voltage = unsigned(1) / 100;
    return header +
      `  Pack: ${voltage.toFixed(2)} V; current=${current.toFixed(2)} A; power=${(current * voltage).toFixed(2)} W; SOC=${unsigned(2)}%; SOH=${unsigned(3)}%\n` +
      `  Capacity: ${(unsigned(4) / 100).toFixed(2)}/${(unsigned(5) / 100).toFixed(2)} Ah; design=${(unsigned(6) / 100).toFixed(2)} Ah; cycles=${unsigned(7)}\n`;
  }
  if (start === 9) {
    return header + `  Status: warnings=0x${hexWord(unsigned(9))}; protections=0x${hexWord(unsigned(10))}; status/fault=0x${hexWord(unsigned(11))}; balance=0x${hexWord(unsigned(12))}\n`;
  }
  const cells = Array.from({ length: 16 }, (_, index) => unsigned(15 + index));
  const names = ['battery1', 'battery2', 'battery3', 'battery4', 'MOSFET', 'environment'];
  return header +
    `  Cells (16, V): ${cells.map((mv) => (mv / 1000).toFixed(3)).join(', ')}; spread=${Math.max(...cells) - Math.min(...cells)} mV\n` +
    `  Temperatures (C): ${names.map((name, index) => `${name}=${(signed(31 + index) / 10).toFixed(1)}`).join('; ')}\n`;
}

function poll(options) {
  const { host, port, addresses, timeout, delay, once: singleSweep, raw } = options;
  const requests = addresses.flatMap((address) => blocks.map((block) => ({ address, ...block })));
  const socket = net.createConnection({ host, port });
  let timer;
  let pending;
  let index = 0;
  let stopping = false;
  let failed = false;
  let requestFailed = false;
  let outputBlocked = false;

  function output(text) {
    if (text && !process.stdout.write(text)) {
      outputBlocked = true;
      socket.pause();
    }
  }

  const decoder = new RtuDecoder({
    onDiagnostic: (message) => process.stderr.write(`${message}\n`),
    onFrame(frame) {
      if (!pending || frame.address !== pending.address) {
        process.stderr.write(`Unexpected Modbus reply from slave ${frame.address}; ignored.\n`);
        return;
      }
      if (frame.exception !== undefined) {
        requestFailed = true;
        const reason = exceptions.get(frame.exception) || 'Unknown exception';
        process.stderr.write(`Battery ${pending.address}, holding ${pending.start}-${pending.start + pending.count - 1}: Modbus exception 0x${frame.exception.toString(16).padStart(2, '0')} (${reason}).\n`);
      } else if (frame.data.length !== pending.count * 2) {
        process.stderr.write(`Battery ${pending.address}: unexpected byte count ${frame.data.length}, expected ${pending.count * 2}; ignored.\n`);
        return;
      } else {
        output(formatRegisters(pending.address, pending.start, frame.data));
      }
      advance();
    },
  });

  function advance() {
    clearTimeout(timer);
    pending = undefined;
    index++;
    timer = setTimeout(sendNext, delay);
  }

  function sendNext() {
    timer = undefined;
    if (stopping || socket.destroyed || outputBlocked) return;
    if (index === requests.length) {
      if (singleSweep) {
        stopping = true;
        process.exitCode = requestFailed ? 1 : 0;
        socket.end();
        return;
      }
      index = 0;
    }
    pending = requests[index];
    const request = buildReadRequest(pending.address, pending.start, pending.count);
    decoder.expect(request);
    if (raw) output(`TX ${hexBytes(request)}\n`);
    timer = setTimeout(() => {
      requestFailed = true;
      process.stderr.write(`Battery ${pending.address}, holding ${pending.start}-${pending.start + pending.count - 1}: no Modbus response within ${timeout} ms.\n`);
      advance();
    }, timeout);
    socket.write(request);
  }

  const resume = () => {
    outputBlocked = false;
    socket.resume();
    if (!timer && !pending) sendNext();
  };
  const outputError = (error) => {
    failed = true;
    process.exitCode = 1;
    process.stderr.write(`Output error: ${error.message}\n`);
    socket.destroy();
  };
  const interrupt = () => {
    stopping = true;
    process.exitCode = 130;
    clearTimeout(timer);
    socket.destroy();
    process.stderr.write('Stopped.\n');
  };
  process.stdout.on('drain', resume);
  process.stdout.on('error', outputError);
  process.once('SIGINT', interrupt);
  socket.setTimeout(10000);
  socket.once('connect', () => {
    socket.setTimeout(0);
    socket.setNoDelay(true);
    process.stderr.write(`Connected to ${host}:${port}. Polling Modbus slaves ${addresses.join(', ')}; Ctrl-C to stop.\n`);
    process.stderr.write('WARNING: Requires PACE_MODBUS and no other polling master; ASCII PACE support is not sufficient.\n');
    sendNext();
  });
  socket.once('timeout', () => socket.destroy(new Error('Connection timed out after 10 seconds')));
  socket.on('data', (data) => {
    if (raw) output(`RX ${hexBytes(data)}\n`);
    decoder.push(data);
  });
  socket.once('error', (error) => {
    failed = true;
    process.exitCode = 1;
    process.stderr.write(`Connection error: ${error.message}\n`);
  });
  socket.once('close', () => {
    clearTimeout(timer);
    decoder.finish();
    process.stdout.removeListener('drain', resume);
    process.removeListener('SIGINT', interrupt);
    if (!stopping && !failed) {
      process.exitCode = 1;
      process.stderr.write('Disconnected: the ESP32 closed the connection.\n');
    }
  });
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

module.exports = { buildReadRequest, crc16, formatRegisters, parseArgs, poll, RtuDecoder };
