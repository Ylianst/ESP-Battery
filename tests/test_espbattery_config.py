import base64
import importlib.util
import os
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
