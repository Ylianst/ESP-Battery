#include "../components/espbattery/publish_on_change.h"

#include <cassert>
#include <iostream>
#include <limits>
#include <string>

using esphome::espbattery::ChangeDetector;

int main() {
	ChangeDetector<float> voltage;
	assert(voltage.changed(53.66f));
	for (int i = 0; i < 10000; i++) assert(!voltage.changed(53.66f));
	assert(voltage.changed(53.67f));
	assert(!voltage.changed(53.67f));
	assert(voltage.changed(53.66f));

	// A timeout must publish unknown once, then recover even to the same previous reading.
	const float unknown = std::numeric_limits<float>::quiet_NaN();
	assert(voltage.changed(unknown));
	assert(!voltage.changed(unknown));
	assert(voltage.changed(53.66f));
	assert(!voltage.changed(53.66f));

	ChangeDetector<float> initially_unknown;
	assert(initially_unknown.changed(unknown));
	assert(!initially_unknown.changed(unknown));
	assert(initially_unknown.changed(0.0f));
	assert(!initially_unknown.changed(-0.0f));
	assert(initially_unknown.changed(-0.1f));

	ChangeDetector<float> independent;
	assert(independent.changed(53.66f));
	assert(!independent.changed(53.66f));
	assert(independent.changed(std::numeric_limits<float>::infinity()));
	assert(!independent.changed(std::numeric_limits<float>::infinity()));
	assert(independent.changed(-std::numeric_limits<float>::infinity()));

	ChangeDetector<std::string> manufacturer;
	assert(manufacturer.changed("LEOCH"));
	for (int i = 0; i < 10000; i++) assert(!manufacturer.changed("LEOCH"));
	assert(manufacturer.changed("PYLON"));
	assert(!manufacturer.changed("PYLON"));
	assert(manufacturer.changed("LEOCH"));
	ChangeDetector<std::string> empty_text;
	assert(empty_text.changed(""));
	assert(!empty_text.changed(""));
	std::cout << "Publish-on-change tests passed\n";
}
