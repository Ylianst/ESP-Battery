'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const net = require('node:net');
const path = require('node:path');
const { test } = require('node:test');
const { buildReadRequest, parseArgs } = require('./rs485-poll');
const { CommandDecoder } = require('./rs485-decoder');

const script = path.join(__dirname, 'rs485-poll.js');

function frame(address, code, payload = '', protocol = 0x25) {
  const byte = (value) => value.toString(16).toUpperCase().padStart(2, '0');
  const size = payload.length;
  const check = (-(size + (size >> 4) + (size >> 8))) & 15;
  const length = ((check << 12) | size).toString(16).toUpperCase().padStart(4, '0');
  const body = `${byte(protocol)}${byte(address)}46${byte(code)}${length}${payload}`;
  const sum = Array.from(body).reduce((total, char) => total + char.charCodeAt(0), 0);
  return `~${body}${((-sum) & 65535).toString(16).toUpperCase().padStart(4, '0')}\r`;
}

function run(t, args, simulateInterrupt = false) {
  const bootstrap = `
    const { poll, parseArgs } = require(${JSON.stringify(script)});
    poll(parseArgs(process.argv.slice(1)));
    process.once('message', () => {
      process.disconnect();
      process.emit('SIGINT');
    });
  `;
  const child = simulateInterrupt
    ? spawn(process.execPath, ['-e', bootstrap, ...args], { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] })
    : spawn(process.execPath, [script, ...args]);
  t.after(() => child.kill());
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (data) => { stdout += data; });
  child.stderr.on('data', (data) => { stderr += data; });
  const result = once(child, 'close').then(([code]) => ({ code, stdout, stderr }));
  return { child, result };
}

