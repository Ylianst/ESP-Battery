#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace esphome {
namespace espbattery {

struct SlcanFrame {
	uint32_t id{0};
	bool extended{false};
	bool remote{false};
	std::vector<uint8_t> data{};
};

inline int slcan_hex(char value) {
	if (value >= '0' && value <= '9') return value - '0';
	if (value >= 'A' && value <= 'F') return value - 'A' + 10;
	if (value >= 'a' && value <= 'f') return value - 'a' + 10;
	return -1;
}

inline bool parse_slcan(const std::string &line, SlcanFrame &frame) {
	if (line.empty()) return false;
	const char command = line[0];
	if (command != 't' && command != 'T' && command != 'r' && command != 'R') return false;
	const bool extended = command == 'T' || command == 'R';
	const bool remote = command == 'r' || command == 'R';
	const size_t digits = extended ? 8 : 3;
	if (line.size() < digits + 2) return false;

	uint32_t id = 0;
	for (size_t i = 1; i <= digits; i++) {
		int value = slcan_hex(line[i]);
		if (value < 0) return false;
		id = (id << 4) | value;
	}
	if (id > (extended ? 0x1FFFFFFFU : 0x7FFU)) return false;
	int length = slcan_hex(line[digits + 1]);
	if (length < 0 || length > 8) return false;
	if (line.size() != digits + 2 + (remote ? 0 : 2 * length)) return false;

	std::vector<uint8_t> data(length, 0);
	if (!remote) {
		for (int i = 0; i < length; i++) {
			int high = slcan_hex(line[digits + 2 + i * 2]);
			int low = slcan_hex(line[digits + 3 + i * 2]);
			if (high < 0 || low < 0) return false;
			data[i] = static_cast<uint8_t>((high << 4) | low);
		}
	}
	frame = {id, extended, remote, std::move(data)};
	return true;
}

inline std::string format_slcan(const SlcanFrame &frame) {
	static const char HEX[] = "0123456789ABCDEF";
	std::string line;
	line.reserve(27);
	line += frame.remote ? (frame.extended ? 'R' : 'r') : (frame.extended ? 'T' : 't');
	for (int shift = frame.extended ? 28 : 8; shift >= 0; shift -= 4)
		line += HEX[(frame.id >> shift) & 0xF];
	line += HEX[frame.data.size()];
	if (!frame.remote) {
		for (uint8_t value : frame.data) {
			line += HEX[value >> 4];
			line += HEX[value & 0xF];
		}
	}
	line += '\r';
	return line;
}

class SlcanParser {
public:
	enum Result { INCOMPLETE, FRAME, INVALID };

	Result feed(uint8_t value, SlcanFrame &frame) {
		if (value == '\n' && this->line_.empty() && !this->overflow_) return INCOMPLETE;
		if (value != '\r') {
			if (this->line_.size() < 26)
				this->line_ += static_cast<char>(value);
			else
				this->overflow_ = true;
			return INCOMPLETE;
		}
		bool valid = !this->overflow_ && parse_slcan(this->line_, frame);
		this->line_.clear();
		this->overflow_ = false;
		return valid ? FRAME : INVALID;
	}

private:
	std::string line_{};
	bool overflow_{false};
};

}  // namespace espbattery
}  // namespace esphome
