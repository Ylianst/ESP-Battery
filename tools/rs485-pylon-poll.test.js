'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const net = require('node:net');
const path = require('node:path');
const { test } = require('node:test');
const { buildPylonRequest, decodePayload, parseArgs, PylonDecoder } = require('./rs485-pylon-poll');

const script = path.join(__dirname, 'rs485-pylon-poll.js');

function frame(address, code, payload = '', version = 0x20, type = 0x46) {
  const hex = (value, size) => value.toString(16).toUpperCase().padStart(size, '0');
  const length = payload.length;
  const check = (-(length + (length >> 4) + (length >> 8))) & 15;
  const body = `${hex(version, 2)}${hex(address, 2)}${hex(type, 2)}${hex(code, 2)}${hex((check << 12) | length, 4)}${payload}`;
  const sum = Array.from(body).reduce((total, char) => total + char.charCodeAt(0), 0);
  return `~${body}${hex((-sum) & 65535, 4)}\r`;
}

// Two cells, one temperature, -2.6 A, 6.600 V, 33.5/50 Ah, 31 cycles.
const legacyModule = '020CE40CE4010B91FFE619C882DC02C350001F';
const extendedModule = '020CE40CE4010B91FFE619C8FFFF04FFFF001F0186A0030D40';
const warningModule = '02000101020000000000000000';
const payload = (command, selector = 0xff) =>
  `11${selector === 0xff ? '02' : selector.toString(16).padStart(2, '0')}` +
  (command === 0x42 ? legacyModule : warningModule).repeat(selector === 0xff ? 2 : 1);

function run(t, args, interruptible = false) {
  const bootstrap = `
    const { poll, parseArgs } = require(${JSON.stringify(script)});
    poll(parseArgs(process.argv.slice(1)));
    process.once('message', () => { process.disconnect(); process.emit('SIGINT'); });
  `;
  const child = interruptible
    ? spawn(process.execPath, ['-e', bootstrap, ...args], { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] })
    : spawn(process.execPath, [script, ...args]);
  t.after(() => child.kill());
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (data) => { stdout += data; });
  child.stderr.on('data', (data) => { stderr += data; });
  return { child, result: once(child, 'close').then(([code]) => ({ code, stdout, stderr })) };
}

async function bridge(t, onRequest) {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    let buffer = '';
    socket.on('data', (data) => {
      buffer += data.toString('ascii');
      let end;
      while ((end = buffer.indexOf('\r')) !== -1) {
        const request = buffer.slice(0, end + 1);
        buffer = buffer.slice(end + 1);
        onRequest(request, socket);
      }
    });
  });
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    return new Promise((resolve) => server.close(resolve));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return String(server.address().port);
}

test('PYLON defaults, exact wire requests and argument validation', () => {
  assert.deepEqual(parseArgs(['host']), {
    host: 'host', port: 1234, addresses: [255], destination: 2, protocol: 0x20,
    timeout: 2000, delay: 250, once: false, raw: false, masterFF: false,
  });
  assert.equal(buildPylonRequest(2, 0x42).toString(), '~20024642E002FFFD09\r');
  assert.equal(buildPylonRequest(2, 0x44).toString(), '~20024644E002FFFD07\r');
  assert.equal(buildPylonRequest(0, 0x42, 0x20, 1).toString(), frame(0, 0x42, '01'));
  assert.deepEqual(parseArgs(['host', '2345', '--destination', '0', '--addresses', '1,2,3,4']).addresses, [1, 2, 3, 4]);
  for (const args of [
    [], ['host', '--protocol', '25'], ['host', '--master-ff'], ['host', '--unknown'],
    ['host', '--destination'], ['host', '--destination', '16'],
    ['host', '--addresses', 'FF,ff'], ['host', '--addresses', '16'],
    ['host', '--raw', '--raw'], ['host', '--timeout', '0'], ['host', '--delay', '60001'],
    ['host', '65536'],
  ]) assert.throws(() => parseArgs(args), undefined, JSON.stringify(args));
  assert.throws(() => buildPylonRequest(2, 0x42, 0x25));
  assert.throws(() => buildPylonRequest(2, 0x45));
});

test('decodes PYLON multi-module units and 24-bit capacities, not PACE units', () => {
  const data = decodePayload(Buffer.from(payload(0x42), 'hex'), 0x42, 0xff);
  assert.equal(data.modules.length, 2);
  assert.equal(data.all, true);
  assert.deepEqual(data.modules[0], {
    cells: [3.3, 3.3], temperatures: [23], current: -2.6, voltage: 6.6,
    remaining: 33.5, total: 50, cycles: 31,
  });
  const extended = decodePayload(Buffer.from(`1101${extendedModule}`, 'hex'), 0x42, 1);
  assert.equal(extended.all, false);
  assert.equal(extended.modules[0].remaining, 100);
  assert.equal(extended.modules[0].total, 200);
  const warnings = decodePayload(Buffer.from(payload(0x44), 'hex'), 0x44, 0xff);
  assert.deepEqual(warnings.modules[1], { cells: [0, 1], temperatures: [2], status: Array(8).fill(0) });
});

