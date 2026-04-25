import os
import sys
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
DRONE_API_KEY = os.environ.get("DRONE_API_KEY")
SEND_INTERVAL = int(os.environ.get("SEND_INTERVAL", 1))

if not DRONE_API_KEY:
    log.error("DRONE_API_KEY not set; refusing to start. Set it in /etc/specter/telemetry-sender.env and restart.")
    sys.exit(1)

AUTH_BACKOFF_CAP_SECONDS = 60


class TelemetrySender:
    def __init__(self):
        self.conn = None
        self.client = httpx.Client(timeout=5, headers={"X-API-Key": DRONE_API_KEY})
        # Dev override: set BYPASS_GPS_GATE=1 to start sending immediately with
        # dummy coords. Production keeps the None-until-fix invariant.
        bypass = os.environ.get("BYPASS_GPS_GATE") == "1"
        self.state = {
            "lat": 28.6139 if bypass else None,
            "lon": 77.2090 if bypass else None,
            "alt": 0.0,
            "speed": 0.0,
            "heading": 0,
            "battery": 0.1,
            "voltage": 0.0,
            "armed": False,
            "flight_mode": "UNKNOWN",
            "gps_fix_type": 0,
            "satellites": 0,
        }
        self.fail_count = 0          # transport / 5xx — network-shaped failures
        self.auth_fail_count = 0     # 401 — auth-shaped failures, distinct signal
        self.last_send = 0
        self.next_send_after = 0     # honored during auth backoff
        self.seen_sysids = set()  # for first-time heartbeat source logging

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
        # Log first heartbeat seen from each source sysid for debugging
        if msg.get_type() == "HEARTBEAT":
            src = msg.get_srcSystem()
            if src not in self.seen_sysids:
                self.seen_sysids.add(src)
                log.info(f"Saw heartbeat from sysid={src} (FC sysid={self.conn.target_system})")

        # Only process messages from the flight controller — mavlink-router
        # relays heartbeats from every node on the bus (GCS, companion, etc),
        # which would cause armed/flight_mode to flip between real FC values
        # and zeroed values from non-autopilot sources.
        if msg.get_srcSystem() != self.conn.target_system:
            return

        match msg.get_type():
            case "GLOBAL_POSITION_INT":
                lat = round(msg.lat / 1e7, 6)
                lon = round(msg.lon / 1e7, 6)
                # Ignore (0,0) — FC sends these before GPS lock.
                # Once we have a real position, keep it sticky across packet loss.
                if lat != 0.0 and lon != 0.0:
                    self.state['lat'] = lat
                    self.state['lon'] = lon
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
                # MAVLink sentinels for "field not provided":
                #   battery_remaining = -1, voltage_battery = UINT16_MAX (65535).
                # Skip the assignment so state stays at last-known (or 0.0
                # initial) instead of propagating sentinel values to cloud.
                if msg.battery_remaining >= 0:
                    self.state['battery'] = msg.battery_remaining
                if msg.voltage_battery != 65535:
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
                if self.fail_count == 0 and self.auth_fail_count == 0 and self.last_send == 0:
                    log.info("First telemetry sent successfully")
                elif self.fail_count > 0:
                    log.info(f"Cloud connection restored after {self.fail_count} failures")
                elif self.auth_fail_count > 0:
                    log.info(f"Auth restored after {self.auth_fail_count} rejections")
                self.fail_count = 0
                self.auth_fail_count = 0
                self.next_send_after = 0
            elif response.status_code == 401:
                self.auth_fail_count += 1
                backoff = min(AUTH_BACKOFF_CAP_SECONDS, 2 ** (self.auth_fail_count - 1))
                self.next_send_after = time.time() + backoff
                log.error(f"Auth rejected (401); backing off {backoff}s. Check DRONE_API_KEY.")
            elif response.status_code < 500:
                log.error(f"Client error: {response.status_code}: {response.text}")
            else:
                self.fail_count += 1
                log.error(f"Server error: {response.status_code}: {response.text}")
        except (httpx.ConnectError, httpx.TimeoutException, httpx.RemoteProtocolError) as e:
            self.fail_count += 1
            log.error(f"Send Failed: {type(e).__name__}")

        if self.fail_count == 30:
            log.error("Cloud connection lost")

    def run(self):
        self.connect()
        waiting_for_fix_logged = False
        while True:
            msg = self.conn.recv_match(blocking=True)
            if msg:
                self.update_state(msg)

            now = time.time()

            if now - self.last_send >= SEND_INTERVAL and now >= self.next_send_after:
                # Don't send telemetry until we have a real GPS position.
                # Prevents the dashboard from rendering Null Island (0,0) at startup.
                if self.state['lat'] is None or self.state['lon'] is None:
                    if not waiting_for_fix_logged:
                        log.info("Waiting for first GPS position before sending telemetry...")
                        waiting_for_fix_logged = True
                    self.last_send = now
                    continue

                payload = self.build_payload()
                log.info(
                    f"TX lat={payload['lat']:.6f} lon={payload['lon']:.6f} "
                    f"alt={payload['alt']:.1f} armed={payload['armed']} "
                    f"mode={payload['flight_mode']} fix={payload['gps_fix_type']} "
                    f"sats={payload['satellites']}"
                )
                self.send(payload)
                self.last_send = now


if __name__ == '__main__':

    log.info(f"Config: drone_id={DRONE_ID} endpoint={CLOUD_INGEST_URL} interval={SEND_INTERVAL}s")
    sender = TelemetrySender()
    sender.run()