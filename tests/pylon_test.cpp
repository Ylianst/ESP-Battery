#include "../components/espbattery/pylon.h"
#include "../components/espbattery/slcan.h"

#include <cassert>
#include <cmath>
#include <iostream>

using namespace esphome::espbattery;

static PylonMessage captured(const std::string &line) {
	SlcanFrame frame;
	PylonMessage message;
	assert(parse_slcan(line, frame));
	assert(decode_pylon(frame.id, frame.extended, frame.remote, frame.data, message) == PylonResult::DECODED);
	return message;
}

static bool near(float actual, float expected) {
	return std::fabs(actual - expected) < 0.001f;
}

int main() {
	auto limits = captured("t351834025807A00FB001");
	assert(limits.type == PylonType::LIMITS);
	assert(near(limits.charge_voltage_limit, 56.4f));
	assert(near(limits.charge_current_limit, 188.0f));
	assert(near(limits.discharge_current_limit, 400.0f));

	auto soc = captured("t35584900640000000000");
	assert(soc.type == PylonType::SOC);
	assert(soc.state_of_charge == 73 && soc.state_of_health == 100);

	auto measurements = captured("t3568F6140000AD000000");
	assert(measurements.type == PylonType::MEASUREMENTS);
	assert(near(measurements.voltage, 53.66f));
	assert(measurements.current == 0);
	assert(near(measurements.temperature, 17.3f));
	auto negative = captured("t3566F61485FFCEFF");
	assert(near(negative.current, -12.3f) && near(negative.temperature, -5.0f));
	auto positive = captured("t3566F6147B003200");
	assert(near(positive.current, 12.3f) && near(positive.temperature, 5.0f));
	auto extremes = captured("t3566FFFF0080FF7F");
	assert(near(extremes.voltage, 655.35f));
	assert(near(extremes.current, -3276.8f) && near(extremes.temperature, 3276.7f));

	auto status = captured("t35980000000004504E00");
	assert(status.type == PylonType::STATUS && status.module_count == 4);
	assert(status.protection_flags == 0 && status.warning_flags == 0);
	status = captured("t35973412785604504E");
	assert(status.protection_flags == 0x1234 && status.warning_flags == 0x5678);

	for (uint8_t flags : std::vector<uint8_t>{0x00, 0x40, 0x80, 0xC0}) {
		PylonMessage permissions;
		assert(decode_pylon(0x35C, false, false, {flags, 0}, permissions) == PylonResult::DECODED);
		assert(permissions.type == PylonType::PERMISSIONS);
		assert(permissions.charging_allowed == ((flags & 0x80) != 0));
		assert(permissions.discharging_allowed == ((flags & 0x40) != 0));
	}
	assert(captured("t35C8C000000000000000").charging_allowed);
	assert(captured("t35E84C454F4348202020").manufacturer == "LEOCH");
	assert(captured("t35E84C454F4348000000").manufacturer == "LEOCH");

	for (uint32_t id : {0x351U, 0x355U, 0x356U, 0x359U, 0x35CU, 0x35EU}) {
		PylonMessage unchanged;
		unchanged.voltage = 123;
		assert(decode_pylon(id, true, false, std::vector<uint8_t>(8), unchanged) == PylonResult::IGNORED);
		assert(decode_pylon(id, false, true, std::vector<uint8_t>(8), unchanged) == PylonResult::IGNORED);
		assert(decode_pylon(id, false, false, {}, unchanged) == PylonResult::INVALID);
		assert(decode_pylon(id, false, false, std::vector<uint8_t>(9), unchanged) == PylonResult::INVALID);
		assert(unchanged.voltage == 123);
	}
	PylonMessage message;
	assert(decode_pylon(0x305, false, false, {}, message) == PylonResult::IGNORED);
	assert(decode_pylon(0x355, false, false, {101, 0, 100, 0}, message) == PylonResult::INVALID);
	assert(decode_pylon(0x355, false, false, {100, 0, 101, 0}, message) == PylonResult::INVALID);
	assert(decode_pylon(0x355, false, false, {0, 0, 100, 0}, message) == PylonResult::DECODED);
	assert(decode_pylon(0x35E, false, false, std::vector<uint8_t>(8, ' '), message) == PylonResult::INVALID);
	assert(decode_pylon(0x35E, false, false, {'A', 1, 'B', ' ', ' ', ' ', ' ', ' '}, message) == PylonResult::INVALID);

	for (const auto &entry : std::vector<std::pair<uint32_t, size_t>>{
		{0x351, 6}, {0x355, 4}, {0x356, 6}, {0x359, 7}, {0x35C, 2}, {0x35E, 8}
	}) {
		for (size_t length = 0; length < entry.second; length++)
			assert(decode_pylon(entry.first, false, false, std::vector<uint8_t>(length), message) == PylonResult::INVALID);
	}
	std::cout << "PYLON decoding tests passed\n";
}
