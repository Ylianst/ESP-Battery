'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const net = require('node:net');
const path = require('node:path');
const { test } = require('node:test');
const { buildReadRequest, crc16, formatRegisters, parseArgs, RtuDecoder } = require('./rs485-modbus-poll');

const script = path.join(__dirname, 'rs485-modbus-poll.js');

function withCRC(data) {
  const checksum = Buffer.alloc(2);
  checksum.writeUInt16LE(crc16(data));
  return Buffer.concat([data, checksum]);
}

function words(values) {
  const data = Buffer.alloc(values.length * 2);
  values.forEach((value, index) => data.writeUInt16BE(value & 65535, index * 2));
  return data;
}

function response(address, values) {
  const data = words(values);
  return withCRC(Buffer.concat([Buffer.from([address, 3, data.length]), data]));
}

function sample(start) {
  if (start === 0) return [-218, 5355, 71, 99, 7118, 10000, 10000, 12];
  if (start === 9) return [0x0001, 0x0002, 0x0400, 0x8001];
  return [...Array.from({ length: 16 }, (_, index) => 3340 + index), -55, 175, 180, 185, 200, 190];
}

function capture() {
  const frames = [];
  const diagnostics = [];
  const decoder = new RtuDecoder({
    onFrame: (frame) => frames.push(frame),
    onDiagnostic: (message) => diagnostics.push(message),
  });
  return { decoder, frames, diagnostics };
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
    let buffer = Buffer.alloc(0);
    socket.on('data', (data) => {
      buffer = Buffer.concat([buffer, data]);
      while (buffer.length >= 8) {
        const request = buffer.subarray(0, 8);
        buffer = buffer.subarray(8);
        assert.equal(request[1], 3, 'must only read holding registers');
        assert.equal(request.readUInt16LE(6), crc16(request.subarray(0, 6)));
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

test('CRC and RTU requests match known vectors with little-endian CRC and no TCP header', () => {
  assert.equal(crc16(Buffer.from('123456789')), 0x4b37);
  assert.equal(buildReadRequest(1, 0, 8).toString('hex'), '010300000008440c');
  assert.equal(buildReadRequest(1, 0, 10).toString('hex'), '01030000000ac5cd');
  for (const args of [
    [0, 0, 8], [248, 0, 8], [1.5, 0, 8], [1, -1, 8], [1, 65536, 1],
    [1, 65535, 2], [1, 0, 0], [1, 0, 126], [1, 0, 1.5], [1, NaN, 1],
  ]) {
    assert.throws(() => buildReadRequest(...args));
  }
  assert.equal(buildReadRequest(247, 65535, 1).length, 8);
});

test('CLI defaults, address range, timeouts and read-only options are validated', () => {
  assert.deepEqual(parseArgs(['recliner.local']), {
    addresses: [1, 2, 3, 4], timeout: 2000, delay: 250, once: false, raw: false,
    host: 'recliner.local', port: 1234,
  });
  assert.deepEqual(parseArgs(['host', '2345', '--addresses', '247,1',
    '--timeout', '8000', '--delay', '5', '--once', '--raw']), {
    addresses: [247, 1], timeout: 8000, delay: 5, once: true, raw: true,
    host: 'host', port: 2345,
  });
  for (const args of [
    [], [' '], ['host', '0'], ['host', '65536'], ['host', 'abc'], ['host', '1.5'],
    ['host', '1234', 'extra'], ['host', '--unknown'], ['host', '--write', '1'],
    ['host', '--raw', '--raw'], ['host', '--addresses'], ['host', '--addresses', '0'],
    ['host', '--addresses', '248'], ['host', '--addresses', 'FF'], ['host', '--addresses', '1,1'],
    ['host', '--addresses', '1,,2'], ['host', '--addresses', '-1'],
    ['host', '--timeout', '0'], ['host', '--timeout', '60001'], ['host', '--timeout', '1.5'],
    ['host', '--delay', '4'], ['host', '--delay', '60001'], ['host', '--delay'],
  ]) {
    assert.throws(() => parseArgs(args), undefined, JSON.stringify(args));
  }
});

test('RTU responses reassemble correctly at every TCP split boundary', () => {
  const reply = response(1, sample(0));
  for (let split = 1; split < reply.length; split++) {
    const { decoder, frames, diagnostics } = capture();
    decoder.expect(buildReadRequest(1, 0, 8));
    decoder.push(reply.subarray(0, split));
    assert.equal(frames.length, 0, `split ${split}`);
    decoder.push(reply.subarray(split));
    assert.equal(frames.length, 1, `split ${split}`);
    assert.equal(frames[0].address, 1);
    assert.equal(frames[0].exception, undefined);
    assert.deepEqual(frames[0].data, words(sample(0)));
    assert.deepEqual(diagnostics, []);
  }
});

test('coalesced frames and split request echoes are handled without interpreting echo as a reply', () => {
  const { decoder, frames, diagnostics } = capture();
  const request = buildReadRequest(1, 0, 8);
  decoder.expect(request);
  decoder.push(request.subarray(0, 3));
  assert.equal(frames.length, 0);
  decoder.push(Buffer.concat([
    request.subarray(3), response(1, sample(0)), withCRC(Buffer.from([2, 0x83, 2])),
  ]));
  assert.equal(frames.length, 2);
  assert.equal(frames[0].data.length, 16);
  assert.equal(frames[1].address, 2);
  assert.equal(frames[1].exception, 2);
  assert.match(diagnostics.join('\n'), /Ignored echoed request/);
});

test('noise, false incomplete headers and bad CRCs do not hide a later valid response', () => {
  const { decoder, frames, diagnostics } = capture();
  const bad = response(1, sample(0));
  bad[bad.length - 1] ^= 1;
  decoder.push(bad);
  assert.equal(frames.length, 0);
  assert.match(diagnostics.join('\n'), /CRC mismatch/);
  decoder.push(Buffer.concat([Buffer.from([0xff, 0, 1, 3, 250]), response(1, sample(0))]));
  assert.equal(frames.length, 1);
  assert.deepEqual(frames[0].data, words(sample(0)));
  assert.match(diagnostics.join('\n'), /Discarded unframed RTU bytes/);
});

test('maximum-length frames work and incomplete/noise buffering stays bounded', () => {
  const { decoder, frames, diagnostics } = capture();
  const reply = response(247, Array(125).fill(0x0301));
  decoder.push(reply.subarray(0, -1));
  assert.equal(frames.length, 0);
  decoder.push(reply.subarray(-1));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].data.length, 250);
  decoder.push(Buffer.alloc(10000, 0xff));
  assert.equal(decoder.buffer.length, 0);
  decoder.push(Buffer.from([1, 3, 16, 0]));
  assert.ok(decoder.buffer.length < 256);
  decoder.expect(buildReadRequest(2, 0, 8));
  assert.match(diagnostics.join('\n'), /Incomplete RTU data: 01 03 10 00/);
  assert.equal(decoder.buffer.length, 0);
});

test('measurement scaling, signed current/temperatures and status registers match the PACE map', () => {
  const basic = formatRegisters(1, 0, words(sample(0)));
  assert.match(basic, /Pack: 53\.55 V; current=-2\.18 A; power=-116\.74 W; SOC=71%; SOH=99%/);
  assert.match(basic, /Capacity: 71\.18\/100\.00 Ah; design=100\.00 Ah; cycles=12/);
  const status = formatRegisters(2, 9, words(sample(9)));
  assert.match(status, /warnings=0x0001; protections=0x0002; status\/fault=0x0400; balance=0x8001/);
  const cells = formatRegisters(3, 15, words(sample(15)));
  assert.match(cells, /Cells \(16, V\): 3\.340, 3\.341/);
  assert.match(cells, /spread=15 mV/);
  assert.match(cells, /battery1=-5\.5; battery2=17\.5/);
  assert.match(cells, /MOSFET=20\.0; environment=19\.0/);
  assert.throws(() => formatRegisters(1, 8, words([0])));
  assert.throws(() => formatRegisters(1, 0, words([0])));
});

test('captured SG48100 PACE-mode replies decode all three Modbus register blocks', () => {
  const { decoder, frames, diagnostics } = capture();
  const captures = [
    [0, '010310000014e3004800641bcb271027100001595a'],
    [9, '010308000000000c0000009687'],
    [15, '01032c0d160d130d110d0f0d0c0d100d100d120d0e0d130d130cfc0d0f0cff0d100d1200b100af00b000af00c600b8ac1a'],
  ];
  for (const [, bytes] of captures) {
    const reply = Buffer.from(bytes, 'hex');
    decoder.push(reply.subarray(0, 8));
    decoder.push(reply.subarray(8));
  }
  assert.equal(frames.length, 3);
  assert.deepEqual(diagnostics, []);
  const output = frames.map((frame, index) => {
    assert.equal(frame.address, 1);
    return formatRegisters(frame.address, captures[index][0], frame.data);
  }).join('');
  assert.match(output, /53\.47 V; current=0\.00 A; power=0\.00 W; SOC=72%; SOH=100%/);
  assert.match(output, /Capacity: 71\.15\/100\.00 Ah/);
  assert.match(output, /status\/fault=0x0C00/);
  assert.match(output, /spread=26 mV/);
  assert.match(output, /battery1=17\.7; battery2=17\.5/);
  assert.match(output, /MOSFET=19\.8; environment=18\.4/);
});

test('CLI help and invalid arguments do not connect', { timeout: 5000 }, async (t) => {
  const help = await run(t, ['--help']).result;
  assert.equal(help.code, 0);
  assert.match(help.stdout, /NOT Modbus TCP or ASCII PACE/);
  assert.match(help.stdout, /default: 1234/);
  const invalid = await run(t, ['host', '--addresses', '0']).result;
  assert.equal(invalid.code, 1);
  assert.match(invalid.stderr, /no broadcast reads/);
});

test('one sweep reads all three blocks for all four slaves and decodes fragmented replies', { timeout: 10000 }, async (t) => {
  const received = [];
  let waiting = false;
  const port = await bridge(t, (request, socket) => {
    assert.equal(waiting, false, 'must keep only one request outstanding');
    waiting = true;
    const address = request[0];
    const start = request.readUInt16BE(2);
    const count = request.readUInt16BE(4);
    received.push([address, start, count]);
    const reply = response(address, sample(start));
    socket.write(reply.subarray(0, 3));
    setTimeout(() => {
      waiting = false;
      socket.write(reply.subarray(3));
    }, 10);
  });
  const output = await run(t, ['127.0.0.1', port, '--once', '--delay', '5', '--raw']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.deepEqual(received, [1, 2, 3, 4].flatMap((address) =>
    [[address, 0, 8], [address, 9, 4], [address, 15, 22]]));
  for (const address of [1, 2, 3, 4]) {
    assert.match(output.stdout, new RegExp(`Battery ${address}: holding 0-7; CRC OK`));
    assert.match(output.stdout, new RegExp(`Battery ${address}: holding 9-12; CRC OK`));
    assert.match(output.stdout, new RegExp(`Battery ${address}: holding 15-36; CRC OK`));
  }
  assert.match(output.stdout, /TX 01 03 00 00 00 08 44 0c/);
  assert.match(output.stdout, /RX 01 03 10/);
  assert.doesNotMatch(output.stderr, /mismatch|Incomplete|Discarded|no Modbus response/);
});

test('echo, wrong slaves, wrong byte counts and CRC errors do not complete requests', { timeout: 5000 }, async (t) => {
  let waiting = false;
  let count = 0;
  const port = await bridge(t, (request, socket) => {
    assert.equal(waiting, false);
    waiting = true;
    count++;
    const start = request.readUInt16BE(2);
    const values = sample(start);
    const corrupt = response(1, values);
    corrupt[corrupt.length - 1] ^= 1;
    socket.write(Buffer.concat([request, response(2, values), response(1, [1]), corrupt]));
    setTimeout(() => {
      waiting = false;
      socket.write(response(1, values));
    }, 30);
  });
  const output = await run(t, ['127.0.0.1', port, '--addresses', '1',
    '--once', '--delay', '5']).result;
  assert.equal(output.code, 0, output.stderr);
  assert.equal(count, 3);
  assert.match(output.stderr, /Ignored echoed request/);
  assert.match(output.stderr, /Unexpected Modbus reply from slave 2/);
  assert.match(output.stderr, /unexpected byte count 2/);
  assert.match(output.stderr, /CRC mismatch/);
  assert.doesNotMatch(output.stderr, /no Modbus response/);
});

test('Modbus exceptions advance the sweep but make --once fail', { timeout: 5000 }, async (t) => {
  let count = 0;
  const port = await bridge(t, (request, socket) => {
    count++;
    socket.write(withCRC(Buffer.from([request[0], 0x83, 2])));
  });
  const output = await run(t, ['127.0.0.1', port, '--addresses', '1', '--once', '--delay', '5']).result;
  assert.equal(output.code, 1);
  assert.equal(count, 3);
  assert.match(output.stderr, /Modbus exception 0x02 \(Illegal data address\)/);
  assert.doesNotMatch(output.stderr, /no Modbus response/);
  assert.doesNotMatch(output.stdout, /CRC OK|Pack:/);
});

test('missing replies time out each block with a failing one-sweep exit code', { timeout: 5000 }, async (t) => {
  let count = 0;
  const port = await bridge(t, () => count++);
  const output = await run(t, ['127.0.0.1', port, '--addresses', '1',
    '--once', '--timeout', '25', '--delay', '5']).result;
  assert.equal(output.code, 1);
  assert.equal(count, 3);
  assert.match(output.stderr, /holding 0-7: no Modbus response within 25 ms/);
  assert.match(output.stderr, /holding 9-12: no Modbus response/);
  assert.match(output.stderr, /holding 15-36: no Modbus response/);
});

test('continuous polling starts another sweep and Ctrl-C cancels pending work', { timeout: 5000 }, async (t) => {
  let count = 0;
  let child;
  const port = await bridge(t, (request, socket) => {
    count++;
    if (count === 4) child.send('SIGINT');
    else socket.write(response(1, sample(request.readUInt16BE(2))));
  });
  const running = run(t, ['127.0.0.1', port, '--addresses', '1', '--delay', '5'], true);
  child = running.child;
  const output = await running.result;
  assert.equal(output.code, 130);
  assert.equal(count, 4);
  assert.match(output.stderr, /Stopped/);
});

test('remote disconnect fails and reports an incomplete reply', { timeout: 5000 }, async (t) => {
  const port = await bridge(t, (request, socket) => socket.end(Buffer.from([1, 3, 16, 0])));
  const output = await run(t, ['127.0.0.1', port]).result;
  assert.equal(output.code, 1);
  assert.match(output.stderr, /Incomplete RTU data/);
  assert.match(output.stderr, /Disconnected/);
});

test('connection errors fail without leaving polling timers running', { timeout: 5000 }, async (t) => {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = String(server.address().port);
  await new Promise((resolve) => server.close(resolve));
  const output = await run(t, ['127.0.0.1', port]).result;
  assert.equal(output.code, 1);
  assert.match(output.stderr, /Connection error:/);
});
