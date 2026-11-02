#pragma once
#include "esphome/core/component.h"
#include "esphome/core/hal.h"
#include "esphome/components/socket/socket.h"
#include "esphome/components/uart/uart.h"

#include <memory>
#include <string>
#include <vector>

namespace esphome {
namespace espbattery {

// Bidirectional RS485 (UART) <-> TCP forwarder. Bytes received on the RS485 bus are sent to every
// connected TCP client, and bytes received from any TCP client are written to the RS485 bus.
class ESPBatteryComponent : public Component {
public:
	ESPBatteryComponent() = default;
	explicit ESPBatteryComponent(uart::UARTComponent *stream) : stream_{ stream } {}
	void set_uart_parent(uart::UARTComponent *parent) { this->stream_ = parent; }
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
	};

	uart::UARTComponent *stream_{ nullptr };
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
