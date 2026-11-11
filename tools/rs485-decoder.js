'use strict';

const commands = new Map([
  [0x42, 'Read measurements'],
  [0x44, 'Read warnings/status'],
  [0x90, 'Read pack number'],
]);

const returnCodes = new Map([
  [0x00, 'OK'],
  [0x01, 'Protocol version error'],
  [0x02, 'Checksum error'],
  [0x03, 'Length checksum error'],
  [0x04, 'Invalid command'],
  [0x05, 'Command format error'],
  [0x06, 'Invalid data'],
  [0x90, 'Address error'],
]);

const hex = (value) => value.toString(16).toUpperCase().padStart(2, '0');
const bytes = (data) => data.toString('hex').toUpperCase() || '(empty)';
const visible = (text) => text.replace(/[^\x20-\x7e]/g,
  (char) => `\\x${hex(char.charCodeAt(0))}`);

function parseFrame(frame) {
  if (!/^~[0-9a-fA-F]{16,}$/.test(frame) || frame.length % 2 !== 1) {
    return { error: 'invalid ASCII-hex frame' };
  }
  const body = frame.slice(1, -4);
  const length = parseInt(body.slice(8, 12), 16);
  const infoLength = length & 0x0fff;
  const lengthChecksum = (-(infoLength + (infoLength >> 4) + (infoLength >> 8))) & 0x0f;
  if ((length >> 12) !== lengthChecksum) {
    return { error: 'length checksum mismatch' };
  }
  if (body.length !== 12 + infoLength || infoLength % 2 !== 0) {
    return { error: 'payload length mismatch' };
  }
  let sum = 0;
  for (const char of body) sum += char.charCodeAt(0);
  if (((-sum) & 0xffff) !== parseInt(frame.slice(-4), 16)) {
    return { error: 'frame checksum mismatch' };
  }
  return {
    version: parseInt(body.slice(0, 2), 16),
    address: parseInt(body.slice(2, 4), 16),
    type: parseInt(body.slice(4, 6), 16),
    code: parseInt(body.slice(6, 8), 16),
    info: Buffer.from(body.slice(12), 'hex'),
  };
}

function measurements(info, address) {
  // The observed SG48100 layout contains one pack, identified by the second byte.
  if (info.length < 3 || info[1] !== address) {
    return '  Unrecognized measurement layout; payload=' + bytes(info);
  }
  let offset = 3;
  const cellCount = info[2];
  if (cellCount < 1 || cellCount > 32 || info.length < offset + cellCount * 2 + 1) {
    return '  Invalid/truncated measurement cell data; payload=' + bytes(info);
  }
  const cells = [];
  for (let i = 0; i < cellCount; i++, offset += 2) {
    cells.push(info.readUInt16BE(offset));
  }
  const tempCount = info[offset++];
  if (tempCount > 16 || info.length < offset + tempCount * 2 + 11) {
    return '  Invalid/truncated measurement data; payload=' + bytes(info);
  }
  const temperatures = [];
  for (let i = 0; i < tempCount; i++, offset += 2) {
    temperatures.push(((info.readUInt16BE(offset) - 2731) / 10).toFixed(1));
  }
  const current = info.readInt16BE(offset) / 100;
  const voltage = info.readUInt16BE(offset + 2) / 1000;
  const remaining = info.readUInt16BE(offset + 4) / 100;
  const extraFields = info[offset + 6];
  const full = info.readUInt16BE(offset + 7) / 100;
  const cycles = info.readUInt16BE(offset + 9);
  offset += 11;
  const soc = full > 0 ? `; calculated SOC=${(remaining / full * 100).toFixed(1)}%` : '';
  return [
    `  Pack: ${voltage.toFixed(3)} V; current=${current.toFixed(2)} A; capacity=${remaining.toFixed(2)}/${full.toFixed(2)} Ah${soc}; cycles=${cycles}`,
    `  Cells (${cellCount}, V): ${cells.map((mv) => (mv / 1000).toFixed(3)).join(', ')}; spread=${Math.max(...cells) - Math.min(...cells)} mV`,
    `  Temperatures (${tempCount}, C): ${temperatures.join(', ') || '(none)'}`,
    `  Vendor fields: flag=0x${hex(info[0])}; pack=0x${hex(info[1])}; extra-field marker=0x${hex(extraFields)}; extension=${bytes(info.subarray(offset))}`,
  ].join('\n');
}