test('rejects short, mismatched and unfamiliar layouts without partial data', () => {
  const valid = Buffer.from(`1101${legacyModule}`, 'hex');
  for (let size = 0; size < valid.length; size++) {
    assert.throws(() => decodePayload(valid.subarray(0, size), 0x42, 1));
  }
  assert.throws(() => decodePayload(valid, 0x42, 2), /selector/);
  assert.throws(() => decodePayload(Buffer.from('1100', 'hex'), 0x42, 0xff), /module count/);
  assert.throws(() => decodePayload(Buffer.from('110100', 'hex'), 0x42, 1), /cell count/);
  assert.throws(() => decodePayload(Buffer.concat([valid, Buffer.from([0])]), 0x42, 1), /extension/);
  const unknownItems = Buffer.from(valid);
  unknownItems[unknownItems.length - 5] = 3;
  assert.throws(() => decodePayload(unknownItems, 0x42, 1), /user-defined/);
});

test('decoder validates checksum, version, destination and supports fragmented/coalesced frames', () => {
  const responses = [];
  const decoder = new PylonDecoder({ onResponse: (reply, command) => responses.push([reply.address, command]) });
  const request = buildPylonRequest(2, 0x42);
  decoder.push(request);
  assert.match(decoder.push(Buffer.from(frame(3, 0, payload(0x42)))), /unmatched/);
  assert.match(decoder.push(Buffer.from(frame(2, 0, payload(0x42), 0x25))), /unsupported/);
  const reply = frame(2, 0, payload(0x42));
  const corrupted = reply.slice(0, -5) + '0000\r';
  assert.match(decoder.push(Buffer.from(corrupted)), /checksum mismatch/);
  assert.deepEqual(responses, []);
  assert.equal(decoder.push(Buffer.from(reply.slice(0, 12))), '');
  const output = decoder.push(Buffer.from(reply.slice(12) + reply));
  assert.match(output, /current=-2.6 A; capacity=33.500\/50.000 Ah/);
  assert.match(output, /Module 2 \(reply order, not battery address\)/);
  assert.match(output, /unmatched/);
  assert.deepEqual(responses, [[2, 0x42]]);
});

test('one sweep reads all-module measurements and warnings without TCP echo', { timeout: 10000 }, async (t) => {
  const commands = [];
  const port = await bridge(t, (request, socket) => {
    const command = parseInt(request.slice(7, 9), 16);
    commands.push(command);
    assert.equal(request, buildPylonRequest(2, command).toString());
    const reply = frame(2, 0, payload(command));
    socket.write(reply.slice(0, 8));
    setTimeout(() => socket.write(reply.slice(8)), 5);
  });
  const result = await run(t, ['127.0.0.1', port, '--once', '--raw', '--delay', '1']).result;
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(commands, [0x42, 0x44]);
  assert.match(result.stdout, /TX "~20024642E002FFFD09\\r"/);
  assert.match(result.stdout, /RX /);
  assert.match(result.stdout, /calculated SOC=67.0%/);
  assert.match(result.stdout, /Status\/alarm registers \(raw\)/);
  assert.match(result.stderr, /only polling master/);
});

test('fixed destination polls four individual selectors', { timeout: 10000 }, async (t) => {
  const selectors = [];
  const port = await bridge(t, (request, socket) => {
    const command = parseInt(request.slice(7, 9), 16);
    const selector = parseInt(request.slice(13, 15), 16);
    selectors.push(selector);
    assert.equal(request, buildPylonRequest(0, command, 0x20, selector).toString());
    socket.write(frame(0, 0, payload(command, selector)));
  });
  const result = await run(t, ['127.0.0.1', port, '--destination', '0', '--addresses', '1,2,3,4', '--once', '--delay', '1']).result;
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(selectors, [1, 1, 2, 2, 3, 3, 4, 4]);
  assert.match(result.stdout, /Battery selector 1/);
  assert.match(result.stdout, /Battery selector 4/);
});

test('timeouts, rejections and unsupported payloads fail one sweep', { timeout: 10000 }, async (t) => {
  for (const mode of ['timeout', 'rejected', 'payload', 'checksum']) {
    await t.test(mode, async (t) => {
      const port = await bridge(t, (request, socket) => {
        const command = parseInt(request.slice(7, 9), 16);
        if (mode === 'timeout') return;
        const reply = mode === 'rejected' ? frame(2, 4)
          : mode === 'payload' ? frame(2, 0, '0000') : frame(2, 0, payload(command));
        socket.write(mode === 'checksum' ? reply.slice(0, -5) + '0000\r' : reply);
      });
      const result = await run(t, ['127.0.0.1', port, '--once', '--timeout', '75', '--delay', '1']).result;
      assert.equal(result.code, 1, result.stdout);
      assert.match(result.stderr, mode === 'rejected' ? /rejected/ : mode === 'payload' ? /Data error/ : /no response/);
    });
  }
});

test('help and invalid CLI arguments do not connect', { timeout: 5000 }, async (t) => {
  const help = await run(t, ['--help']).result;
  assert.equal(help.code, 0);
  assert.match(help.stdout, /PYLON/);
  assert.match(help.stdout, /default: FF/);
  const invalid = await run(t, ['host', '--protocol', '25']).result;
  assert.equal(invalid.code, 1);
  assert.match(invalid.stderr, /Invalid arguments/);
});

test('remote disconnect and Ctrl-C have explicit exit codes', { timeout: 10000 }, async (t) => {
  await t.test('disconnect', async (t) => {
    const port = await bridge(t, (_request, socket) => socket.end());
    const result = await run(t, ['127.0.0.1', port, '--once']).result;
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Disconnected/);
  });
  await t.test('interrupt', async (t) => {
    let child;
    const port = await bridge(t, () => child.send('interrupt'));
    const running = run(t, ['127.0.0.1', port], true);
    child = running.child;
    const result = await running.result;
    assert.equal(result.code, 130);
    assert.match(result.stderr, /Stopped/);
  });
});
