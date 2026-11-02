'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const net = require('node:net');
const path = require('node:path');
const { test } = require('node:test');

const script = path.join(__dirname, 'rs485-monitor.js');

function run(args, simulateInterrupt = false) {
  const bootstrap = `
    process.argv.splice(1, 0, ${JSON.stringify(script)});
    require(${JSON.stringify(script)});
    process.once('message', () => {
      process.disconnect();
      process.emit('SIGINT');
    });
  `;
  const child = simulateInterrupt
    ? spawn(process.execPath, ['-e', bootstrap, ...args], {
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    })
    : spawn(process.execPath, [script, ...args]);
  let stdout = Buffer.alloc(0);
  let stderr = '';
  child.stdout.on('data', (data) => { stdout = Buffer.concat([stdout, data]); });
  child.stderr.on('data', (data) => { stderr += data; });
  const result = once(child, 'close').then(([code, signal]) => ({
    code, signal, stdout, stderr,
  }));
  return { child, result };
}

async function bridge(t, onConnection) {
  const server = net.createServer(onConnection);
  const sockets = new Set();
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    return new Promise((resolve) => server.close(resolve));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return String(server.address().port);
}

test('help describes the default port without connecting', async () => {
  const { result } = run(['--help']);
  const output = await result;
  assert.equal(output.code, 0);
  assert.match(output.stdout.toString(), /default: 1234/);
  assert.match(output.stdout.toString(), /--raw\s+Display ASCII/);
  assert.match(output.stdout.toString(), /Decode PACE-style/);
  assert.equal(output.stderr, '');
});

test('rejects missing host, invalid ports and unknown options', async () => {
  for (const args of [
    [], ['localhost', '0'], ['localhost', '65536'],
    ['localhost', '1.5'], ['localhost', 'abc'],
    ['localhost', '--unknown'], ['localhost', '1234', 'extra'],
    ['localhost', '--raw', '--raw'],
    ['localhost', '--hex', '--hex'], ['localhost', '--hex', '--raw'],
  ]) {
    const output = await run(args).result;
    assert.equal(output.code, 1, JSON.stringify(args));
    assert.match(output.stderr, /Invalid arguments/);
  }
});

test('displays binary traffic as hex and reports remote disconnect', { timeout: 5000 }, async (t) => {
  let received = 0;
  const port = await bridge(t, (socket) => {
    socket.on('data', (data) => { received += data.length; });
    socket.end(Buffer.from([0x00, 0x7f, 0x80, 0xff]));
  });
  const { child, result } = run(['127.0.0.1', port, '--hex']);
  t.after(() => child.kill());
  const output = await result;
  assert.equal(output.stdout.toString(), '00 7f 80 ff\n');
  assert.match(output.stderr, /Connected to/);
  assert.match(output.stderr, /Disconnected/);
  assert.equal(output.code, 1);
  assert.equal(received, 0);
});

test('ASCII commands stay on one line across TCP chunks', { timeout: 5000 }, async (t) => {
  let peer;
  const port = await bridge(t, (socket) => {
    peer = socket;
    socket.write('~25024690');
  });
  const { child, result } = run(['127.0.0.1', port, '--raw']);
  t.after(() => child.kill());
  child.stdout.once('data', () => {
    peer.end('0000FDA4\r~250346900000FDA3\r');
  });
  const output = await result;
  assert.equal(output.stdout.toString(), '~250246900000FDA4\n~250346900000FDA3\n');
});

test('ASCII mode handles split CR/LF and escapes nonprintable bytes', { timeout: 5000 }, async (t) => {
  let peer;
  const port = await bridge(t, (socket) => {
    peer = socket;
    socket.write('first\r');
  });
  const { child, result } = run(['127.0.0.1', port, '--raw']);
  t.after(() => child.kill());
  child.stdout.once('data', () => {
    peer.end(Buffer.concat([
      Buffer.from('\nsecond\rthird\n'),
      Buffer.from([0x00, 0x1b, 0x7f, 0x80, 0xff]),
    ]));
  });
  const output = await result;
  assert.equal(output.stdout.toString(), 'first\nsecond\nthird\n\\x00\\x1b\\x7f\\x80\\xff');
});

test('default mode decodes requests split across TCP chunks', { timeout: 5000 }, async (t) => {
  const port = await bridge(t, (socket) => {
    socket.write('~250246');
    socket.end('900000FDA4\r~250346900000FDA3\r');
  });
  const { child, result } = run(['127.0.0.1', port]);
  t.after(() => child.kill());
  const output = await result;
  assert.match(output.stdout.toString(), /Battery 2 .*REQUEST Read pack number/);
  assert.match(output.stdout.toString(), /Battery 3 .*REQUEST Read pack number/);
  assert.doesNotMatch(output.stdout.toString(), /Invalid frame/);
});

test('reports connection errors with a failing exit code', { timeout: 5000 }, async () => {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = String(server.address().port);
  await new Promise((resolve) => server.close(resolve));
  const output = await run(['127.0.0.1', port]).result;
  assert.equal(output.code, 1);
  assert.match(output.stderr, /Connection error:/);
});

test('SIGINT handler closes an idle connection', { timeout: 5000 }, async (t) => {
  const port = await bridge(t, () => {});
  // Emit the signal event in the child because Windows cannot send console Ctrl-C via child.kill.
  const { child, result } = run(['127.0.0.1', port], true);
  t.after(() => child.kill());
  child.stderr.on('data', (data) => {
    if (data.toString().includes('Connected to')) child.send('SIGINT');
  });
  const output = await result;
  assert.equal(output.code, 130);
  assert.match(output.stderr, /Stopped/);
});
