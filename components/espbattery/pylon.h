#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace esphome {
namespace espbattery {

enum class PylonResult { IGNORED, INVALID, DECODED };
enum class PylonType { LIMITS, SOC, MEASUREMENTS, STATUS, PERMISSIONS, MANUFACTURER };

struct PylonMessage {
	PylonType type{};
	float charge_voltage_limit{0};
	float charge_current_limit{0};
	float discharge_current_limit{0};
	float state_of_charge{0};
	float state_of_health{0};
	float voltage{0};
	float current{0};
	float temperature{0};
	uint16_t protection_flags{0};
	uint16_t warning_flags{0};
	uint8_t module_count{0};
	bool charging_allowed{false};
	bool discharging_allowed{false};
	std::string manufacturer{};
};

inline uint16_t pylon_u16(const uint8_t *data) {
	return static_cast<uint16_t>(data[0] | (static_cast<uint16_t>(data[1]) << 8));
}

inline int32_t pylon_i16(const uint8_t *data) {
	uint16_t value = pylon_u16(data);
	return value >= 0x8000 ? static_cast<int32_t>(value) - 0x10000 : value;
}

inline PylonResult decode_pylon(uint32_t id, bool extended, bool remote,
	const std::vector<uint8_t> &data, PylonMessage &message) {
	if (extended || remote) return PylonResult::IGNORED;
	size_t minimum;
	PylonMessage decoded;
	switch (id) {
		case 0x351: decoded.type = PylonType::LIMITS; minimum = 6; break;
		case 0x355: decoded.type = PylonType::SOC; minimum = 4; break;
		case 0x356: decoded.type = PylonType::MEASUREMENTS; minimum = 6; break;
		case 0x359: decoded.type = PylonType::STATUS; minimum = 7; break;
		case 0x35C: decoded.type = PylonType::PERMISSIONS; minimum = 2; break;
		case 0x35E: decoded.type = PylonType::MANUFACTURER; minimum = 8; break;
		default: return PylonResult::IGNORED;
	}
	if (data.size() < minimum || data.size() > 8) return PylonResult::INVALID;

	switch (decoded.type) {
		case PylonType::LIMITS:
			decoded.charge_voltage_limit = pylon_u16(&data[0]) / 10.0f;
			decoded.charge_current_limit = pylon_i16(&data[2]) / 10.0f;
			decoded.discharge_current_limit = pylon_i16(&data[4]) / 10.0f;
			break;
		case PylonType::SOC:
			decoded.state_of_charge = pylon_u16(&data[0]);
			decoded.state_of_health = pylon_u16(&data[2]);
			if (decoded.state_of_charge > 100 || decoded.state_of_health > 100)
				return PylonResult::INVALID;
			break;
		case PylonType::MEASUREMENTS:
			decoded.voltage = pylon_u16(&data[0]) / 100.0f;
			decoded.current = pylon_i16(&data[2]) / 10.0f;
			decoded.temperature = pylon_i16(&data[4]) / 10.0f;
			break;
		case PylonType::STATUS:
			decoded.protection_flags = pylon_u16(&data[0]);
			decoded.warning_flags = pylon_u16(&data[2]);
			decoded.module_count = data[4];
			break;
		case PylonType::PERMISSIONS:
			decoded.charging_allowed = (data[0] & 0x80) != 0;
			decoded.discharging_allowed = (data[0] & 0x40) != 0;
			break;
		case PylonType::MANUFACTURER:
			decoded.manufacturer.assign(data.begin(), data.end());
			while (!decoded.manufacturer.empty() &&
				(decoded.manufacturer.back() == ' ' || decoded.manufacturer.back() == '\0'))
				decoded.manufacturer.pop_back();
			if (decoded.manufacturer.empty()) return PylonResult::INVALID;
			for (unsigned char value : decoded.manufacturer)
				if (value < 0x20 || value > 0x7E) return PylonResult::INVALID;
			break;
	}
	message = std::move(decoded);
	return PylonResult::DECODED;
}

}  // namespace espbattery
}  // namespace esphome
