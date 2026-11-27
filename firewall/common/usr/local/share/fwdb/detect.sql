-- Fills the signal table from the last 26 hours. fw-ingest runs it after each load, so a row's counters are refreshed.
-- Each rule gives: day, kind, dev, target, severity, detail, n, bytes, first_seen, last_seen.
CREATE OR REPLACE TEMP TABLE f AS
  SELECT * FROM flow WHERE "end" >= localtimestamp - INTERVAL 26 HOUR
  UNION ALL SELECT * FROM flow_active;

-- The way an app's own name lookups are written down for its remote addresses
CREATE OR REPLACE TEMP TABLE nm AS
  SELECT dev, ip, arg_max(name, last_seen) AS name FROM remote_name WHERE last_seen >= localtimestamp - INTERVAL 7 DAY GROUP BY 1, 2;
CREATE OR REPLACE TEMP TABLE sni AS
  SELECT remote AS ip, arg_max(name, hour) AS name FROM service_hour WHERE kind <> 'ssh' AND hour >= localtimestamp - INTERVAL 7 DAY GROUP BY 1;
-- Every address any device got from DNS. An address that is not here was not looked up through the firewall.
CREATE OR REPLACE TEMP TABLE known AS SELECT DISTINCT ip FROM remote_name UNION SELECT DISTINCT ip FROM sni;

CREATE OR REPLACE TEMP TABLE s AS
-- 1. Connections from the internet into the LAN. Only the port forwards can make one. A host from the owner's list on a
--    port that the owner expects is 'info', unless it moves 50 MB or more in a day. Another port from that host stays 'high'.
SELECT start::DATE AS day, 'inbound' AS kind, dev, remote || ' -> ' || proto || '/' || coalesce(port::VARCHAR, '-') AS target,
  CASE WHEN NOT coalesce(bool_or(list_contains(string_split(k.ports, ','), proto || '/' || port)), false) THEN 'high'
       WHEN sum(up + down) >= 50 * 1048576 THEN 'medium' ELSE 'info' END AS severity,
  CASE WHEN any_value(k.name) IS NULL THEN 'a connection from the internet reached this device through a port forward'
       WHEN NOT coalesce(bool_or(list_contains(string_split(k.ports, ','), proto || '/' || port)), false)
         THEN 'known host ' || any_value(k.name) || ', but on a port that is not on the owner''s list'
       ELSE 'known host ' || any_value(k.name) || ', expected port' ||
         CASE WHEN sum(up + down) >= 50 * 1048576 THEN ', but a large transfer' ELSE '' END END AS detail,
  count(*) AS n, sum(up + down)::BIGINT AS bytes, min(start) AS first_seen, max("end") AS last_seen
FROM f LEFT JOIN known_host k ON k.ip = f.remote WHERE dir = 'in' GROUP BY 1, 3, 4
UNION ALL
-- 2. Connections from the internet to the firewall itself that were accepted (there should be none).
SELECT start::DATE, 'inbound-firewall', dev, remote || ' -> ' || proto || '/' || coalesce(port::VARCHAR, '-'), 'high',
  'the firewall itself accepted or answered a packet from the internet', count(*), sum(up + down)::BIGINT, min(start), max("end")
FROM f WHERE dir = 'fw-in' GROUP BY 1, 3, 4
UNION ALL
-- 3. Known names: remote access, tunnels, VPNs, relays, encrypted DNS, file sharing, telemetry. From DNS questions.
SELECT hour::DATE, cat, dev, app,
  CASE WHEN cat IN ('tunnel', 'vpn', 'remote-access', 'p2p') THEN 'medium' WHEN cat IN ('relay', 'doh') THEN 'low' ELSE 'info' END,
  'DNS: ' || string_agg(DISTINCT name, ', ' ORDER BY name)[:200] ||
    CASE WHEN sum(blocked) = 0 THEN '' WHEN sum(blocked) >= sum(n) THEN ' (all blocked)' ELSE ' (' || sum(blocked) || ' of ' || sum(n) || ' blocked)' END,
  sum(n)::BIGINT, NULL, min(hour), max(hour)
