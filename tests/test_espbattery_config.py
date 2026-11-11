import base64
import importlib.util
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch

import yaml


ROOT = Path(__file__).resolve().parents[1]

SPEC = importlib.util.spec_from_file_location(
    "espbattery_config", ROOT / "components" / "espbattery" / "__init__.py"
)
COMPONENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPONENT)


class SocketBudgetTest(unittest.TestCase):
    def test_legacy_socket_accounting(self):
        config = {"canbus_id": "test_can", "port": 1235, "buffer_size": 32}
        with patch.object(COMPONENT.socket, "SocketType", None, create=True):
            with patch.object(COMPONENT.socket, "consume_sockets", create=True) as consume:
                COMPONENT.validate_transport(config)
                self.assertEqual(consume.call_args_list, [call(1, "espbattery"), call(1, "espbattery")])

    def test_disabled_listener_uses_no_sockets(self):
        config = {"canbus_id": "test_can", "port": 0, "buffer_size": 32}
        with patch.object(COMPONENT.socket, "consume_sockets", create=True) as consume:
            COMPONENT.validate_transport(config)
            consume.assert_not_called()


class ESPBatteryConfigTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = {
            "esphome": {"name": "bridge-test"},
            "esp32": {
                "variant": "esp32s3",
                "flash_size": "16MB",
                "framework": {"type": "esp-idf"},
            },
            "wifi": {"ssid": "validation-network", "password": "validation-only"},
            "external_components": [{
                "source": {"type": "local", "path": str(ROOT / "components")},
                "components": ["espbattery"],
            }],
            "uart": {
                "id": "test_uart", "tx_pin": "GPIO17",
                "rx_pin": "GPIO18", "baud_rate": 9600,
            },
            "canbus": [{
                "platform": "esp32_can", "id": "test_can",
                "tx_pin": "GPIO2",
                "rx_pin": {"number": "GPIO3", "ignore_strapping_warning": True},
                "can_id": 0, "bit_rate": "500kbps",
            }],
        }

    def validate(self, expected_error=None, generate=False):
        path = Path(self.directory.name) / "bridge.yaml"
        path.write_text(yaml.safe_dump(self.config), encoding="utf-8")
        command = [sys.executable, "-m", "esphome"]
        if generate:
            command += ["compile", "--only-generate"]
        else:
            command += ["config"]
        environment = dict(os.environ, NO_COLOR="1")
        result = subprocess.run(
            command + [str(path)], capture_output=True, text=True,
            encoding="utf-8", errors="replace", env=environment, timeout=120,
        )
        output = result.stdout + result.stderr
        if expected_error:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(expected_error, output)
        else:
            self.assertEqual(result.returncode, 0, output)
        if generate and result.returncode == 0:
            source = Path(self.directory.name) / ".esphome" / "build" / "bridge-test" / "src"
            definitions = (source / "esphome" / "core" / "defines.h").read_text(encoding="utf-8")
            bridges = self.config["espbattery"]
            if isinstance(bridges, dict):
                bridges = [bridges]
            self.assertEqual(
                "#define USE_ESPBATTERY_CAN" in definitions,
                any("canbus_id" in bridge for bridge in bridges),
            )
            self.assertEqual(
                "#define USE_ESPBATTERY_UART" in definitions,
                any("canbus_id" not in bridge for bridge in bridges),
            )
            return (source / "main.cpp").read_text(encoding="utf-8")
        return result.stdout

    def test_existing_explicit_uart(self):
        del self.config["canbus"]
        self.config["espbattery"] = {"uart_id": "test_uart"}
        generated = self.validate(generate=True)
        self.assertIn("set_uart_parent", generated)

    def test_existing_implicit_uart(self):
        del self.config["canbus"]
        self.config["espbattery"] = {"port": 1234}
        self.validate()

    def test_can_only(self):
        del self.config["uart"]
        self.config["espbattery"] = {"canbus_id": "test_can", "port": 1235}
        generated = self.validate(generate=True)
        self.assertIn("set_canbus_parent", generated)
        self.assertNotIn("set_uart_parent", generated)

    def test_simultaneous(self):
        self.config["espbattery"] = [
            {"uart_id": "test_uart", "port": 1234, "flow_control_pin": "GPIO21"},
            {"canbus_id": "test_can", "port": 1235, "buffer_size": 1024},
        ]
        generated = self.validate(generate=True)
        self.assertIn("set_uart_parent", generated)
        self.assertIn("set_canbus_parent", generated)
        self.assertIn("set_port(1234)", generated)
        self.assertIn("set_port(1235)", generated)

    def pylon_entities(self):
        self.config["espbattery"] = [
            {"id": "uart_bridge", "uart_id": "test_uart", "port": 1234},
            {"id": "can_bridge", "canbus_id": "test_can", "port": 1235},
        ]
        self.config["sensor"] = [{
            "platform": "espbattery", "espbattery_id": "can_bridge",
            **{key: {"name": key} for key in (
                "voltage", "current", "power", "temperature", "state_of_charge",
                "state_of_health", "charge_voltage_limit", "charge_current_limit",
                "discharge_current_limit", "module_count", "protection_flags", "warning_flags",
            )},
        }]
        self.config["binary_sensor"] = [{
            "platform": "espbattery", "espbattery_id": "can_bridge",
            **{key: {"name": key} for key in (
                "charging_allowed", "discharging_allowed", "protection_active", "warning_active",
            )},
        }]
        self.config["text_sensor"] = [{
            "platform": "espbattery", "espbattery_id": "can_bridge",
            "manufacturer": {"name": "manufacturer"},
        }]

    def test_all_pylon_entities(self):
        self.pylon_entities()
        generated = self.validate(generate=True)
        self.assertIn("can_bridge->set_pylon_enabled(true)", generated)
        self.assertNotIn("uart_bridge->set_pylon_enabled", generated)
        for domain, suffix in (("sensor", "sensor"), ("binary_sensor", "binary_sensor"), ("text_sensor", "text_sensor")):
            for key in self.config[domain][0]:
                if key not in ("platform", "espbattery_id"):
                    self.assertIn(f"can_bridge->set_{key}_{suffix}", generated)
        self.assertEqual(len(re.findall(r"^\s*static esphome::espbattery::ChangeDetector<float> changes;", generated, re.MULTILINE)), 12)
        self.assertEqual(len(re.findall(r"^\s*static esphome::espbattery::ChangeDetector<std::string> changes;", generated, re.MULTILINE)), 1)

    def test_change_filter_runs_after_user_filters(self):
        self.pylon_entities()
        self.config["sensor"][0]["voltage"]["filters"] = [
            {"timeout": "15s"}, {"delta": 0.02},
        ]
        self.config["text_sensor"][0]["manufacturer"]["filters"] = [{"to_upper": {}}]
        class Loader(yaml.SafeLoader):
            pass

        Loader.add_constructor("!lambda", lambda loader, node: loader.construct_scalar(node))
        validated = yaml.load(self.validate(), Loader=Loader)
        numeric_filters = validated["sensor"][0]["voltage"]["filters"]
        self.assertEqual(len(numeric_filters), 3)
        for config, name in zip(numeric_filters, ("timeout", "delta", "lambda")):
            self.assertIn(name, config)
        text_filters = validated["text_sensor"][0]["manufacturer"]["filters"]
        self.assertEqual(len(text_filters), 2)
        self.assertIn("to_upper", text_filters[0])
        self.assertIn("lambda", text_filters[1])
        generated = self.validate(generate=True)
        self.assertIn("new sensor::TimeoutFilter", generated)
        self.assertIn("new sensor::DeltaFilter", generated)
        self.assertIn("new text_sensor::ToUpperFilter", generated)

    def test_force_update_preserves_repeated_numeric_updates(self):
        self.pylon_entities()
        self.config["sensor"][0]["voltage"]["force_update"] = True
        generated = self.validate(generate=True)
        self.assertEqual(len(re.findall(r"^\s*static esphome::espbattery::ChangeDetector<float> changes;", generated, re.MULTILINE)), 11)

    def test_pylon_entity_platforms_independently_without_tcp(self):
        del self.config["uart"]
        for domain in ("sensor", "binary_sensor", "text_sensor"):
            with self.subTest(domain=domain):
                self.pylon_entities()
                for other in ("sensor", "binary_sensor", "text_sensor"):
                    if other != domain:
                        del self.config[other]
                self.config["espbattery"] = [{
                    "id": "can_bridge", "canbus_id": "test_can", "port": 0,
                }]
                self.assertIn("can_bridge->set_pylon_enabled(true)", self.validate(generate=True))

    def test_pylon_entities_reject_uart_parent(self):
        for domain in ("sensor", "binary_sensor", "text_sensor"):
            with self.subTest(domain=domain):
                self.pylon_entities()
                self.config[domain][0]["espbattery_id"] = "uart_bridge"
                self.validate("PYLON entities require")

    def test_empty_pylon_entities_rejected(self):
        for domain in ("sensor", "binary_sensor", "text_sensor"):
            with self.subTest(domain=domain):
                self.pylon_entities()
                self.config[domain] = [{"platform": "espbattery", "espbattery_id": "can_bridge"}]
                self.validate("at least one")

    def test_invalid_transports(self):
        self.config["espbattery"] = {"uart_id": "test_uart", "canbus_id": "test_can"}
        self.validate("not both")

    def test_can_flow_control_rejected(self):
        self.config["espbattery"] = {"canbus_id": "test_can", "flow_control_pin": "GPIO21"}
        self.validate("only supported with UART")

    def test_small_can_buffer_rejected(self):
        self.config["espbattery"] = {"canbus_id": "test_can", "buffer_size": 16}
        self.validate("at least 32")

    def test_minimum_can_buffer(self):
        self.config["espbattery"] = {"canbus_id": "test_can", "buffer_size": 32}
        self.validate()

    def test_missing_canbus_rejected(self):
        del self.config["canbus"]
        self.config["espbattery"] = {"canbus_id": "test_can"}
        self.validate("test_can")

    def test_non_power_of_two_rejected(self):
        self.config["espbattery"] = {"canbus_id": "test_can", "buffer_size": 100}
        self.validate("power of two")

    def test_duplicate_ports_rejected(self):
        self.config["espbattery"] = [
            {"uart_id": "test_uart"}, {"canbus_id": "test_can"},
        ]
        self.validate("different port")

    def test_disabled_listeners(self):
        self.config["espbattery"] = [
            {"uart_id": "test_uart", "port": 0},
            {"canbus_id": "test_can", "port": 0},
        ]
        self.validate()

    def test_complete_recliner_configuration(self):
        class SecretsLoader(yaml.SafeLoader):
            pass

        secrets = {
            "recliner_api_key": base64.b64encode(os.urandom(32)).decode("ascii"),
            "recliner_ap_password": "validation-only",
            "wifi_ssid": "validation-network",
            "wifi_password": "validation-only",
        }
        SecretsLoader.add_constructor(
            "!secret", lambda loader, node: secrets[loader.construct_scalar(node)]
        )
        sample = yaml.load(
            (ROOT / "esphome" / "recliner-rs485.md").read_text(encoding="utf-8-sig"),
            Loader=SecretsLoader,
        )
        sample["external_components"] = self.config["external_components"]
        self.config = sample
        self.validate()


if __name__ == "__main__":
    unittest.main()
