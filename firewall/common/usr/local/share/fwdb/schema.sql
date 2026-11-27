-- /var/lib/fwdb/fwlog.duckdb. All times are the house's local time (@@TIME_ZONE@@), TIMESTAMP without zone.
CREATE TABLE IF NOT EXISTS ingest_state (path VARCHAR PRIMARY KEY, inode UBIGINT, pos UBIGINT);
-- Bytes per minute: device, remote, protocol and port. up = sent by the device.
-- dir: out (LAN to internet), in (internet to LAN), hairpin, fw-out, fw-in, fw-in-lan (LAN to the firewall).
CREATE TABLE IF NOT EXISTS flow_min (ts TIMESTAMP, dir VARCHAR, dev VARCHAR, remote VARCHAR, proto VARCHAR, port INTEGER,
  up BIGINT, down BIGINT, conns INTEGER);
CREATE TABLE IF NOT EXISTS flow_hour (hour TIMESTAMP, dir VARCHAR, dev VARCHAR, remote VARCHAR, proto VARCHAR, port INTEGER,
  up BIGINT, down BIGINT, conns INTEGER);
-- One row for each finished connection.
CREATE TABLE IF NOT EXISTS flow (start TIMESTAMP, "end" TIMESTAMP, dir VARCHAR, dev VARCHAR, remote VARCHAR, proto VARCHAR,
  dev_port INTEGER, port INTEGER, replied BOOLEAN, up BIGINT, down BIGINT);
-- Connections open now for more than 30 minutes, and every open connection from the internet (replaced at each load).
CREATE TABLE IF NOT EXISTS flow_active AS SELECT * FROM flow LIMIT 0;
-- DNS questions per hour, device and name. blocked = stopped by a DNS blocklist. cat and app come from signatures.tsv.
CREATE TABLE IF NOT EXISTS dns_hour (hour TIMESTAMP, dev VARCHAR, name VARCHAR, n INTEGER, nxdomain INTEGER, blocked INTEGER,
  cat VARCHAR, app VARCHAR, PRIMARY KEY (hour, dev, name));
-- Which name a device looked up to get an address.
CREATE TABLE IF NOT EXISTS remote_name (dev VARCHAR, ip VARCHAR, name VARCHAR, first_seen TIMESTAMP, last_seen TIMESTAMP,
  PRIMARY KEY (dev, ip, name));
-- Names seen inside connections (Suricata): kind tls, quic, http, ssh. For ssh, name is the client software.
CREATE TABLE IF NOT EXISTS service_hour (hour TIMESTAMP, dev VARCHAR, remote VARCHAR, port INTEGER, kind VARCHAR, name VARCHAR,
  n INTEGER, cat VARCHAR, app VARCHAR, PRIMARY KEY (hour, dev, remote, port, kind, name));
CREATE TABLE IF NOT EXISTS alert (ts TIMESTAMP, sid BIGINT, signature VARCHAR, category VARCHAR, severity INTEGER,
  src VARCHAR, sport INTEGER, dst VARCHAR, dport INTEGER, proto VARCHAR);
-- nftables log lines. prefix: DROP_WAN, DROP_LAN, DROP_FWD, DROP_BLOUT, DROP_DOT, ... The WAN address is stored as 'wan'.
CREATE TABLE IF NOT EXISTS drops (ts TIMESTAMP, prefix VARCHAR, in_if VARCHAR, out_if VARCHAR, src VARCHAR, dst VARCHAR,
  proto VARCHAR, sport INTEGER, dport INTEGER);
CREATE TABLE IF NOT EXISTS system_event (ts TIMESTAMP, host VARCHAR, tag VARCHAR, msg VARCHAR);
CREATE TABLE IF NOT EXISTS device (mac VARCHAR PRIMARY KEY, ip VARCHAR, hostname VARCHAR, friendly VARCHAR, vendor VARCHAR,
  random_mac BOOLEAN, first_seen TIMESTAMP, last_seen TIMESTAMP);
CREATE TABLE IF NOT EXISTS device_ip (mac VARCHAR, ip VARCHAR, first_seen TIMESTAMP, last_seen TIMESTAMP, PRIMARY KEY (mac, ip));
-- Owner network of each remote address (iptoasn.com).
CREATE TABLE IF NOT EXISTS remote_net (ip VARCHAR PRIMARY KEY, asn BIGINT, country VARCHAR, org VARCHAR);
-- Things worth a look, one row per day, kind, device and target. severity: high, medium, low, info.
CREATE TABLE IF NOT EXISTS signal (day DATE, kind VARCHAR, dev VARCHAR, target VARCHAR, severity VARCHAR, detail VARCHAR,
  n BIGINT, bytes BIGINT, first_seen TIMESTAMP, last_seen TIMESTAMP, PRIMARY KEY (day, kind, dev, target));