FROM dns_hour WHERE cat IS NOT NULL AND hour >= localtimestamp - INTERVAL 26 HOUR GROUP BY hour::DATE, cat, dev, app
UNION ALL
-- 4. STUN and TURN: how an app finds its outside address, the first step of UDP hole punching.
SELECT start::DATE, 'stun', f.dev, proto || '/' || port, 'low',
  'STUN/TURN to ' || count(DISTINCT remote) || ' servers: ' || string_agg(DISTINCT coalesce(nm.name, sni.name, remote), ', ')[:160],
  count(*), sum(up + down)::BIGINT, min(start), max("end")
FROM f LEFT JOIN nm ON nm.dev = f.dev AND nm.ip = f.remote LEFT JOIN sni ON sni.ip = f.remote
WHERE dir = 'out' AND port IN (3478, 3479, 5349, 5350, 19302, 19303, 19305, 19307, 19309) GROUP BY start::DATE, f.dev, proto, port
UNION ALL
-- 5. VPN, tunnel and remote-access ports and protocols.
SELECT start::DATE, 'tunnel-port', x.dev, what || ' ' || remote, sev, 'port ' || proto || '/' || coalesce(port::VARCHAR, '-') || ' to ' ||
    coalesce(any_value(nm.name), any_value(sni.name), remote) || CASE WHEN bool_or(replied) THEN '' ELSE ' (no answer)' END,
  count(*), sum(up + down)::BIGINT, min(start), max("end")
FROM (SELECT f.*, CASE
    WHEN proto IN ('gre', 'esp', 'ah', 'ipv6-in-ip') THEN proto || ' tunnel'
    WHEN proto = 'udp' AND port = 1194 OR proto = 'tcp' AND port = 1194 THEN 'OpenVPN'
    WHEN proto = 'udp' AND port BETWEEN 51820 AND 51830 THEN 'WireGuard'
    WHEN proto = 'udp' AND port IN (500, 4500) THEN 'IPsec (or Wi-Fi calling)'
    WHEN port = 1701 THEN 'L2TP' WHEN proto = 'tcp' AND port = 1723 THEN 'PPTP'
    WHEN proto = 'udp' AND port = 9993 THEN 'ZeroTier' WHEN proto = 'udp' AND port = 41641 THEN 'Tailscale'
    WHEN proto = 'udp' AND port = 3544 THEN 'Teredo' WHEN port = 7844 THEN 'Cloudflare Tunnel'
    WHEN port BETWEEN 21114 AND 21119 THEN 'RustDesk' WHEN port IN (5938) THEN 'TeamViewer'
    WHEN port IN (6568, 7070) THEN 'AnyDesk' WHEN proto = 'tcp' AND port = 3389 THEN 'RDP out'
    WHEN proto = 'tcp' AND port BETWEEN 5900 AND 5903 THEN 'VNC out' WHEN port IN (9001, 9030) THEN 'Tor'
    WHEN port IN (22000, 22067, 21027) THEN 'Syncthing' WHEN port IN (6881, 51413) THEN 'BitTorrent'
    WHEN proto = 'tcp' AND port = 1080 THEN 'SOCKS' WHEN proto = 'tcp' AND port = 22 THEN 'SSH out' END AS what,
    CASE WHEN proto = 'udp' AND port IN (500, 4500) OR proto = 'tcp' AND port = 22 THEN 'low' ELSE 'medium' END AS sev
  FROM f WHERE dir = 'out') x
LEFT JOIN nm ON nm.dev = x.dev AND nm.ip = x.remote LEFT JOIN sni ON sni.ip = x.remote
WHERE what IS NOT NULL GROUP BY start::DATE, x.dev, what, remote, sev, proto, port
UNION ALL
-- 6. UDP to addresses that were never looked up, on high ports, answered: direct peers. With STUN from the same device
--    this is UDP hole punching. Games and video calls do it too.
SELECT start::DATE, 'udp-peer', f.dev, 'UDP peers',
  CASE WHEN f.dev IN (SELECT dev FROM f WHERE dir = 'out' AND port IN (3478, 3479, 5349, 19302, 19305)) THEN 'medium' ELSE 'low' END,
  count(DISTINCT remote) || ' peers; answered UDP on high ports to addresses without a DNS lookup; most bytes: ' || arg_max(remote || ':' || port, up + down) ||
  CASE WHEN f.dev IN (SELECT dev FROM f WHERE dir = 'out' AND port IN (3478, 3479, 5349, 19302, 19305)) THEN '; STUN seen: hole punching' ELSE '' END,
  count(*), sum(up + down)::BIGINT, min(start), max("end")
