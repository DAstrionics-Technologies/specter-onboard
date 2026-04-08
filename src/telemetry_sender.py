import os
import time
import math
import httpx
import logging
from pymavlink import mavutil


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
log = logging.getLogger("telemetry-sender")

MAVLINK_SOURCE = os.environ.get("MAVLINK_SOURCE", "COM5")
CLOUD_INGEST_URL = os.environ.get("CLOUD_INGEST_URL", "http://localhost:8000/api/v1/ingest/telemetry")
DRONE_ID = os.environ.get("DRONE_ID", "drone-1")
SEND_INTERVAL = int(os.environ.get("SEND_INTERVAL", 1))


class TelemetrySender:
    def __init__(self):
        self.conn = None
        self.client = httpx.Client(timeout=5)
        self.state = {
            "lat": 0.0,
            "lon": 0.0,
            "alt": 0.0,
            "speed": 0.0,
            "heading": 0,
            "battery": 0.0,
            "voltage": 0.0,
            "armed": False,
            "flight_mode": "UNKNOWN",
            "gps_fix_type": 0,
            "satellites": 0,
        }
        self.fail_count = 0
        self.last_send = 0

    def connect(self):
        """Connect to mavlink-router and wait for first heartbeat."""
        
        log.info(f"Connecting to {MAVLINK_SOURCE}...")
        self.conn = mavutil.mavlink_connection(MAVLINK_SOURCE, baud=115200)
        self.conn.wait_heartbeat()
        self.conn.mav.request_data_stream_send(
            self.conn.target_system,
            self.conn.target_component,
            mavutil.mavlink.MAV_DATA_STREAM_ALL,
            4,     # 4 Hz
            1      # start
        )
        log.info(f"Heartbeat received from system {self.conn.target_system}")

    def update_state(self, msg):

        match msg.get_type():
            case "GLOBAL_POSITION_INT":
                self.state['lat'] = msg.lat / 1e7
                self.state['lon'] = msg.lon / 1e7
                self.state['alt'] = msg.relative_alt / 1000
                self.state['heading'] = msg.hdg / 100

            case "HEARTBEAT":
                new_armed = bool(msg.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
                if new_armed != self.state['armed']:
                    log.info(f"{'Armed' if new_armed else 'Disarmed'}")
                self.state['armed'] = new_armed

                new_mode = mavutil.mode_string_v10(msg)
                if new_mode != self.state['flight_mode']:
                    log.info(f"Flight mode: {self.state['flight_mode']} -> {new_mode}")
                self.state['flight_mode'] = new_mode
            
            case "SYS_STATUS":
                self.state['battery'] = msg.battery_remaining
                self.state['voltage'] = msg.voltage_battery / 1000

            case "ATTITUDE":
                self.state['roll'] = math.degrees(msg.roll)
                self.state['yaw'] = math.degrees(msg.yaw)
                self.state['pitch'] = math.degrees(msg.pitch)
            
            case "VFR_HUD":
                self.state['speed'] = msg.groundspeed

            case "GPS_RAW_INT":
                old_fix = self.state['gps_fix_type']
                self.state['gps_fix_type'] = msg.fix_type
                if old_fix < 3 and msg.fix_type >= 3:
                    log.info(f"GPS 3D fix acquired, satellites={msg.satellites_visible}")
                self.state['satellites'] = msg.satellites_visible

    def build_payload(self):
        payload = {
            "drone_id": DRONE_ID,
            "lat": self.state['lat'],
            "lon": self.state['lon'],
            "alt": self.state['alt'],
            "speed": self.state['speed'],
            "heading": int(self.state['heading']),
            "battery": self.state['battery'],
            "voltage": self.state['voltage'],
            "armed": self.state['armed'],
            "flight_mode": self.state['flight_mode'],
            "gps_fix_type": self.state['gps_fix_type'],
            "satellites": self.state['satellites'],
        }

        return payload

    def send(self, payload):
        try:
            response = self.client.post(CLOUD_INGEST_URL, json=payload)
            if response.status_code == 200:
                if self.fail_count == 0 and self.last_send == 0:
                    log.info("First telemetry sent successfully")
                elif self.fail_count > 0:
                    log.info(f"Cloud connection restored after {self.fail_count} failures")
                self.fail_count = 0
            elif response.status_code < 500:
                log.error(f"Client error: {response.status_code}: {response.text}")
            else:
                self.fail_count += 1
                log.error(f"Server error: {response.status_code}: {response.text}")
        except (httpx.ConnectError, httpx.TimeoutException, httpx.RemoteProtocolError) as e:
            self.fail_count += 1
            log.error(f"Send Failed: {type(e).__name__}")
        
        if self.fail_count >= 30:
            log.error("Cloud connection lost")

    def run(self):
        self.connect()
        while True:
            msg = self.conn.recv_match(blocking=True)
            if msg:
                self.update_state(msg)

            now = time.time()

            if now - self.last_send >= SEND_INTERVAL:
                self.send(self.build_payload())
                self.last_send = now


if __name__ == '__main__':

    log.info(f"Config: drone_id={DRONE_ID} endpoint={CLOUD_INGEST_URL} interval={SEND_INTERVAL}s")
    sender = TelemetrySender()
    sender.run()