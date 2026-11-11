'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { CommandDecoder } = require('./rs485-decoder');

function frame(code, payload = '', address = 2, version = 0x25, type = 0x46) {
  const byte = (value) => value.toString(16).toUpperCase().padStart(2, '0');
  const size = payload.length;
  const check = (-(size + (size >> 4) + (size >> 8))) & 15;
  const length = ((check << 12) | size).toString(16).toUpperCase().padStart(4, '0');
  const body = byte(version) + byte(address) + byte(type) + byte(code) + length + payload;
  const sum = Array.from(body).reduce((total, char) => total + char.charCodeAt(0), 0);
  return `~${body}${((-sum) & 65535).toString(16).toUpperCase().padStart(4, '0')}\r`;
}

function decode(decoder, text) {
  return decoder.push(Buffer.from(text, 'latin1'));
}

function analogPayload(current = 218) {
  const cells = [3349, 3350, 3349, 3350, 3352, 3349, 3349, 3341,
    3351, 3353, 3350, 3352, 3349, 3343, 3348, 3351];
  const temperatures = [2886, 2886, 2880, 2882, 2904, 2896];
  const payload = Buffer.alloc(3 + cells.length * 2 + 1 + temperatures.length * 2 + 11);
  payload[1] = 2;
  payload[2] = cells.length;
  let offset = 3;
  for (const cell of cells) {
    payload.writeUInt16BE(cell, offset);
    offset += 2;
  }
  payload[offset++] = temperatures.length;
  for (const temperature of temperatures) {
    payload.writeUInt16BE(temperature, offset);
    offset += 2;
  }
  payload.writeInt16BE(current, offset);
  payload.writeUInt16BE(53586, offset + 2);
  payload.writeUInt16BE(6650, offset + 4);
  payload[offset + 6] = 2;
  payload.writeUInt16BE(10000, offset + 7);
  payload.writeUInt16BE(1, offset + 9);
  return payload.toString('hex').toUpperCase();
}

test('decodes known captured requests and validates both checksums', () => {
  const decoder = new CommandDecoder();
  assert.match(decode(decoder, '~250246900000FDA4\r'), /REQUEST Read pack number.*checksum OK/);
  assert.match(decode(decoder, '~25024642E00202FD2E\r'), /REQUEST Read measurements.*payload=02/);
  assert.match(decode(decoder, '~25024644E00202FD2C\r'), /REQUEST Read warnings\/status/);
  assert.match(decode(decoder, '~250246900000FDA5\r'), /frame checksum mismatch/);
  assert.match(decode(decoder, '~25024642F00202FD2E\r'), /length checksum mismatch/);
});

test('reassembles fragmented frames and multiple frames in one chunk', () => {
  const decoder = new CommandDecoder();
  assert.equal(decode(decoder, '~2502'), '');
  const output = decode(decoder, '46900000FDA4\r\n~250346900000FDA3\r');
  assert.match(output, /Battery 2 .*REQUEST Read pack number/);
  assert.match(output, /Battery 3 .*REQUEST Read pack number/);
  assert.doesNotMatch(output, /Invalid|Unframed/);
});

test('matches responses by address and converts measurements to engineering units', () => {
  const decoder = new CommandDecoder();
  decode(decoder, frame(0x42, '02'));
  decode(decoder, frame(0x44, '03', 3));
  const output = decode(decoder, frame(0, analogPayload()));
  assert.match(output, /RESPONSE Read measurements \(0x42\): OK/);
  assert.match(output, /53\.586 V; current=2\.18 A/);
  assert.match(output, /capacity=66\.50\/100\.00 Ah; calculated SOC=66\.5%; cycles=1/);
  assert.match(output, /Cells \(16, V\): 3\.349, 3\.350/);
  assert.match(output, /spread=12 mV/);
  assert.match(output, /Temperatures \(6, C\): 15\.5, 15\.5, 14\.9, 15\.1, 17\.3, 16\.5/);
  assert.match(output, /extra-field marker=0x02; extension=\(empty\)/);
});

test('handles signed current without guessing vendor extension meanings', () => {
  const decoder = new CommandDecoder();
  decode(decoder, frame(0x42, '02'));
  const output = decode(decoder, frame(0, analogPayload(-218) + '2710430000000064'));
  assert.match(output, /current=-2\.18 A/);
  assert.match(output, /extension=2710430000000064/);
});

