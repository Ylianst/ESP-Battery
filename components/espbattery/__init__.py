import esphome.codegen as cg
import esphome.config_validation as cv
import esphome.final_validate as fv
from esphome.components import canbus, socket, uart
from esphome.const import CONF_ID, CONF_PORT, CONF_FLOW_CONTROL_PIN, CONF_BUFFER_SIZE, CONF_UART_ID
from esphome.cpp_helpers import gpio_pin_expression
from esphome import pins

AUTO_LOAD = ["socket"]
DEPENDENCIES = ["network"]
MULTI_CONF = True

CONF_CANBUS_ID = "canbus_id"
CONF_ESPBATTERY_ID = "espbattery_id"

espbattery_ns = cg.esphome_ns.namespace("espbattery")
ESPBatteryComponent = espbattery_ns.class_("ESPBatteryComponent", cg.Component)

ESPBATTERY_ENTITY_SCHEMA = cv.Schema(
    {cv.GenerateID(CONF_ESPBATTERY_ID): cv.use_id(ESPBatteryComponent)}
)

def validate_can_entity(config):
    full_config = fv.full_config.get()
    path = full_config.get_path_for_id(config[CONF_ESPBATTERY_ID])[:-1]
    parent = full_config.get_config_for_path(path)
    if CONF_CANBUS_ID not in parent:
        raise cv.Invalid("PYLON entities require an espbattery instance with canbus_id.")
    return config

async def pylon_parent(config):
    cg.add_define("USE_ESPBATTERY_PYLON")
    parent = await cg.get_variable(config[CONF_ESPBATTERY_ID])
    cg.add(parent.set_pylon_enabled(True))
    return parent

def validate_buffer_size(buffer_size):
    if buffer_size & (buffer_size - 1) != 0:
        raise cv.Invalid("Buffer size must be a power of two.")
    return buffer_size

def validate_transport(config):
    if CONF_CANBUS_ID in config:
        if CONF_UART_ID in config:
            raise cv.Invalid("Specify either uart_id or canbus_id, not both.")
        if CONF_FLOW_CONTROL_PIN in config:
            raise cv.Invalid("flow_control_pin is only supported with UART.")
        if config[CONF_BUFFER_SIZE] < 32:
            raise cv.Invalid("CAN buffer_size must be at least 32 bytes.")
    else:
        # Preserve implicit UART selection for existing single-bus configurations.
        uart_config = {CONF_UART_ID: config[CONF_UART_ID]} if CONF_UART_ID in config else {}
        config.update(uart.UART_DEVICE_SCHEMA(uart_config))
    # Older ESPHome versions predate automatic socket budgeting.
    if config[CONF_PORT] != 0 and hasattr(socket, "consume_sockets"):
        socket.consume_sockets(1, "espbattery")(config)
        if hasattr(socket, "SocketType") and hasattr(socket.SocketType, "TCP_LISTEN"):
            socket.consume_sockets(1, "espbattery", socket.SocketType.TCP_LISTEN)(config)
        else:
            socket.consume_sockets(1, "espbattery")(config)
    return config

def validate_ports(config):
    ports = set()
    for bridge in fv.full_config.get()["espbattery"]:
        port = bridge[CONF_PORT]
        if port != 0 and port in ports:
            raise cv.Invalid("Each espbattery TCP server must use a different port.")
        ports.add(port)
    return config

CONFIG_SCHEMA = cv.All(
    cv.require_esphome_version(2022, 3, 0),
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(ESPBatteryComponent),
            cv.Optional(CONF_PORT, default = 1234): cv.int_range(min = 0, max = 65535),
            cv.Optional(CONF_BUFFER_SIZE, default = 256): cv.All(cv.positive_int, validate_buffer_size),
            cv.Optional(CONF_FLOW_CONTROL_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_UART_ID): cv.use_id(uart.UARTComponent),
            cv.Optional(CONF_CANBUS_ID): cv.use_id(canbus.CanbusComponent),
        }
    )
    .extend(cv.COMPONENT_SCHEMA),
    validate_transport,
)

FINAL_VALIDATE_SCHEMA = validate_ports

async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    cg.add(var.set_port(config[CONF_PORT]))
    cg.add(var.set_buffer_size(config[CONF_BUFFER_SIZE]))

    if CONF_FLOW_CONTROL_PIN in config:
        pin = await gpio_pin_expression(config[CONF_FLOW_CONTROL_PIN])
        cg.add(var.set_flow_control_pin(pin))

    await cg.register_component(var, config)
    if CONF_CANBUS_ID in config:
        cg.add_define("USE_ESPBATTERY_CAN")
        bus = await cg.get_variable(config[CONF_CANBUS_ID])
        cg.add(var.set_canbus_parent(bus))
    else:
        cg.add_define("USE_ESPBATTERY_UART")
        await uart.register_uart_device(var, config)