-- History from @@LOG_HOST@@ (router syslog, 2026-10-25 to the move).
CREATE TABLE IF NOT EXISTS legacy_event (id BIGINT, recv_time TIMESTAMP, event_time TIMESTAMP, device VARCHAR, facility VARCHAR,
  severity VARCHAR, src VARCHAR, dst VARCHAR, action VARCHAR, proto VARCHAR, sport INTEGER, dport INTEGER, msg VARCHAR);

CREATE OR REPLACE MACRO site(name) AS
  CASE WHEN name IS NULL THEN NULL
       WHEN regexp_matches(name, '\.(co|com|org|net|gov|ac)\.[a-z]{2}$') THEN regexp_extract(name, '([^.]+\.[^.]+\.[^.]+)$', 1)
       WHEN regexp_matches(name, '[^.]+\.[^.]+$') THEN regexp_extract(name, '([^.]+\.[^.]+)$', 1) ELSE name END;
CREATE OR REPLACE MACRO mb(b) AS round(b / 1048576.0, 1);
CREATE OR REPLACE MACRO is_lan(ip) AS starts_with(ip, '@@LAN_PREFIX@@.');

CREATE OR REPLACE VIEW device_name AS
  SELECT ip, arg_max(coalesce(friendly, nullif(hostname, '*'), vendor, mac), last_seen) AS device, arg_max(mac, last_seen) AS mac
  FROM device WHERE ip IS NOT NULL GROUP BY ip;
-- One best name per (device, remote) and per remote.
CREATE OR REPLACE VIEW best_name_dev AS
  SELECT dev, ip, arg_max(name, last_seen) AS name FROM remote_name GROUP BY 1, 2;
CREATE OR REPLACE VIEW best_name AS
  SELECT ip, arg_max(name, p) AS name FROM (
    SELECT ip, name, last_seen AS p FROM remote_name
    UNION ALL SELECT remote, name, hour FROM service_hour WHERE kind <> 'ssh') GROUP BY 1;
-- The owner's list of outside addresses the owner knows, reloaded from known-hosts.tsv on each run. A label only: it opens
-- nothing. ports = the inbound ports the owner expects from that address, such as tcp/443,udp/443. No primary key, because
-- fw-ingest deletes and fills it in one transaction.
CREATE TABLE IF NOT EXISTS known_host (ip VARCHAR, name VARCHAR, relation VARCHAR, ports VARCHAR, note VARCHAR);
-- Traffic per hour with readable names. service = the owner's name for a known host, site name, network owner, or address.
CREATE OR REPLACE VIEW traffic AS
  SELECT f.hour, f.dir, f.dev, coalesce(d.device, f.dev) AS device, f.remote, coalesce(bd.name, b.name) AS name,
    coalesce(k.name, site(coalesce(bd.name, b.name)), r.org, f.remote) AS service, r.org, r.country, f.proto, f.port, f.up, f.down, f.conns
  FROM flow_hour f LEFT JOIN device_name d ON d.ip = f.dev
  LEFT JOIN best_name_dev bd ON bd.dev = f.dev AND bd.ip = f.remote
  LEFT JOIN best_name b ON b.ip = f.remote LEFT JOIN remote_net r ON r.ip = f.remote
  LEFT JOIN known_host k ON k.ip = f.remote;
-- The same per minute, for the last 14 days.
CREATE OR REPLACE VIEW traffic_min AS
  SELECT f.ts, f.dir, f.dev, coalesce(d.device, f.dev) AS device, f.remote, coalesce(bd.name, b.name) AS name,
    coalesce(k.name, site(coalesce(bd.name, b.name)), r.org, f.remote) AS service, r.org, r.country, f.proto, f.port, f.up, f.down, f.conns
  FROM flow_min f LEFT JOIN device_name d ON d.ip = f.dev
  LEFT JOIN best_name_dev bd ON bd.dev = f.dev AND bd.ip = f.remote
  LEFT JOIN best_name b ON b.ip = f.remote LEFT JOIN remote_net r ON r.ip = f.remote
  LEFT JOIN known_host k ON k.ip = f.remote;
