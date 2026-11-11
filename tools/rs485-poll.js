#!/usr/bin/env node
'use strict';

const net = require('node:net');
const { CommandDecoder } = require('./rs485-decoder');

const usage = `Usage: node tools/rs485-poll.js <host> [port] [options]

Actively read PACE measurements and warnings over the ESP32 TCP bridge.
Use ONLY on a bus with no other polling master (inverter or master battery).
No settings, charging controls or other write commands are sent.
  host                  ESP32 IP address or hostname
  port                  TCP port (default: 1234)
  --addresses 1,2,3,4    Pack selectors, decimal 0-15 or FF (default: 1,2,3,4)
  --destination 0       Fixed frame destination, decimal 0-15 (default: each pack)
                        FF requires --destination and requests an all-pack reply
  --master-ff           Use INFO FF instead of 01 for address 1 (not broadcast)
  --protocol 25         Request protocol, 20 or 25 (default: 25)
  --timeout 2000        Response timeout in ms, 1-60000 (default: 2000)
  --delay 250           Gap between requests in ms, 1-60000 (default: 250)
  --once                One sweep; exit 1 if any request times out or is rejected
  --raw                 Also show TX/RX ASCII bytes, with escaped CR/LF
  --help                Show this help

The RS485A/inverter port may use a different protocol or expose only the master.
No response does not prove that a battery is missing. Check protocol, baud rate,
addressing, wiring and transmit direction control. Ctrl-C stops polling.
`;

