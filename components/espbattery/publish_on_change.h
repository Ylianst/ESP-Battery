#pragma once

#include <cmath>

namespace esphome {
namespace espbattery {

template<typename T> inline bool same_published_value(const T &left, const T &right) {
	return left == right;
}

inline bool same_published_value(float left, float right) {
	return left == right || (std::isnan(left) && std::isnan(right));
}

template<typename T> class ChangeDetector {
public:
	bool changed(const T &value) {
		if (this->has_value_ && same_published_value(this->previous_, value)) return false;
		this->previous_ = value;
		this->has_value_ = true;
		return true;
	}

private:
	T previous_{};
	bool has_value_{false};
};

}  // namespace espbattery
}  // namespace esphome
