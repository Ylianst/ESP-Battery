import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import text_sensor
from esphome.const import CONF_FILTERS, ENTITY_CATEGORY_DIAGNOSTIC

from . import ESPBATTERY_ENTITY_SCHEMA, pylon_parent, validate_can_entity

DEPENDENCIES = ["espbattery"]
CONF_MANUFACTURER = "manufacturer"

def append_change_filter(config):
    config[CONF_FILTERS] = config.get(CONF_FILTERS, []) + text_sensor.validate_filters([{
        "lambda": cv.Lambda(
            "static esphome::espbattery::ChangeDetector<std::string> changes;\n"
            "if (!changes.changed(x)) return {};\n"
            "return x;"
        ),
    }])
    return config

CONFIG_SCHEMA = cv.All(
    cv.Schema({
        cv.Optional(CONF_MANUFACTURER): cv.All(
            text_sensor.text_sensor_schema(entity_category=ENTITY_CATEGORY_DIAGNOSTIC),
            append_change_filter,
        ),
    }).extend(ESPBATTERY_ENTITY_SCHEMA),
    cv.has_at_least_one_key(CONF_MANUFACTURER),
)
FINAL_VALIDATE_SCHEMA = validate_can_entity


async def to_code(config):
    parent = await pylon_parent(config)
    cg.add_define("USE_ESPBATTERY_PYLON_TEXT_SENSOR")
    entity = await text_sensor.new_text_sensor(config[CONF_MANUFACTURER])
    cg.add(parent.set_manufacturer_text_sensor(entity))