function parseArgs(args) {
  const options = { addresses: [1, 2, 3, 4], protocol: 0x25, timeout: 2000, delay: 250, once: false, raw: false, masterFF: false };
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
    if (arg === '--master-ff') {
      options.masterFF = true;
    } else if (arg === '--once' || arg === '--raw') {
      options[arg.slice(2)] = true;
    } else if (arg === '--addresses' || arg === '--timeout' || arg === '--delay' ||
               arg === '--protocol' || arg === '--destination') {
      const value = args[++i];
      if (arg === '--protocol') {
        if (value !== '20' && value !== '25') throw new Error('--protocol must be 20 or 25');
        options.protocol = parseInt(value, 16);
      } else if (arg === '--destination') {
        if (!value || !/^\d+$/.test(value) || Number(value) > 15) {
          throw new Error('--destination must be a decimal value from 0 to 15');
        }
        options.destination = Number(value);
      } else if (arg === '--addresses') {
        if (!value || !/^(?:\d+|FF)(?:,(?:\d+|FF))*$/i.test(value)) throw new Error('Invalid address list');
        const selectors = value.split(',');
        const addresses = selectors.map((selector) => /^FF$/i.test(selector) ? 0xff : Number(selector));
        if (selectors.some((selector) => !/^FF$/i.test(selector) && Number(selector) > 15) ||
            new Set(addresses).size !== addresses.length) {
          throw new Error('Pack selectors must be unique decimal values from 0 to 15 or FF');
        }
        options.addresses = addresses;
      } else {
        const maximum = 60000;
        if (!value || !/^\d+$/.test(value) || Number(value) < 1 || Number(value) > maximum) {
          throw new Error(`${arg} must be an integer from 1 to ${maximum}`);
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
  if (options.addresses.includes(0xff) && options.destination === undefined) {
    throw new Error('FF requires --destination; it is an INFO selector, not a frame destination');
  }
  if (options.masterFF && options.destination !== undefined) {
    throw new Error('Use --addresses FF with --destination instead of --master-ff');
  }
  return { ...options, host, port: Number(portText) };
}

function buildReadRequest(address, command, protocol = 0x25, packAddress = address) {
  if (!Number.isInteger(address) || address < 0 || address > 15 ||
      (command !== 0x42 && command !== 0x44) || (protocol !== 0x20 && protocol !== 0x25) ||
      !Number.isInteger(packAddress) || packAddress < 0 || (packAddress > 15 && packAddress !== 0xff)) {
    throw new Error('Expected a PACE destination from 0 to 15, read command 0x42 or 0x44, protocol 20 or 25, and INFO selector from 0 to 15 or FF');
  }
  const byte = (value) => value.toString(16).toUpperCase().padStart(2, '0');
  // INFO selects the pack independently of the frame's destination address.
  const body = `${byte(protocol)}${byte(address)}46${byte(command)}E002${byte(packAddress)}`;
  let sum = 0;
  for (const char of body) sum += char.charCodeAt(0);
  const checksum = ((-sum) & 0xffff).toString(16).toUpperCase().padStart(4, '0');
  return Buffer.from(`~${body}${checksum}\r`, 'ascii');
}

function poll(options, { Decoder = CommandDecoder, buildRequest = buildReadRequest } = {}) {
  const { host, port, addresses, destination, protocol, timeout, delay, once: singleSweep, raw, masterFF } = options;
  const requests = addresses.flatMap((packAddress) =>
    [0x42, 0x44].map((command) => ({
      address: destination === undefined ? packAddress : destination,
      packAddress: masterFF && packAddress === 1 ? 0xff : packAddress,
      command,
    })));
  const socket = net.createConnection({ host, port });
  let timer;
  let pending;
  let index = 0;
  let stopping = false;
  let failed = false;
  let requestFailed = false;
  let outputBlocked = false;
  const decoder = new Decoder({
    responseTimeout: timeout,
    onInvalidPayload(error) {
      requestFailed = true;
      process.stderr.write(`Data error: ${error.message}\n`);
    },
    onResponse(frame, command) {
      if (!pending || frame.address !== pending.address || command !== pending.command) return;
      if (frame.code !== 0) {
        requestFailed = true;
        process.stderr.write(`Battery ${frame.address}: request rejected (return code 0x${frame.code.toString(16)}); INFO=0x${pending.packAddress.toString(16).padStart(2, '0')}.\n`);
      }
      advance();
    },
  });

  function output(text) {
    if (text && !process.stdout.write(text)) {
      outputBlocked = true;
      socket.pause();
    }
  }

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
    const request = buildRequest(pending.address, pending.command, protocol, pending.packAddress);
    // The bridge does not echo TCP writes, so seed the shared decoder locally.
    if (raw) output(`TX ${JSON.stringify(request.toString('ascii'))}\n`);
    output(decoder.push(request));
    timer = setTimeout(() => {
      requestFailed = true;
      process.stderr.write(`Battery ${pending.address}: no response to 0x${pending.command.toString(16)} within ${timeout} ms; INFO=0x${pending.packAddress.toString(16).padStart(2, '0')}.\n`);
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
    const selectors = addresses.map((address) => address === 0xff ? 'FF' : String(address));
    process.stderr.write(`Connected to ${host}:${port}. Polling batteries ${selectors.join(', ')}; Ctrl-C to stop.\n`);
    if (destination !== undefined) {
      process.stderr.write(`Fixed frame destination ${destination}; INFO selects the requested pack.\n`);
    }
    if (masterFF && addresses.includes(1)) {
      process.stderr.write('Address 1 requests use INFO FF; the destination remains 01, not a broadcast address.\n');
    }
    process.stderr.write('WARNING: This tool must be the only polling master on this RS485 bus.\n');
    sendNext();
  });
  socket.once('timeout', () => socket.destroy(new Error('Connection timed out after 10 seconds')));
  socket.on('data', (data) => {
    if (raw) output(`RX ${JSON.stringify(data.toString('latin1'))}\n`);
    output(decoder.push(data));
  });
  socket.once('error', (error) => {
    failed = true;
    process.exitCode = 1;
    process.stderr.write(`Connection error: ${error.message}\n`);
  });
  socket.once('close', () => {
    clearTimeout(timer);
    if (!failed) output(decoder.finish());
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

module.exports = { buildReadRequest, parseArgs, poll };
