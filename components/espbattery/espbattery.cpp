#include "espbattery.h"

#include "esphome/core/helpers.h"
#include "esphome/core/log.h"
#include "esphome/core/util.h"
#include "esphome/core/version.h"

#include "esphome/components/network/util.h"
#include "esphome/components/socket/socket.h"

#include <algorithm>

namespace esphome {
namespace espbattery {

static const char *const TAG = "espbattery";

void ESPBatteryComponent::setup() {
	if (this->flow_control_pin_ != nullptr) {
		this->flow_control_pin_->setup();
		this->flow_control_pin_->digital_write(false);
	}

	// The make_unique() wrapper doesn't like arrays, so initialize the unique_ptr directly.
	this->buf_ = std::unique_ptr<uint8_t[]>{ new uint8_t[this->buf_size_] };

	if (this->port_ != 0) {
		struct sockaddr_storage bind_addr;
#if ESPHOME_VERSION_CODE >= VERSION_CODE(2023, 4, 0)
		socklen_t bind_addrlen = socket::set_sockaddr_any(reinterpret_cast<struct sockaddr*>(&bind_addr), sizeof(bind_addr), this->port_);
#else
		socklen_t bind_addrlen = socket::set_sockaddr_any(reinterpret_cast<struct sockaddr*>(&bind_addr), sizeof(bind_addr), htons(this->port_));
#endif
		this->socket_ = socket::socket_ip(SOCK_STREAM, PF_INET);
		if (!this->socket_) {
			ESP_LOGE(TAG, "Failed to create TCP socket");
			this->mark_failed();
			return;
		}
		this->socket_->setblocking(false);
		if (this->socket_->bind(reinterpret_cast<struct sockaddr*>(&bind_addr), bind_addrlen) != 0) {
			ESP_LOGE(TAG, "Failed to bind TCP port %u (errno %d)", this->port_, errno);
			this->mark_failed();
			return;
		}
		this->socket_->listen(8);
	}
#ifdef USE_ESPBATTERY_CAN
	if (this->canbus_ != nullptr) {
		this->canbus_->add_callback([this](uint32_t id, bool extended, bool remote, const std::vector<uint8_t> &data) {
			this->receive_can_(id, extended, remote, data);
		});
	}
#endif
}

void ESPBatteryComponent::loop() {
	this->accept();
	this->read();
	this->flush();
	this->write();
	this->cleanup();
}

void ESPBatteryComponent::dump_config() {
	ESP_LOGCONFIG(TAG, "ESP-Battery:");
#ifdef USE_ESPBATTERY_CAN
	ESP_LOGCONFIG(TAG, "  Transport: %s", this->canbus_ != nullptr ? "CAN (SLCAN frames)" : "UART (raw bytes)");
#endif
#if ESPHOME_VERSION_CODE >= VERSION_CODE(2026, 7, 0)
	char use_address_buf[esphome::network::USE_ADDRESS_BUFFER_SIZE];
	ESP_LOGCONFIG(TAG, "  Address: %s:%u", esphome::network::get_use_address_to(use_address_buf), this->port_);
#else
	ESP_LOGCONFIG(TAG, "  Address: %s:%u", esphome::network::get_use_address(), this->port_);
#endif
	ESP_LOGCONFIG(TAG, "  Buffer Size: %u", (unsigned) this->buf_size_);
#ifdef USE_ESPBATTERY_PYLON
	ESP_LOGCONFIG(TAG, "  PYLON decoding: %s", this->pylon_enabled_ ? "enabled" : "disabled");
#endif
	LOG_PIN("  Flow Control Pin: ", this->flow_control_pin_);
#ifdef USE_ESPBATTERY_PYLON_SENSOR
	LOG_SENSOR("  ", "Voltage", this->voltage_sensor_);
	LOG_SENSOR("  ", "Current", this->current_sensor_);
	LOG_SENSOR("  ", "Power", this->power_sensor_);
	LOG_SENSOR("  ", "Temperature", this->temperature_sensor_);
	LOG_SENSOR("  ", "State of charge", this->state_of_charge_sensor_);
	LOG_SENSOR("  ", "State of health", this->state_of_health_sensor_);
	LOG_SENSOR("  ", "Charge voltage limit", this->charge_voltage_limit_sensor_);
	LOG_SENSOR("  ", "Charge current limit", this->charge_current_limit_sensor_);
	LOG_SENSOR("  ", "Discharge current limit", this->discharge_current_limit_sensor_);
	LOG_SENSOR("  ", "Module count", this->module_count_sensor_);
	LOG_SENSOR("  ", "Protection flags", this->protection_flags_sensor_);
	LOG_SENSOR("  ", "Warning flags", this->warning_flags_sensor_);
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
	LOG_BINARY_SENSOR("  ", "Charging allowed", this->charging_allowed_binary_sensor_);
	LOG_BINARY_SENSOR("  ", "Discharging allowed", this->discharging_allowed_binary_sensor_);
	LOG_BINARY_SENSOR("  ", "Protection active", this->protection_active_binary_sensor_);
	LOG_BINARY_SENSOR("  ", "Warning active", this->warning_active_binary_sensor_);
#endif
#ifdef USE_ESPBATTERY_PYLON_TEXT_SENSOR
	LOG_TEXT_SENSOR("  ", "Manufacturer", this->manufacturer_text_sensor_);
#endif
}

void ESPBatteryComponent::on_shutdown() {
	for (const Client &client : this->clients_)
		client.socket->shutdown(SHUT_RDWR);
}

void ESPBatteryComponent::accept() {
	if (!this->socket_) return;
	struct sockaddr_storage client_addr;
	socklen_t client_addrlen = sizeof(client_addr);
	std::unique_ptr<socket::Socket> socket = this->socket_->accept(reinterpret_cast<struct sockaddr*>(&client_addr), &client_addrlen);
	if (!socket) return;

	socket->setblocking(false);
	std::string identifier = inet_ntoa(reinterpret_cast<struct sockaddr_in*>(&client_addr)->sin_addr);
	this->clients_.emplace_back(std::move(socket), identifier, this->buf_head_);
	ESP_LOGD(TAG, "New client connected from %s", identifier.c_str());
}

void ESPBatteryComponent::cleanup() {
	auto discriminator = [](const Client &client) { return !client.disconnected; };
	auto last_client = std::partition(this->clients_.begin(), this->clients_.end(), discriminator);
	if (last_client != this->clients_.end()) {
		this->clients_.erase(last_client, this->clients_.end());
	}
}

// Read bytes from the RS485 bus into the ring buffer.
void ESPBatteryComponent::read() {
#ifdef USE_ESPBATTERY_UART
	if (this->stream_ == nullptr) return;
	size_t len = 0;
	int available;
	while ((available = this->stream_->available()) > 0) {
		size_t free = this->buf_size_ - (this->buf_head_ - this->buf_tail_);
		if (free == 0) {
			// Only overwrite if nothing has been added yet, otherwise give flush() a chance to empty the buffer first.
			if (len > 0)
				return;

			ESP_LOGE(TAG, "Incoming bytes available, but outgoing buffer is full: stream will be corrupted!");
			free = std::min<size_t>(available, this->buf_size_);
			this->buf_tail_ += free;
			for (Client &client : this->clients_) {
				if (client.position < this->buf_tail_) {
					ESP_LOGD(TAG, "Dropped %u pending bytes for client %s", (unsigned) (this->buf_tail_ - client.position), client.identifier.c_str());
					client.position = this->buf_tail_;
				}
			}
		}

		// Fill all available contiguous space in the ring buffer.
		len = std::min<size_t>(available, std::min<size_t>(this->buf_ahead(this->buf_head_), free));
		this->stream_->read_array(&this->buf_[this->buf_index(this->buf_head_)], len);
		this->buf_head_ += len;
	}
#endif
}

#ifdef USE_ESPBATTERY_CAN
void ESPBatteryComponent::receive_can_(uint32_t id, bool extended, bool remote, const std::vector<uint8_t> &data) {
	if (this->is_failed()) return;
	if (data.size() > 8 || id > (extended ? 0x1FFFFFFFU : 0x7FFU)) {
		ESP_LOGW(TAG, "Cannot relay invalid classic CAN frame");
		return;
	}
#ifdef USE_ESPBATTERY_PYLON
	if (this->pylon_enabled_) {
		PylonMessage message;
		auto result = decode_pylon(id, extended, remote, data, message);
		if (result == PylonResult::DECODED)
			this->publish_pylon_(message);
		else if (result == PylonResult::INVALID)
			ESP_LOGW(TAG, "Invalid PYLON CAN frame 0x%03X (%u bytes); sensor states unchanged", (unsigned) id, (unsigned) data.size());
	}
#endif
	if (this->clients_.empty()) return;
	const std::string line = format_slcan({id, extended, remote, data});
	if (this->buf_size_ - (this->buf_head_ - this->buf_tail_) < line.size())
		this->flush();

	this->buf_tail_ = this->buf_head_;
	for (Client &client : this->clients_) {
		if (client.disconnected) continue;
		if (this->buf_head_ - client.position + line.size() > this->buf_size_) {
			// Closing slow clients avoids dropping bytes in the middle of a CAN record.
			ESP_LOGW(TAG, "Disconnecting slow CAN client %s: outgoing buffer full", client.identifier.c_str());
			client.disconnected = true;
			client.socket->shutdown(SHUT_RDWR);
		} else {
			this->buf_tail_ = std::min(this->buf_tail_, client.position);
		}
	}
	for (char value : line)
		this->buf_[this->buf_index(this->buf_head_++)] = static_cast<uint8_t>(value);
}
#endif

#ifdef USE_ESPBATTERY_PYLON
#ifdef USE_ESPBATTERY_PYLON_SENSOR
static void publish_sensor(sensor::Sensor *sensor, float value) {
	if (sensor != nullptr) sensor->publish_state(value);
}
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
static void publish_binary_sensor(binary_sensor::BinarySensor *sensor, bool value) {
	if (sensor != nullptr) sensor->publish_state(value);
}
#endif

void ESPBatteryComponent::publish_pylon_(const PylonMessage &message) {
	switch (message.type) {
		case PylonType::LIMITS:
#ifdef USE_ESPBATTERY_PYLON_SENSOR
			publish_sensor(this->charge_voltage_limit_sensor_, message.charge_voltage_limit);
			publish_sensor(this->charge_current_limit_sensor_, message.charge_current_limit);
			publish_sensor(this->discharge_current_limit_sensor_, message.discharge_current_limit);
#endif
			break;
		case PylonType::SOC:
#ifdef USE_ESPBATTERY_PYLON_SENSOR
			publish_sensor(this->state_of_charge_sensor_, message.state_of_charge);
			publish_sensor(this->state_of_health_sensor_, message.state_of_health);
#endif
			break;
		case PylonType::MEASUREMENTS:
#ifdef USE_ESPBATTERY_PYLON_SENSOR
			publish_sensor(this->voltage_sensor_, message.voltage);
			publish_sensor(this->current_sensor_, message.current);
			publish_sensor(this->power_sensor_, message.voltage * message.current);
			publish_sensor(this->temperature_sensor_, message.temperature);
#endif
			break;
		case PylonType::STATUS:
#ifdef USE_ESPBATTERY_PYLON_SENSOR
			publish_sensor(this->module_count_sensor_, message.module_count);
			publish_sensor(this->protection_flags_sensor_, message.protection_flags);
			publish_sensor(this->warning_flags_sensor_, message.warning_flags);
#endif
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
			publish_binary_sensor(this->protection_active_binary_sensor_, message.protection_flags != 0);
			publish_binary_sensor(this->warning_active_binary_sensor_, message.warning_flags != 0);
#endif
			break;
		case PylonType::PERMISSIONS:
#ifdef USE_ESPBATTERY_PYLON_BINARY_SENSOR
			publish_binary_sensor(this->charging_allowed_binary_sensor_, message.charging_allowed);
			publish_binary_sensor(this->discharging_allowed_binary_sensor_, message.discharging_allowed);
#endif
			break;
		case PylonType::MANUFACTURER:
#ifdef USE_ESPBATTERY_PYLON_TEXT_SENSOR
			if (this->manufacturer_text_sensor_ != nullptr)
				this->manufacturer_text_sensor_->publish_state(message.manufacturer);
#endif
			break;
	}
}
#endif

// Send buffered RS485 bytes to all connected TCP clients.
void ESPBatteryComponent::flush() {
	ssize_t written;
	this->buf_tail_ = this->buf_head_;
	for (Client &client : this->clients_) {
		if (client.disconnected || client.position == this->buf_head_)
			continue;

		// Split the write into two parts: from the current position to the end of the ring buffer, and from the start
		// of the ring buffer until the head. The second part might be zero if no wraparound is necessary.
		struct iovec iov[2];
		iov[0].iov_base = &this->buf_[this->buf_index(client.position)];
		iov[0].iov_len = std::min(this->buf_head_ - client.position, this->buf_ahead(client.position));
		iov[1].iov_base = &this->buf_[0];
		iov[1].iov_len = this->buf_head_ - (client.position + iov[0].iov_len);
		if ((written = client.socket->writev(iov, 2)) > 0) {
			client.position += written;
		}
		else if (written == 0 || errno == ECONNRESET) {
			ESP_LOGD(TAG, "Client %s disconnected", client.identifier.c_str());
			client.disconnected = true;
			continue;  // don't consider this client when calculating the tail position
		}
		else if (errno == EWOULDBLOCK || errno == EAGAIN) {
			// Expected if the (TCP) transmit buffer is full, nothing to do.
		}
		else {
			ESP_LOGE(TAG, "Failed to write to client %s with error %d!", client.identifier.c_str(), errno);
		}

		this->buf_tail_ = std::min(this->buf_tail_, client.position);
	}
}

// Forward bytes received from TCP clients onto the RS485 bus.
void ESPBatteryComponent::write() {
	uint8_t buf[128];
	ssize_t read;
	for (Client &client : this->clients_) {
		if (client.disconnected)
			continue;

		while ((read = client.socket->read(&buf, sizeof(buf))) > 0) {
#ifdef USE_ESPBATTERY_CAN
			if (this->canbus_ != nullptr) {
				for (ssize_t i = 0; i < read; i++) {
					SlcanFrame frame;
					auto result = client.parser.feed(buf[i], frame);
					if (result == SlcanParser::INVALID) {
						ESP_LOGW(TAG, "Invalid or unsupported SLCAN frame from %s; disconnecting", client.identifier.c_str());
						client.disconnected = true;
						client.socket->shutdown(SHUT_RDWR);
						break;
					}
					if (result == SlcanParser::FRAME)
						this->canbus_->send_data(frame.id, frame.extended, frame.remote, frame.data);
				}
				if (client.disconnected) break;
				continue;
			}
#endif
#ifdef USE_ESPBATTERY_UART
			if (this->flow_control_pin_ != nullptr) { this->flow_control_pin_->digital_write(true); }
			this->stream_->write_array(buf, read);
			this->stream_->flush();
			if (this->flow_control_pin_ != nullptr) { this->flow_control_pin_->digital_write(false); }
#endif
		}

		if (client.disconnected) continue;
		if (read == 0 || errno == ECONNRESET) {
			ESP_LOGD(TAG, "Client %s disconnected", client.identifier.c_str());
			client.disconnected = true;
		}
		else if (errno == EWOULDBLOCK || errno == EAGAIN) {
			// Expected if the (TCP) receive buffer is empty, nothing to do.
		}
		else {
			ESP_LOGD(TAG, "Failed to read from client %s with error %d!", client.identifier.c_str(), errno);
		}
	}
}

ESPBatteryComponent::Client::Client(std::unique_ptr<socket::Socket> socket, std::string identifier, size_t position)
	: socket(std::move(socket)), identifier{ identifier }, position{ position } {
}

}  // namespace espbattery
}  // namespace esphome
