#!/usr/bin/env node
'use strict';

const net = require('node:net');
const { CommandDecoder } = require('./rs485-decoder');

const usage = `Usage: node tools/rs485-monitor.js <host> [port] [--hex | --raw]

Monitor the ESP32 RS485 TCP bridge until Ctrl-C.
Decode PACE-style commands and replies by default (experimental).
  host    ESP32 IP address or hostname (for example, battery.local)
  port    TCP port (default: 1234)
  --hex   Display received bytes in hexadecimal
  --raw   Display ASCII commands, with CR/LF converted to line breaks
  --help  Show this help
`;

const args = process.argv.slice(2);
if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
  process.stdout.write(usage);
} else {
  const raw = args.includes('--raw');
  const hex = args.includes('--hex');
  const positional = args.filter((arg) => arg !== '--raw' && arg !== '--hex');
  const [host, portText = '1234'] = positional;
  const port = Number(portText);

  if (!host || !host.trim() || positional.length > 2 ||
      args.filter((arg) => arg === '--raw' || arg === '--hex').length > 1 ||
      positional.some((arg) => arg.startsWith('-')) ||
      !/^\d+$/.test(portText) || !Number.isInteger(port) || port < 1 || port > 65535) {
    process.stderr.write(`Invalid arguments.\n\n${usage}`);
    process.exitCode = 1;
  } else {
    const socket = net.createConnection({ host, port });
    let interrupted = false;
    let failed = false;
    let previousCR = false;
    const decoder = new CommandDecoder();

    socket.setTimeout(10000);
    socket.once('connect', () => {
      socket.setTimeout(0);
      process.stderr.write(`Connected to ${host}:${port}. Press Ctrl-C to stop.\n`);
    });

    socket.once('timeout', () => {
      socket.destroy(new Error('Connection timed out after 10 seconds'));
    });

    socket.on('data', (data) => {
      let output;
      if (hex) {
        output = `${data.toString('hex').match(/../g).join(' ')}\n`;
      } else if (raw) {
        output = '';
        for (const byte of data) {
          if (byte === 0x0d || byte === 0x0a) {
            if (byte !== 0x0a || !previousCR) output += '\n';
          } else if (byte >= 0x20 && byte <= 0x7e) {
            output += String.fromCharCode(byte);
          } else {
            output += `\\x${byte.toString(16).padStart(2, '0')}`;
          }
          // A CR/LF pair may span TCP chunks.
          previousCR = byte === 0x0d;
        }
      } else {
        output = decoder.push(data);
      }
      if (!process.stdout.write(output)) {
        socket.pause();
      }
    });

    const resume = () => socket.resume();
    const outputError = (error) => {
      failed = true;
      process.stderr.write(`Output error: ${error.message}\n`);
      process.exitCode = 1;
      socket.destroy();
    };
    const interrupt = () => {
      interrupted = true;
      process.exitCode = 130;
      socket.destroy();
    };

    process.stdout.on('drain', resume);
    process.stdout.on('error', outputError);
    process.once('SIGINT', interrupt);

    socket.once('error', (error) => {
      failed = true;
      process.stderr.write(`Connection error: ${error.message}\n`);
      process.exitCode = 1;
    });

    socket.once('close', () => {
      if (!raw && !hex && !failed) process.stdout.write(decoder.finish());
      process.stdout.removeListener('drain', resume);
      process.removeListener('SIGINT', interrupt);
      if (interrupted) {
        process.stderr.write('Stopped.\n');
      } else if (!failed) {
        process.stderr.write('Disconnected: the ESP32 closed the connection.\n');
        process.exitCode = 1;
      }
    });
  }
}
