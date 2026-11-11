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

	void setup() override;
	void loop() override;
	void dump_config() override;
	void on_shutdown() override;

	float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

protected:
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