test('shows warning codes and registers, including nonzero warnings', () => {
  const decoder = new CommandDecoder();
  const payload = Buffer.alloc(38);
  payload[1] = 2;
  payload[2] = 16;
  payload[3] = 1;
  payload[19] = 6;
  payload[20] = 2;
  payload[26] = 1;
  decode(decoder, frame(0x44, '02'));
  const output = decode(decoder, frame(0, payload.toString('hex').toUpperCase()));
  assert.match(output, /RESPONSE Read warnings\/status/);
  assert.match(output, /Cell warning codes \(16\): 1=0x01/);
  assert.match(output, /Temperature warning codes \(6\): 1=0x02/);
  assert.match(output, /charge-current warning=0x01/);
  assert.match(output, /fault=0x00/);
});

test('leaves unmatched, expired, unknown and unsupported messages visible', (t) => {
  const decoder = new CommandDecoder();
  assert.match(decode(decoder, frame(0, '0202')), /RESPONSE unmatched request.*\n  Payload=0202/);
  assert.match(decode(decoder, frame(0xee, '1234')), /REQUEST Unknown command.*payload=1234/);
  assert.match(decode(decoder, frame(0x42, '', 2, 0x21)), /unsupported protocol/);
  assert.match(decode(decoder, frame(0x42, '', 2, 0x25, 0x47)), /unsupported protocol/);
  let now = 10000;
  t.mock.method(Date, 'now', () => now);
  decode(decoder, frame(0x42, '02'));
  now += 5001;
  assert.match(decode(decoder, frame(0, analogPayload())), /RESPONSE unmatched request/);
});

test('reports error replies without decoding them as measurements', () => {
  const decoder = new CommandDecoder();
  decode(decoder, frame(0x42, '02'));
  const output = decode(decoder, frame(2, '1234'));
  assert.match(output, /RESPONSE Read measurements.*Checksum error/);
  assert.match(output, /Payload=1234/);
  assert.doesNotMatch(output, /Pack:/);
});

test('decodes captured protocol 20 replies to protocol 25 requests', () => {
  const decoder = new CommandDecoder();
  decode(decoder, frame(0x42, '02'));
  const analog = '~2002460070720002100D1B0D180D160D140D110D150D140D160D130D180D180D020D140D050D150D17050B600B590B580B5A0B580000D1371BCF0227100001E588\r';
  const output = decode(decoder, analog);
  assert.match(output, /protocol 20.*RESPONSE Read measurements.*OK/);
  assert.match(output, /Pack: 53\.559 V; current=0\.00 A/);
  assert.match(output, /capacity=71\.19\/100\.00 Ah/);
  assert.match(output, /Cells \(16, V\)/);
  assert.match(output, /Temperatures \(5, C\)/);
  decode(decoder, frame(0x44, '02'));
  const status = '~20024600A042000210000000000000000000000000000000000500010101010000000006000000F129\r';
  const warningOutput = decode(decoder, status);
  assert.match(warningOutput, /RESPONSE Read warnings\/status.*OK/);
  assert.match(warningOutput, /Temperature warning codes \(5\): 2=0x01, 3=0x01, 4=0x01, 5=0x01/);
  assert.match(warningOutput, /Status registers: register1=0x00;.*register5=0x06;.*register8=0x00/);
  assert.match(warningOutput, /extension=\(empty\)/);
  assert.doesNotMatch(warningOutput, /Invalid|truncated|Unrecognized/);

  decode(decoder, frame(0x44, '02'));
  const payload = '000210000000000000000000000000000000000500010101010000000006000000';
  assert.match(decode(decoder, frame(0, payload + 'ABCD', 2, 0x20)), /extension=ABCD/);
  decode(decoder, frame(0x44, '02'));
  assert.match(decode(decoder, frame(0, payload.slice(0, -2), 2, 0x20)), /Invalid\/truncated warning data/);
});

test('response callbacks receive validated replies and matched command codes only', () => {
  const replies = [];
  const decoder = new CommandDecoder({
    onResponse: (parsed, command) => replies.push({ parsed, command }),
  });
  decode(decoder, '~250246900000FDA5\r');
  decode(decoder, frame(0x42, '02'));
  assert.equal(replies.length, 0);
  assert.match(decode(decoder, frame(0x90)), /RESPONSE Read measurements.*Address error/);
  assert.equal(replies.length, 1);
  assert.equal(replies[0].command, 0x42);
  assert.equal(replies[0].parsed.code, 0x90);
  assert.equal(replies[0].parsed.address, 2);
  decode(decoder, frame(0));
  assert.equal(replies[1].command, undefined);
});