FROM f WHERE dir = 'out' AND proto = 'udp' AND replied AND port > 1024 AND port NOT IN (3478, 3479, 5349, 5350, 19302, 19305)
  AND remote NOT IN (SELECT ip FROM known) GROUP BY 1, 3
UNION ALL
-- 7. Connections open for more than 4 hours: a tunnel must stay open. Push services do it too.
SELECT start::DATE, 'long-connection', f.dev, coalesce(site(coalesce(any_value(nm.name), any_value(sni.name))), remote) || ' ' || proto || '/' || coalesce(port::VARCHAR, '-'),
  CASE WHEN port IN (443, 5223, 5228, 8883, 993, 4070, 8009) OR any_value(nm.name) IS NOT NULL THEN 'info' ELSE 'low' END,
  'longest ' || round(max(epoch("end" - start)) / 3600.0, 1) || ' h to ' || coalesce(any_value(nm.name), any_value(sni.name), remote),
  count(*), sum(up + down)::BIGINT, min(start), max("end")
FROM f LEFT JOIN nm ON nm.dev = f.dev AND nm.ip = f.remote LEFT JOIN sni ON sni.ip = f.remote
WHERE dir = 'out' AND replied AND "end" - start > INTERVAL 4 HOUR GROUP BY start::DATE, f.dev, remote, proto, port
UNION ALL
-- 8. Much more sent than received, over 200 MB to one place: backup, camera, or data leaving the house.
SELECT hour::DATE, 'upload', dev, service, 'low', mb(sum(up)) || ' MB sent, ' || mb(sum(down)) || ' MB received, ' || coalesce(any_value(org), ''),
  sum(conns)::BIGINT, sum(up)::BIGINT, min(hour), max(hour)
FROM traffic WHERE dir = 'out' AND hour >= localtimestamp - INTERVAL 26 HOUR GROUP BY 1, 3, 4
HAVING sum(up) > 200 * 1048576 AND sum(up) > 3 * sum(down)
UNION ALL
-- 9. A device asked the firewall for a port mapping (NAT-PMP or PCP). The firewall has no such service.
SELECT ts::DATE, 'port-mapping', src, 'NAT-PMP/PCP request', 'medium', 'asked the router to open a port; refused, no such service here',
  count(*), NULL, min(ts), max(ts)
FROM drops WHERE prefix = 'DROP_LAN' AND dport = 5351 AND ts >= localtimestamp - INTERVAL 26 HOUR GROUP BY 1, 3
UNION ALL
-- 10. DNS over TLS that the firewall reset.
SELECT ts::DATE, 'dot-bypass', src, dst, 'low', 'DNS over TLS (853) reset by the firewall', count(*), NULL, min(ts), max(ts)
FROM drops WHERE prefix = 'DROP_DOT' AND ts >= localtimestamp - INTERVAL 26 HOUR GROUP BY 1, 3, 4
UNION ALL
-- 11. A LAN device tried to reach an address on a blocklist.
SELECT ts::DATE, 'blocked-destination', src, dst, 'high', prefix || ' ' || proto || '/' || coalesce(dport::VARCHAR, '-'), count(*), NULL, min(ts), max(ts)
FROM drops WHERE prefix IN ('DROP_BLOUT', 'DROP_GEO') AND ts >= localtimestamp - INTERVAL 26 HOUR GROUP BY ts::DATE, src, dst, prefix, proto, dport
UNION ALL
-- 12. Beacons: the same address and port at an even rhythm, 24 or more times, 1 minute to 2 hours apart.
SELECT d, 'beacon', dev, coalesce(site(name), remote) || ' ' || proto || '/' || coalesce(port::VARCHAR, '-'), CASE WHEN name IS NULL THEN 'medium' ELSE 'info' END,
  'every ' || round(avg_gap) || ' s (variation ' || round(100 * sd / avg_gap) || '%) to ' || coalesce(name, remote), n, bytes, a, b