async function bridge(t, onRequest) {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
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

test('builds exact captured read frames and valid frames for batteries 1-4', () => {
  assert.equal(buildReadRequest(2, 0x42).toString(), '~25024642E00202FD2E\r');
  assert.equal(buildReadRequest(2, 0x44).toString(), '~25024644E00202FD2C\r');
  const decoder = new CommandDecoder();
  for (const address of [1, 2, 3, 4]) {
    for (const command of [0x42, 0x44]) {
      const request = buildReadRequest(address, command);
      assert.equal(request.toString(), frame(address, command, `0${address}`));
      assert.match(decoder.push(request), new RegExp(`Battery ${address} .*REQUEST .*checksum OK`));
    }
  }
  for (const address of [16, -1, 1.5, NaN]) {
    assert.throws(() => buildReadRequest(address, 0x42));
  }
  assert.throws(() => buildReadRequest(1, 0x45));
  assert.equal(buildReadRequest(1, 0x42, 0x20).toString(), frame(1, 0x42, '01', 0x20));
  assert.throws(() => buildReadRequest(1, 0x42, 0x21));
  assert.equal(buildReadRequest(1, 0x42, 0x25, 0xff).toString(), '~25014642E002FFFD05\r');
  assert.equal(buildReadRequest(1, 0x44, 0x25, 0xff).toString(), frame(1, 0x44, 'FF'));
  assert.equal(buildReadRequest(2, 0x42, 0x25, 0xff).toString(), frame(2, 0x42, 'FF'));
  assert.equal(buildReadRequest(1, 0x42, 0x25, 2).toString(), frame(1, 0x42, '02'));
  assert.throws(() => buildReadRequest(1, 0x42, 0x25, NaN));
  assert.throws(() => buildReadRequest(0, 0x42, 0x25, 16));
  assert.throws(() => buildReadRequest(0, 0x42, 0x25, -1));
  assert.throws(() => buildReadRequest(0, 0x42, 0x25, 1.5));
  assert.equal(buildReadRequest(0, 0x42).toString(), frame(0, 0x42, '00'));
  assert.equal(buildReadRequest(0, 0x44, 0x20).toString(), frame(0, 0x44, '00', 0x20));
  assert.equal(buildReadRequest(0, 0x42, 0x25, 1).toString(), '~25004642E00201FD31\r');
  assert.equal(buildReadRequest(0, 0x42, 0x25, 0xff).toString(), '~25004642E002FFFD06\r');
});

test('parses defaults and rejects invalid or duplicate options', () => {
  assert.deepEqual(parseArgs(['recliner.local']), {
    host: 'recliner.local', port: 1234, addresses: [1, 2, 3, 4], protocol: 0x25,
    timeout: 2000, delay: 250, once: false, raw: false, masterFF: false,
  });
  assert.deepEqual(parseArgs(['host', '2345', '--addresses', '4,1', '--timeout', '5000',
    '--delay', '100', '--once', '--raw', '--protocol', '20', '--master-ff']), {
    host: 'host', port: 2345, addresses: [4, 1], protocol: 0x20, timeout: 5000, delay: 100, once: true, raw: true, masterFF: true,
  });
  assert.deepEqual(parseArgs(['host', '--addresses', '0']).addresses, [0]);
  const relay = parseArgs(['host', '--destination', '0', '--addresses', '1,2,3,4,ff', '--timeout', '8000']);
  assert.equal(relay.destination, 0);
  assert.deepEqual(relay.addresses, [1, 2, 3, 4, 255]);
  assert.equal(relay.timeout, 8000);
  for (const args of [
    [], [' '], ['host', '0'], ['host', '65536'], ['host', 'abc'], ['host', '1.5'],
    ['host', '1234', 'extra'], ['host', '--unknown'], ['host', '--raw', '--raw'],
    ['host', '--addresses'], ['host', '--addresses', '1,1'], ['host', '--addresses', '0,0'],
    ['host', '--addresses', '16'], ['host', '--addresses', '1,,2'],
    ['host', '--timeout', '0'], ['host', '--timeout', '60001'], ['host', '--timeout', '1.5'],
    ['host', '--delay', '60001'], ['host', '--delay'], ['host', '--delay', '-1'],
    ['host', '--protocol'], ['host', '--protocol', '21'],
    ['host', '--master-ff', '--master-ff'],
    ['host', '--destination'], ['host', '--destination', '16'], ['host', '--destination', '-1'],
    ['host', '--destination', '1.5'], ['host', '--destination', 'FF'],
    ['host', '--addresses', 'FF'], ['host', '--destination', '0', '--addresses', '255'],
    ['host', '--destination', '0', '--addresses', 'FF,ff'],
    ['host', '--destination', '0', '--master-ff'],
  ]) {
    assert.throws(() => parseArgs(args), undefined, JSON.stringify(args));
  }
});

test('help and invalid CLI arguments do not connect', { timeout: 5000 }, async (t) => {
  const help = await run(t, ['--help']).result;
  assert.equal(help.code, 0);
  assert.match(help.stdout, /default: 1,2,3,4/);
  assert.match(help.stdout, /no other polling master/);
  const invalid = await run(t, ['host', '--timeout', '60001']).result;
  assert.equal(invalid.code, 1);
  assert.match(invalid.stderr, /Invalid arguments/);
});

test('one sweep decodes all four batteries without relying on bridge echo', { timeout: 10000 }, async (t) => {
  const received = [];
  const port = await bridge(t, (request, socket) => {
    const address = parseInt(request.slice(3, 5), 16);
    const command = parseInt(request.slice(7, 9), 16);
    received.push([address, command]);
    assert.equal(request, buildReadRequest(address, command).toString());
    const payload = command === 0x42
      ? `000${address}010D16010B4600DA0D1619FA0227100001`
      : `000${address}01000100${'00'.repeat(12)}`;
    const reply = frame(address, 0, payload);
    socket.write(reply.slice(0, 8));
    setTimeout(() => socket.write(reply.slice(8)), 15);
  });
  const output = await run(t, ['127.0.0.1', port, '--once', '--delay', '1']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.deepEqual(received, [1, 2, 3, 4].flatMap((address) => [[address, 0x42], [address, 0x44]]));
  for (const address of [1, 2, 3, 4]) {
    assert.match(output.stdout, new RegExp(`Battery ${address} .*RESPONSE Read measurements .*OK`));
    assert.match(output.stdout, new RegExp(`Battery ${address} .*RESPONSE Read warnings/status .*OK`));
  }
  assert.match(output.stdout, /Pack: 3\.350 V; current=2\.18 A/);
  assert.match(output.stdout, /Temperatures \(1, C\): 15\.5/);
  assert.match(output.stdout, /Status registers:/);
  assert.doesNotMatch(output.stdout, /Invalid|truncated|unmatched|Unrecognized/);
});

test('echo, corrupt frames and other addresses do not finish the pending request', { timeout: 5000 }, async (t) => {
  let waiting = false;
  let count = 0;
  const port = await bridge(t, (request, socket) => {
    assert.equal(waiting, false, 'must wait for a valid reply');
    waiting = true;
    count++;
    socket.write(request + frame(4, 0) + '~25024600E00202FD35\r');
    setTimeout(() => {
      waiting = false;
      socket.write(frame(2, 0));
    }, 40);
  });
  const output = await run(t, ['127.0.0.1', port, '--addresses', '2',
    '--once', '--delay', '1', '--raw']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.equal(count, 2);
  assert.match(output.stdout, /TX "~25024642E00202FD2E\\r"/);
  assert.match(output.stdout, /RX /);
  assert.match(output.stdout, /frame checksum mismatch/);
});

test('master FF mode queries INFO FF,02,03,04 without broadcasting', { timeout: 5000 }, async (t) => {
  const received = [];
  const port = await bridge(t, (request, socket) => {
    const address = parseInt(request.slice(3, 5), 16);
    const command = parseInt(request.slice(7, 9), 16);
    const packAddress = address === 1 ? 0xff : address;
    assert.equal(request, buildReadRequest(address, command, 0x25, packAddress).toString());
    received.push([address, command, request.slice(13, 15)]);
    socket.write(frame(address, 0, '', 0x20));
  });
  const output = await run(t, ['127.0.0.1', port, '--master-ff', '--once',
    '--delay', '1', '--raw']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.deepEqual(received, [1, 2, 3, 4].flatMap((address) =>
    [0x42, 0x44].map((command) => [address, command, address === 1 ? 'FF' : `0${address}`])));
  assert.match(output.stdout, /TX "~25014642E002FFFD05\\r"/);
  assert.match(output.stdout, /Battery 1 .*RESPONSE Read measurements .*OK/);
  assert.match(output.stdout, /Battery 1 .*RESPONSE Read warnings\/status .*OK/);
  assert.match(output.stderr, /destination remains 01/);
  assert.doesNotMatch(output.stderr, /no response/);
});

test('address zero uses destination 00 and INFO 00 even with master FF enabled', { timeout: 5000 }, async (t) => {
  const received = [];
  const port = await bridge(t, (request, socket) => {
    received.push(request);
    socket.write(frame(0, 0, '', 0x20));
  });
  const output = await run(t, ['127.0.0.1', port, '--addresses', '0',
    '--master-ff', '--once', '--delay', '1']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.deepEqual(received, [frame(0, 0x42, '00'), frame(0, 0x44, '00')]);
  assert.match(output.stdout, /Battery 0 .*RESPONSE Read measurements .*OK/);
  assert.match(output.stdout, /Battery 0 .*RESPONSE Read warnings\/status .*OK/);
  assert.doesNotMatch(output.stderr, /Address 1 requests|no response/);
});

test('fixed destination 00 queries packs 1-4 and FF with independent INFO selectors', { timeout: 5000 }, async (t) => {
  const received = [];
  const port = await bridge(t, (request, socket) => {
    const command = parseInt(request.slice(7, 9), 16);
    const selector = request.slice(13, 15);
    received.push([request.slice(3, 5), command, selector]);
    assert.equal(request, frame(0, command, selector));
    const payload = selector === 'FF' ? '0000' : command === 0x42
      ? `00${selector}010D16010B4600DA0D1619FA0227100001`
      : `00${selector}01000100${'00'.repeat(8)}`;
    socket.write(frame(0, 0, payload, 0x20));
  });
  const output = await run(t, ['127.0.0.1', port, '--destination', '0',
    '--addresses', '1,2,3,4,FF', '--timeout', '8000', '--once', '--delay', '1', '--raw']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.deepEqual(received, ['01', '02', '03', '04', 'FF'].flatMap((selector) =>
    [0x42, 0x44].map((command) => ['00', command, selector])));
  assert.equal((output.stdout.match(/Pack: 3\.350 V/g) || []).length, 4);
  assert.equal((output.stdout.match(/Status registers:/g) || []).length, 4);
  assert.match(output.stdout, /All-pack query; payload=0000/);
  assert.doesNotMatch(output.stdout, /unmatched|Unrecognized|Invalid|truncated/);
  assert.match(output.stderr, /Fixed frame destination 0/);
});

test('timeouts advance the sweep and make --once fail', { timeout: 5000 }, async (t) => {
  const received = [];
  const port = await bridge(t, (request) => received.push(request));
  const output = await run(t, ['127.0.0.1', port, '--addresses', '1',
    '--once', '--timeout', '30', '--delay', '1']).result;
  assert.equal(output.code, 1);
  assert.equal(received.length, 2);
  assert.match(output.stderr, /Battery 1: no response to 0x42 within 30 ms/);
  assert.match(output.stderr, /Battery 1: no response to 0x44 within 30 ms/);
});

test('protocol 20 replies complete requests for either request protocol', { timeout: 5000 }, async (t) => {
  const versions = [];
  const port = await bridge(t, (request, socket) => {
    versions.push(request.slice(1, 3));
    socket.write(frame(1, 0, '', 0x20));
  });
  for (const protocol of ['25', '20']) {
    const output = await run(t, ['127.0.0.1', port, '--addresses', '1',
      '--once', '--delay', '1', '--protocol', protocol]).result;
    assert.equal(output.code, 0, output.stderr);
    assert.match(output.stdout, /protocol 20.*RESPONSE Read measurements .*OK/);
    assert.doesNotMatch(output.stderr, /no response/);
  }
  assert.deepEqual(versions, ['25', '25', '20', '20']);
});

test('nonzero and empty address-error replies are decoded and make --once fail', { timeout: 5000 }, async (t) => {
  let count = 0;
  const port = await bridge(t, (request, socket) => socket.write(frame(1, count++ ? 0x90 : 0x04)));
  const output = await run(t, ['127.0.0.1', port, '--addresses', '1', '--once', '--delay', '1']).result;
  assert.equal(output.code, 1);
  assert.equal(count, 2);
  assert.match(output.stdout, /RESPONSE Read measurements .*Invalid command/);
  assert.match(output.stdout, /RESPONSE Read warnings\/status .*Address error/);
  assert.doesNotMatch(output.stderr, /no response/);
});

test('continuous mode starts another sweep and Ctrl-C cancels pending timers', { timeout: 5000 }, async (t) => {
  let count = 0;
  let child;
  const port = await bridge(t, (request, socket) => {
    count++;
    if (count === 3) child.send('SIGINT');
    else socket.write(frame(1, 0));
  });
  const running = run(t, ['127.0.0.1', port, '--addresses', '1', '--delay', '1'], true);
  child = running.child;
  const output = await running.result;
  assert.equal(output.code, 130);
  assert.equal(count, 3);
  assert.match(output.stderr, /Stopped/);
});

test('remote disconnect fails and cancels polling timers', { timeout: 5000 }, async (t) => {
  const port = await bridge(t, (request, socket) => socket.end());
  const output = await run(t, ['127.0.0.1', port]).result;
  assert.equal(output.code, 1);
  assert.match(output.stderr, /Disconnected/);
});

test('connection errors produce a failing exit code', { timeout: 5000 }, async (t) => {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = String(server.address().port);
  await new Promise((resolve) => server.close(resolve));
  const output = await run(t, ['127.0.0.1', port]).result;
  assert.equal(output.code, 1);
  assert.match(output.stderr, /Connection error:/);
});
