#pragma once
#include "esphome/core/defines.h"
#include "esphome/core/component.h"
#include "esphome/core/hal.h"
#include "esphome/components/socket/socket.h"
#ifdef USE_ESPBATTERY_UART
#include "esphome/components/uart/uart.h"
#endif
#ifdef USE_ESPBATTERY_CAN
#include "esphome/components/canbus/canbus.h"
#include "slcan.h"
#endif
#ifdef USE_ESPBATTERY_PYLON
#include "pylon.h"
#endif
#ifdef USE_ESPBATTERY_PYLON_SENSOR
#include "esphome/components/sensor/sensor.h"
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
#include "esphome/components/binary_sensor/binary_sensor.h"
#endif
#ifdef USE_ESPBATTERY_PYLON_TEXT_SENSOR
#include "esphome/components/text_sensor/text_sensor.h"
#endif

#include <memory>
#include <string>
#include <vector>

namespace esphome {
namespace espbattery {

// Each instance bridges either raw UART bytes or SLCAN frames on its own TCP port.
class ESPBatteryComponent : public Component {
public:
	ESPBatteryComponent() = default;
#ifdef USE_ESPBATTERY_UART
	explicit ESPBatteryComponent(uart::UARTComponent *stream) : stream_{ stream } {}
	void set_uart_parent(uart::UARTComponent *parent) { this->stream_ = parent; }
#endif
#ifdef USE_ESPBATTERY_CAN
	void set_canbus_parent(canbus::Canbus *parent) { this->canbus_ = parent; }
#endif
	void set_buffer_size(size_t size) { this->buf_size_ = size; }
	void set_flow_control_pin(GPIOPin *flow_control_pin) { this->flow_control_pin_ = flow_control_pin; }
	void set_port(uint16_t port) { this->port_ = port; }
#ifdef USE_ESPBATTERY_PYLON
	void set_pylon_enabled(bool enabled) { this->pylon_enabled_ = enabled; }
#endif
#ifdef USE_ESPBATTERY_PYLON_SENSOR
	void set_voltage_sensor(sensor::Sensor *sensor) { this->voltage_sensor_ = sensor; }
	void set_current_sensor(sensor::Sensor *sensor) { this->current_sensor_ = sensor; }
	void set_power_sensor(sensor::Sensor *sensor) { this->power_sensor_ = sensor; }
	void set_temperature_sensor(sensor::Sensor *sensor) { this->temperature_sensor_ = sensor; }
	void set_state_of_charge_sensor(sensor::Sensor *sensor) { this->state_of_charge_sensor_ = sensor; }
	void set_state_of_health_sensor(sensor::Sensor *sensor) { this->state_of_health_sensor_ = sensor; }
	void set_charge_voltage_limit_sensor(sensor::Sensor *sensor) { this->charge_voltage_limit_sensor_ = sensor; }
	void set_charge_current_limit_sensor(sensor::Sensor *sensor) { this->charge_current_limit_sensor_ = sensor; }
	void set_discharge_current_limit_sensor(sensor::Sensor *sensor) { this->discharge_current_limit_sensor_ = sensor; }
	void set_module_count_sensor(sensor::Sensor *sensor) { this->module_count_sensor_ = sensor; }
	void set_protection_flags_sensor(sensor::Sensor *sensor) { this->protection_flags_sensor_ = sensor; }
	void set_warning_flags_sensor(sensor::Sensor *sensor) { this->warning_flags_sensor_ = sensor; }
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
	void set_charging_allowed_binary_sensor(binary_sensor::BinarySensor *sensor) { this->charging_allowed_binary_sensor_ = sensor; }
	void set_discharging_allowed_binary_sensor(binary_sensor::BinarySensor *sensor) { this->discharging_allowed_binary_sensor_ = sensor; }
	void set_protection_active_binary_sensor(binary_sensor::BinarySensor *sensor) { this->protection_active_binary_sensor_ = sensor; }
	void set_warning_active_binary_sensor(binary_sensor::BinarySensor *sensor) { this->warning_active_binary_sensor_ = sensor; }
#endif
#ifdef USE_ESPBATTERY_PYLON_TEXT_SENSOR
	void set_manufacturer_text_sensor(text_sensor::TextSensor *sensor) { this->manufacturer_text_sensor_ = sensor; }
#endif

	void setup() override;
	void loop() override;
	void dump_config() override;
	void on_shutdown() override;

	float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

protected:
#ifdef USE_ESPBATTERY_PYLON
	void publish_pylon_(const PylonMessage &message);
	bool pylon_enabled_{false};
#endif
#ifdef USE_ESPBATTERY_PYLON_SENSOR
	sensor::Sensor *voltage_sensor_{nullptr};
	sensor::Sensor *current_sensor_{nullptr};
	sensor::Sensor *power_sensor_{nullptr};
	sensor::Sensor *temperature_sensor_{nullptr};
	sensor::Sensor *state_of_charge_sensor_{nullptr};
	sensor::Sensor *state_of_health_sensor_{nullptr};
	sensor::Sensor *charge_voltage_limit_sensor_{nullptr};
	sensor::Sensor *charge_current_limit_sensor_{nullptr};
	sensor::Sensor *discharge_current_limit_sensor_{nullptr};
	sensor::Sensor *module_count_sensor_{nullptr};
	sensor::Sensor *protection_flags_sensor_{nullptr};
	sensor::Sensor *warning_flags_sensor_{nullptr};
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
	binary_sensor::BinarySensor *charging_allowed_binary_sensor_{nullptr};
	binary_sensor::BinarySensor *discharging_allowed_binary_sensor_{nullptr};
	binary_sensor::BinarySensor *protection_active_binary_sensor_{nullptr};
	binary_sensor::BinarySensor *warning_active_binary_sensor_{nullptr};
#endif
#ifdef USE_ESPBATTERY_PYLON_TEXT_SENSOR
	text_sensor::TextSensor *manufacturer_text_sensor_{nullptr};
#endif
	void accept();
	void cleanup();
	void read();
	void flush();
	void write();

	size_t buf_index(size_t pos) { return pos & (this->buf_size_ - 1); }
	/// Return the number of consecutive elements that are ahead of @p pos in memory.
	size_t buf_ahead(size_t pos) { return (pos | (this->buf_size_ - 1)) - pos + 1; }

	struct Client {
		Client(std::unique_ptr<socket::Socket> socket, std::string identifier, size_t position);

		std::unique_ptr<socket::Socket> socket{ nullptr };
		std::string identifier{};
		bool disconnected{ false };
		size_t position{ 0 };
#ifdef USE_ESPBATTERY_CAN
		SlcanParser parser{};
#endif
	};

#ifdef USE_ESPBATTERY_UART
	uart::UARTComponent *stream_{ nullptr };
#endif
#ifdef USE_ESPBATTERY_CAN
	void receive_can_(uint32_t id, bool extended, bool remote, const std::vector<uint8_t> &data);
	canbus::Canbus *canbus_{ nullptr };
#endif
	uint16_t port_{ 0 };
	size_t buf_size_{ 256 };
	GPIOPin *flow_control_pin_{ nullptr };

	std::unique_ptr<uint8_t[]> buf_{};
	size_t buf_head_{ 0 };
	size_t buf_tail_{ 0 };

	std::unique_ptr<socket::Socket> socket_{};
	std::vector<Client> clients_{};
};

}  // namespace espbattery
}  // namespace esphome
