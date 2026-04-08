import pytest
from telemetry_sender import TelemetrySender


class FakeMsg:
    def __init__(self, msg_type, **kwargs):
        self._type = msg_type
        self.__dict__.update(kwargs)

    def get_type(self):
        return self._type


def test_default_state():
    sender = TelemetrySender()
    assert sender.state['lat'] == 0.0
    assert sender.state['lon'] == 0.0
    assert sender.state['alt'] == 0.0
    assert sender.state['speed'] == 0.0
    assert sender.state['heading'] == 0
    assert sender.state['battery'] == 0.0
    assert sender.state['voltage'] == 0.0
    assert sender.state['armed'] == False
    assert sender.state['flight_mode'] == "UNKNOWN"
    assert sender.state['gps_fix_type'] == 0
    assert sender.state['satellites'] == 0


def test_global_position_int():
    sender = TelemetrySender()
    msg = FakeMsg("GLOBAL_POSITION_INT",
        lat=285271350,
        lon=770654210,
        relative_alt=15430,
        hdg=18045,
    )
    sender.update_state(msg)
    assert sender.state['lat'] == pytest.approx(28.527135)
    assert sender.state['lon'] == pytest.approx(77.065421)
    assert sender.state['alt'] == pytest.approx(15.43)
    assert sender.state['heading'] == pytest.approx(180.45)


def test_sys_status():
    sender = TelemetrySender()
    msg = FakeMsg("SYS_STATUS",
        battery_remaining=87,
        voltage_battery=12600,
    )
    sender.update_state(msg)
    assert sender.state['battery'] == 87
    assert sender.state['voltage'] == pytest.approx(12.6)


def test_vfr_hud():
    sender = TelemetrySender()
    msg = FakeMsg("VFR_HUD", groundspeed=5.2)
    sender.update_state(msg)
    assert sender.state['speed'] == pytest.approx(5.2)


def test_gps_raw_int():
    sender = TelemetrySender()
    msg = FakeMsg("GPS_RAW_INT",
        fix_type=3,
        satellites_visible=12,
    )
    sender.update_state(msg)
    assert sender.state['gps_fix_type'] == 3
    assert sender.state['satellites'] == 12


def test_build_payload_has_all_fields():
    sender = TelemetrySender()
    payload = sender.build_payload()
    required = ['drone_id', 'lat', 'lon', 'alt', 'speed', 'heading',
                'battery', 'voltage', 'armed', 'flight_mode',
                'gps_fix_type', 'satellites']
    for field in required:
        assert field in payload


def test_build_payload_heading_is_int():
    sender = TelemetrySender()
    sender.state['heading'] = 180.45
    payload = sender.build_payload()
    assert payload['heading'] == 180
    assert isinstance(payload['heading'], int)


def test_accumulator_across_messages():
    sender = TelemetrySender()
    sender.update_state(FakeMsg("GLOBAL_POSITION_INT",
        lat=285271350, lon=770654210,
        relative_alt=15430, hdg=18045))
    sender.update_state(FakeMsg("SYS_STATUS",
        battery_remaining=87, voltage_battery=12600))
    sender.update_state(FakeMsg("VFR_HUD", groundspeed=5.2))
    sender.update_state(FakeMsg("GPS_RAW_INT",
        fix_type=3, satellites_visible=12))

    payload = sender.build_payload()
    assert payload['lat'] == pytest.approx(28.527135)
    assert payload['battery'] == 87
    assert payload['speed'] == pytest.approx(5.2)
    assert payload['satellites'] == 12