FROM (SELECT g.d, g.dev, g.remote, g.proto, g.port, any_value(coalesce(nm.name, sni.name)) AS name, count(*) AS n, avg(gap) AS avg_gap, stddev(gap) AS sd,
    sum(bytes)::BIGINT AS bytes, min(start) AS a, max(start) AS b
  FROM (SELECT start::DATE AS d, dev, remote, proto, port, start, up + down AS bytes,
      epoch(start - lag(start) OVER (PARTITION BY dev, remote, proto, port ORDER BY start)) AS gap
    FROM f WHERE dir = 'out' AND port NOT IN (123)) g
  LEFT JOIN nm ON nm.dev = g.dev AND nm.ip = g.remote LEFT JOIN sni ON sni.ip = g.remote
  WHERE gap IS NOT NULL GROUP BY g.d, g.dev, g.remote, g.proto, g.port) z
WHERE n >= 24 AND avg_gap BETWEEN 60 AND 7200 AND sd < 0.1 * avg_gap
UNION ALL
-- 13. A device the firewall has not seen before.
SELECT first_seen::DATE, 'new-device', coalesce(ip, '?'), mac, 'medium',
  'first seen; name ' || coalesce(friendly, nullif(hostname, '*'), '-') || ', maker ' || coalesce(vendor, '-') ||
  CASE WHEN random_mac THEN ' (private Wi-Fi address: may be a known phone)' ELSE '' END, 1, NULL, first_seen, last_seen
FROM device WHERE first_seen >= localtimestamp - INTERVAL 26 HOUR AND first_seen > (SELECT min(first_seen) + INTERVAL 1 DAY FROM device)
UNION ALL
-- 14. Intrusion rules (Suricata), one row per rule and device. Severity 1 is the most serious.
SELECT ts::DATE, 'alert', CASE WHEN is_lan(src) THEN src WHEN is_lan(dst) THEN dst ELSE coalesce(src, '-') END, coalesce(signature, sid::VARCHAR),
  CASE WHEN max(severity) = 1 THEN 'medium' WHEN max(severity) = 2 THEN 'low' ELSE 'info' END,
  'sid ' || any_value(sid) || ', ' || coalesce(any_value(category), '-') || ', e.g. ' || coalesce(any_value(src || ' -> ' || dst || ':' || dport), '-'),
  count(*), NULL, min(ts), max(ts)
FROM alert WHERE ts >= localtimestamp - INTERVAL 26 HOUR GROUP BY 1, 3, 4
UNION ALL
-- 15. A LAN device that tries many ports or addresses on the firewall or gets its forwards refused.
SELECT ts::DATE, 'lan-scan', src, prefix, 'medium', count(DISTINCT dst || ':' || dport) || ' different targets refused', count(*), NULL, min(ts), max(ts)
FROM drops WHERE prefix IN ('DROP_LAN', 'DROP_FWD') AND is_lan(src) AND ts >= localtimestamp - INTERVAL 26 HOUR GROUP BY 1, 3, 4
HAVING count(DISTINCT dst || ':' || dport) >= 30;

INSERT INTO signal
  SELECT day, kind, dev, target, arg_max(severity, n), arg_max(detail, n), sum(n)::BIGINT, sum(bytes)::BIGINT, min(first_seen), max(last_seen)
  FROM s WHERE day IS NOT NULL AND dev IS NOT NULL AND target IS NOT NULL GROUP BY 1, 2, 3, 4
  ON CONFLICT DO UPDATE SET severity = excluded.severity, detail = excluded.detail, n = greatest(n, excluded.n),
    bytes = greatest(bytes, excluded.bytes), first_seen = least(first_seen, excluded.first_seen), last_seen = greatest(last_seen, excluded.last_seen);