function warnings(info, address, version) {
  if (info.length < 3 || info[1] !== address) {
    return '  Unrecognized warning layout; payload=' + bytes(info);
  }
  const cellCount = info[2];
  let offset = 3;
  if (cellCount < 1 || cellCount > 32 || info.length < offset + cellCount + 1) {
    return '  Invalid/truncated warning cell data; payload=' + bytes(info);
  }
  const cells = info.subarray(offset, offset + cellCount);
  offset += cellCount;
  const tempCount = info[offset++];
  const statusCount = version === 0x20 ? 8 : 12;
  if (tempCount > 16 || info.length < offset + tempCount + statusCount) {
    return '  Invalid/truncated warning data; payload=' + bytes(info);
  }
  const temperatures = info.subarray(offset, offset + tempCount);
  offset += tempCount;
  const nonzero = (values) => Array.from(values,
    (value, index) => value ? `${index + 1}=0x${hex(value)}` : null).filter(Boolean).join(', ') || 'all zero';
  const names = version === 0x20
    ? Array.from({ length: statusCount }, (_, i) => `register${i + 1}`)
    : ['charge-current warning', 'pack-voltage warning', 'discharge-current warning',
      'protection1', 'protection2', 'instruction', 'control', 'fault',
      'balance1', 'balance2', 'warning1', 'warning2'];
  return [
    `  Cell warning codes (${cellCount}): ${nonzero(cells)}`,
    `  Temperature warning codes (${tempCount}): ${nonzero(temperatures)}`,
    `  Status registers: ${names.map((name, i) => `${name}=0x${hex(info[offset + i])}`).join('; ')}`,
    `  Vendor fields: flag=0x${hex(info[0])}; pack=0x${hex(info[1])}; extension=${bytes(info.subarray(offset + statusCount))}`,
  ].join('\n');
}

class CommandDecoder {
  constructor({ onResponse, responseTimeout = 5000 } = {}) {
    this.frame = '';
    this.pending = new Map();
    this.onResponse = onResponse;
    this.responseTimeout = responseTimeout;
  }

  decode(frame) {
    const parsed = parseFrame(frame);
    if (parsed.error) return `Invalid frame: ${parsed.error}; ASCII=${visible(frame)}\n`;
    const { version, address, type, code, info } = parsed;
    const prefix = `Battery ${address} (0x${hex(address)}), protocol ${hex(version)}, CID1=0x${hex(type)}`;
    if ((version !== 0x25 && version !== 0x20) || type !== 0x46) {
      return `${prefix}: unsupported protocol; code=0x${hex(code)}; payload=${bytes(info)}\n`;
    }

    const pending = this.pending.get(address);
    // Error 0x90 overlaps the pack-number request; the observed query has no payload.
    const response = code <= 0x0f ||
      (code === 0x90 && pending && (pending.code !== 0x90 || info.length > 0));
    if (!response) {
      this.pending.set(address, {
        code,
        packAddress: (code === 0x42 || code === 0x44) && info.length === 1 ? info[0] : undefined,
        time: Date.now(),
      });
      return `${prefix}: REQUEST ${commands.get(code) || 'Unknown command'} (0x${hex(code)}); payload=${bytes(info)}; checksum OK\n`;
    }

    this.pending.delete(address);
    const matched = pending && Date.now() - pending.time <= this.responseTimeout;
    const command = matched ? pending.code : undefined;
    if (this.onResponse) this.onResponse(parsed, command);
    const label = command === undefined ? 'unmatched request' : `${commands.get(command) || 'Unknown command'} (0x${hex(command)})`;
    const status = returnCodes.get(code) || `Unknown return code 0x${hex(code)}`;
    let output = `${prefix}: RESPONSE ${label}: ${status}; checksum OK\n`;
    if (code !== 0 || command === undefined) {
      return output + `  Payload=${bytes(info)}\n`;
    }
    const packAddress = pending.packAddress === undefined ? address : pending.packAddress;
    if ((command === 0x42 || command === 0x44) && packAddress === 0xff) {
      return output + `  All-pack query; payload=${bytes(info)} (multi-pack layout not assumed)\n`;
    }
    if (command === 0x42) output += measurements(info, packAddress) + '\n';
    else if (command === 0x44) output += warnings(info, packAddress, version) + '\n';
    else if (command === 0x90 && info.length === 1) {
      output += `  Pack number/address field: ${info[0]} (0x${hex(info[0])})\n`;
    }
    else output += `  Payload=${bytes(info)} (vendor-specific layout)\n`;
    return output;
  }

  push(data) {
    let output = '';
    let noise = '';
    for (const byte of data) {
      if (byte === 0x7e) {
        if (this.frame) output += `Discarded incomplete frame: ${visible(this.frame)}\n`;
        this.frame = '~';
      } else if (this.frame) {
        if (byte === 0x0d) {
          output += this.decode(this.frame);
          this.frame = '';
        } else {
          this.frame += String.fromCharCode(byte);
          if (this.frame.length > 4113) {
            output += 'Invalid frame: exceeded maximum protocol length; discarded\n';
            this.frame = '';
          }
        }
      } else if (byte !== 0x0a && byte !== 0x0d) {
        noise += String.fromCharCode(byte);
      }
    }
    if (noise) output += `Unframed data: ${visible(noise)}\n`;
    return output;
  }

  finish() {
    const output = this.frame ? `Incomplete frame at shutdown: ${visible(this.frame)}\n` : '';
    this.frame = '';
    return output;
  }
}

module.exports = { CommandDecoder, parseFrame };
