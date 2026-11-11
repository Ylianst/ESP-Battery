#include "../components/espbattery/slcan.h"

#include <cassert>
#include <iostream>

using namespace esphome::espbattery;

int main() {
	SlcanFrame frame;
	assert(parse_slcan("t1232aAbB", frame));
	assert(frame.id == 0x123 && !frame.extended && !frame.remote);
	assert((frame.data == std::vector<uint8_t>{0xAA, 0xBB}));
	assert(format_slcan(frame) == "t1232AABB\r");

	for (bool extended : {false, true}) {
		for (bool remote : {false, true}) {
			for (size_t length = 0; length <= 8; length++) {
				for (uint32_t id : {0U, 1U, extended ? 0x1FFFFFFFU : 0x7FFU}) {
					SlcanFrame original{id, extended, remote, std::vector<uint8_t>(length, 0xA5)};
					const auto encoded = format_slcan(original);
					assert(encoded.size() <= 27 && encoded.back() == '\r');
					SlcanParser parser;
					for (size_t i = 0; i < encoded.size(); i++) {
						auto result = parser.feed(encoded[i], frame);
						assert(result == (i + 1 == encoded.size() ? SlcanParser::FRAME : SlcanParser::INCOMPLETE));
					}
					assert(frame.id == id && frame.extended == extended && frame.remote == remote);
					assert(frame.data.size() == length);
					assert(frame.data == std::vector<uint8_t>(length, remote ? 0 : 0xA5));
				}
			}
		}
	}

	for (const std::string invalid : {
		"", "O", "C", "S6", "t", "t123", "t8000", "T200000000", "t12G0",
		"t1239", "t123F", "t1231", "t1230AA", "t1231AZ", "r1231AA",
		"RFFFFFFFF0", "t1230\n", "t1230extra"
	}) {
		assert(!parse_slcan(invalid, frame));
	}

	// TCP chunk boundaries do not delimit frames, and clients cannot share partial input.
	SlcanParser first;
	SlcanParser second;
	for (char value : std::string("t1232AA")) assert(first.feed(value, frame) == SlcanParser::INCOMPLETE);
	for (char value : std::string("r4568")) assert(second.feed(value, frame) == SlcanParser::INCOMPLETE);
	assert(second.feed('\r', frame) == SlcanParser::FRAME && frame.id == 0x456);
	for (char value : std::string("BB")) assert(first.feed(value, frame) == SlcanParser::INCOMPLETE);
	assert(first.feed('\r', frame) == SlcanParser::FRAME && frame.id == 0x123);

	int frames = 0;
	for (char value : std::string("\nt0000\r\nt7FF0\rT1FFFFFFF0\rR000000008\r")) {
		auto result = first.feed(value, frame);
		assert(result != SlcanParser::INVALID);
		if (result == SlcanParser::FRAME) frames++;
	}
	assert(frames == 4);

	for (int i = 0; i < 10000; i++) assert(first.feed('A', frame) == SlcanParser::INCOMPLETE);
	assert(first.feed('\r', frame) == SlcanParser::INVALID);
	for (char value : std::string("t0010")) assert(first.feed(value, frame) == SlcanParser::INCOMPLETE);
	assert(first.feed('\r', frame) == SlcanParser::FRAME && frame.id == 1);
	assert(first.feed('\r', frame) == SlcanParser::INVALID);
	std::cout << "SLCAN tests passed\n";
}