test('relay replies use the INFO selector rather than the frame destination as pack identity', () => {
  const decoder = new CommandDecoder();
  decode(decoder, frame(0x42, '02', 0));
  const output = decode(decoder, frame(0, analogPayload(), 0, 0x20));
  assert.match(output, /Battery 0 .*RESPONSE Read measurements.*OK/);
  assert.match(output, /53\.586 V; current=2\.18 A/);
  assert.match(output, /pack=0x02/);
  assert.doesNotMatch(output, /Unrecognized/);
  decode(decoder, frame(0x42, 'FF', 0));
  assert.match(decode(decoder, frame(0, analogPayload(), 0, 0x20)),
    /All-pack query; payload=.*multi-pack layout not assumed/);
});

test('active response matching honors long timeouts without changing the passive default', (t) => {
  let now = 10000;
  t.mock.method(Date, 'now', () => now);
  const long = new CommandDecoder({ responseTimeout: 8000 });
  const passive = new CommandDecoder();
  for (const decoder of [long, passive]) decode(decoder, frame(0x42, '02'));
  now += 6000;
  assert.match(decode(long, frame(0, analogPayload())), /RESPONSE Read measurements.*OK/);
  assert.match(decode(passive, frame(0, analogPayload())), /RESPONSE unmatched request/);
  decode(long, frame(0x42, '02'));
  now += 8001;
  assert.match(decode(long, frame(0, analogPayload())), /RESPONSE unmatched request/);
});

test('captured destination-zero replies do not invent pack 1 or aggregate measurements', () => {
  const decoder = new CommandDecoder();
  for (const command of [0x42, 0x44]) {
    decode(decoder, frame(command, '01', 0));
    const output = decode(decoder, '~20004600C0040001FCDC\r');
    assert.match(output, /RESPONSE Read .*OK/);
    assert.match(output, /Unrecognized .* layout; payload=0001/);
    assert.doesNotMatch(output, /Pack:|Status registers:/);
  }
  decode(decoder, frame(0x42, 'FF', 0));
  const payload = '00FF100000000000000000000000000000000000000000000000000000000000000000050AAA0AAA0AAA0AAA0AAA0000000000000200000000';
  const output = decode(decoder, frame(0, payload, 0, 0x20));
  assert.match(output, /All-pack query; payload=00FF10.*multi-pack layout not assumed/);
  assert.doesNotMatch(output, /Pack:|calculated SOC|Cells \(/);
});

test('decodes the observed one-byte pack number without treating it as a pack count', () => {
  const decoder = new CommandDecoder();
  decode(decoder, '~250246900000FDA4\r');
  const output = decode(decoder, '~25024600E00202FD34\r');
  assert.match(output, /RESPONSE Read pack number/);
  assert.match(output, /Pack number\/address field: 2 \(0x02\)/);
});

test('reports malformed and truncated payloads without throwing', () => {
  const decoder = new CommandDecoder();
  for (const code of [0x42, 0x44]) {
    for (const payload of ['00', '000210', '000200', '000201000100']) {
      decode(decoder, frame(code, '02'));
      assert.match(decode(decoder, frame(0, payload)), /Unrecognized|Invalid\/truncated/);
    }
  }
  assert.match(decode(decoder, '~NOTHEX\r'), /invalid ASCII-hex frame/);
  assert.match(decode(decoder, '~25024642E002FD2E\r'), /payload length mismatch/);
});

test('recovers after noise, lost delimiters, and oversized frames', () => {
  const decoder = new CommandDecoder();
  assert.match(decode(decoder, 'noise\x00\r\n'), /Unframed data: noise\\x00/);
  const output = decode(decoder, '~2502~250246900000FDA4\r');
  assert.match(output, /Discarded incomplete frame/);
  assert.match(output, /REQUEST Read pack number/);
  assert.match(decode(decoder, '~' + '0'.repeat(4114)), /exceeded maximum protocol length/);
  decode(decoder, '~2502');
  assert.match(decoder.finish(), /Incomplete frame at shutdown: ~2502/);
  assert.equal(decoder.finish(), '');
});
