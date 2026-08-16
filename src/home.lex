# home.lex — the household as a party: sites, shed actuation, and the
# EMS-shaped evidence surface (home pack).
#
# The house is the EXECUTOR side of the capacity_tender pattern lex-pack-flex
# coordinates: flex posts and settles tenders; this pack is where a committed
# household site actually DELIVERS — and where the delivery evidence flex
# re-checks comes from. The interop is deliberate and narrow:
#
#   * flex.mount(r, db, ems_url) checks `GET <ems_url>/api/v1/sites/:id/events`
#     for `limit_updated` entries and `GET .../meter` for readings before any
#     money moves. This pack SERVES that exact surface for household sites, so
#     a soft-node can point flex's ems_url at the home pack and a house
#     becomes a checkable flex seller with zero flex changes.
#   * The actuation behind a shed is the site's own HA sidecar
#     (lex-robot's sidecar/ha_sidecar.py — a runtime HTTP dependency recorded
#     per site, not a lex.toml dependency), which gates every command with
#     the household's grant before anything touches an appliance.
#
# Evidence honesty: a shed event is recorded ONLY when the sidecar confirmed
# the actuation (`reached`). A failed or unbacked actuation is a refused
# request, not evidence — this pack never mints `limit_updated` entries for
# things that did not happen.
#
#   POST /home/sites             — {site_id, owner, ha_url, max_price_cents_kwh}
#   GET  /home/sites/:id         — site + policy + its chained events
#   POST /home/sites/:id/shed    — {ref, kw, window}: actuate via the HA sidecar
#   POST /home/sites/:id/meter   — {kw}: record a reading
#   GET  /api/v1/sites/:id/events — EMS-compat: [{event_type, detail}]
#   GET  /api/v1/sites/:id/meter  — EMS-compat: [{kw}]
#
# Prices are integer cents per kWh — never floats in a budget.

import "std.str" as str

import "std.list" as list

import "std.float" as float

import "std.int" as int

import "std.time" as time

import "std.sql" as sql

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn jnum(j :: jv.Json, k :: Str) -> Float {
  match jv.get_field(j, k) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    _ => 0.0,
  }
}

fn jint_of(j :: jv.Json, k :: Str) -> Int {
  match jv.get_field(j, k) {
    Some(JInt(n)) => n,
    Some(JFloat(v)) => float.to_int(v),
    _ => 0,
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_float(row :: sql.Row, k :: Str) -> Float {
  match sql.get_float(row, k) {
    Some(v) => v,
    None => 0.0,
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# ── the owner's price gate (pure, part of the pack's public vocabulary) ──────
# May an appliance cycle start at this price? Integer cents per kWh; the
# ceiling is the owner's registered policy. Same examples-tested shape as
# lex-robot's wash_allowed — the two must agree, and both say so in tests.
fn price_ok(max_price_cents_kwh :: Int, price_cents_kwh :: Int) -> Bool
  examples {
    price_ok(15, 11) => true,
    price_ok(15, 15) => true,
    price_ok(15, 32) => false,
    price_ok(0, 1) => false
  }
{
  price_cents_kwh <= max_price_cents_kwh
}

# The human-readable delivery detail a shed event carries — the same string
# the EMS-compat events route serves back to flex's evidence check.
fn shed_detail(kw :: Float, window :: Str, ref :: Str) -> Str
  examples {
    shed_detail(0.9, "13:00-14:00", "S-1") => "shed 0.9kW window 13:00-14:00 ref S-1",
    shed_detail(2.0, "", "") => "shed 2kW window ? ref ?"
  }
{
  let w := if str.is_empty(window) {
    "?"
  } else {
    window
  }
  let r := if str.is_empty(ref) {
    "?"
  } else {
    ref
  }
  str.join(["shed ", float.to_str(kw), "kW window ", w, " ref ", r], "")
}

# Portable DDL (SQLite + Postgres): TEXT / DOUBLE PRECISION / BIGINT only —
# same rule flex.lex documents.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __s := sql.exec(db, "CREATE TABLE IF NOT EXISTS home_sites (site_id TEXT PRIMARY KEY, owner TEXT NOT NULL, ha_url TEXT NOT NULL DEFAULT '', max_price_cents_kwh BIGINT NOT NULL DEFAULT 0, created_ms BIGINT NOT NULL)", [])
  let __d := sql.exec(db, "CREATE TABLE IF NOT EXISTS home_sheds (ref TEXT NOT NULL, site_id TEXT NOT NULL, kw DOUBLE PRECISION NOT NULL DEFAULT 0, window_label TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '', ts_ms BIGINT NOT NULL)", [])
  let __m := sql.exec(db, "CREATE TABLE IF NOT EXISTS home_meter (site_id TEXT NOT NULL, kw DOUBLE PRECISION NOT NULL DEFAULT 0, ts_ms BIGINT NOT NULL)", [])
  ()
}

type Site = { owner :: Str, ha_url :: Str, max_price_cents_kwh :: Int }

fn site_for(db :: Db, site_id :: Str) -> [sql] Option[Site] {
  match sql.query(db, "SELECT owner, ha_url, max_price_cents_kwh FROM home_sites WHERE site_id = ?", [PStr(site_id)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ owner: row_str(row, "owner"), ha_url: row_str(row, "ha_url"), max_price_cents_kwh: row_int(row, "max_price_cents_kwh") }),
    },
  }
}

# The site's own event chain, keyed by site_id — same shape as flex's
# tender_events.
fn site_events(db :: Db, site_id :: Str) -> [sql] List[jv.Json] {
  let pat := str.concat("%\"site_id\":", str.concat(jv.stringify(JStr(site_id)), "%"))
  match sql.query(db, "SELECT id, kind, ts_ms FROM events WHERE kind LIKE 'home.%' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> jv.Json {
      JObj([("event_id", JStr(row_str(row, "id"))), ("kind", JStr(row_str(row, "kind"))), ("ts_ms", JInt(row_int(row, "ts_ms")))])
    }),
  }
}

# Ask the site's HA sidecar to stop the deferrable load. The sidecar's own
# grant decides — a denial there comes back verbatim and no evidence is
# recorded here.
fn ha_stop(ha_url :: Str, entity :: Str) -> [net] Result[Str, Str] {
  let url := str.concat(ha_url, "/skill/appliance_stop")
  let body := str.join(["{\"entity\":\"", entity, "\"}"], "")
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(15000) }
  let req := http.with_header(req0, "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => Err(str.concat("HA sidecar unreachable at ", ha_url)),
    Ok(res) => match bytes.to_str(res.body) {
      Err(_) => Err("HA sidecar returned an undecodable body"),
      Ok(s) => Ok(s),
    },
  }
}

fn site_json(site_id :: Str, s :: Site, events :: List[jv.Json]) -> jv.Json {
  JObj([("site_id", JStr(site_id)), ("owner", JStr(s.owner)), ("ha_url", JStr(s.ha_url)), ("max_price_cents_kwh", JInt(s.max_price_cents_kwh)), ("events", JList(events))])
}

fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_register := router.route_effectful(r, "POST", "/home/sites", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let site_id := jstr(j, "site_id")
        let owner := jstr(j, "owner")
        let ha_url := jstr(j, "ha_url")
        let ceiling := jint_of(j, "max_price_cents_kwh")
        if str.is_empty(site_id) or str.is_empty(owner) {
          resp.bad_request("{\"error\":\"site_id and owner are required\"}")
        } else {
          match sql.exec(db, "INSERT INTO home_sites (site_id, owner, ha_url, max_price_cents_kwh, created_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT (site_id) DO NOTHING", [PStr(site_id), PStr(owner), PStr(ha_url), PInt(ceiling), PInt(time.now_ms())]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("site_id", JStr(site_id)), ("owner", JStr(owner)), ("ha_url", JStr(ha_url)), ("max_price_cents_kwh", JInt(ceiling))]))
              let __e := tlog.append(log, "home.site_registered", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("site_id", JStr(site_id)), ("owner", JStr(owner)), ("max_price_cents_kwh", JInt(ceiling))])))
            },
          }
        }
      },
    }
  })
  let with_get := router.route_effectful(with_register, "GET", "/home/sites/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let site_id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match site_for(db, site_id) {
      None => resp.json_status(404, "{\"error\":\"unknown site\"}"),
      Some(s) => resp.json(jv.stringify(site_json(site_id, s, site_events(db, site_id)))),
    }
  })
  let with_shed := router.route_effectful(with_get, "POST", "/home/sites/:id/shed", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let site_id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "ref")
        let kw := jnum(j, "kw")
        let window := jstr(j, "window")
        if str.is_empty(ref) or kw <= 0.0 {
          resp.bad_request("{\"error\":\"ref and a kw > 0 are required\"}")
        } else {
          match site_for(db, site_id) {
            None => resp.json_status(404, "{\"error\":\"unknown site\"}"),
            Some(s) => if str.is_empty(s.ha_url) {
              resp.json_status(409, "{\"error\":\"site has no ha_url backend: nothing to actuate, so no evidence can be recorded\"}")
            } else {
              match ha_stop(s.ha_url, "washer.main") {
                Err(e) => resp.json_status(409, str.concat("{\"error\":", str.concat(jv.stringify(JStr(str.concat("actuation failed: ", e))), "}"))),
                Ok(out) => if str.contains(out, "\"reached\"") {
                  let detail := shed_detail(kw, window, ref)
                  match sql.exec(db, "INSERT INTO home_sheds (ref, site_id, kw, window_label, detail, ts_ms) VALUES (?, ?, ?, ?, ?, ?)", [PStr(ref), PStr(site_id), PFloat(kw), PStr(window), PStr(detail), PInt(time.now_ms())]) {
                    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                    Ok(_) => {
                      let log := settlement.trail_on(db)
                      let payload := jv.stringify(JObj([("site_id", JStr(site_id)), ("ref", JStr(ref)), ("kw", JFloat(kw)), ("window", JStr(window)), ("detail", JStr(detail))]))
                      let __e := tlog.append(log, "home.limit_updated", None, payload)
                      resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("site_id", JStr(site_id)), ("ref", JStr(ref)), ("detail", JStr(detail))])))
                    },
                  }
                } else {
                  resp.json_status(409, str.concat("{\"error\":", str.concat(jv.stringify(JStr(str.concat("sidecar refused the actuation, no evidence recorded: ", out))), "}")))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_meter := router.route_effectful(with_shed, "POST", "/home/sites/:id/meter", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let site_id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let kw := jnum(j, "kw")
        match site_for(db, site_id) {
          None => resp.json_status(404, "{\"error\":\"unknown site\"}"),
          Some(_) => match sql.exec(db, "INSERT INTO home_meter (site_id, kw, ts_ms) VALUES (?, ?, ?)", [PStr(site_id), PFloat(kw), PInt(time.now_ms())]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("site_id", JStr(site_id)), ("kw", JFloat(kw))]))
              let __e := tlog.append(log, "home.meter_reading", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("site_id", JStr(site_id)), ("kw", JFloat(kw))])))
            },
          },
        }
      },
    }
  })
  let with_ems_events := router.route_effectful(with_meter, "GET", "/api/v1/sites/:id/events", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let site_id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match sql.query(db, "SELECT detail FROM home_sheds WHERE site_id = ? ORDER BY ts_ms DESC", [PStr(site_id)]) {
      Err(_) => resp.json("[]"),
      Ok(rows) => resp.json(jv.stringify(JList(list.map(rows, fn (row :: sql.Row) -> jv.Json {
        JObj([("event_type", JStr("limit_updated")), ("detail", JStr(row_str(row, "detail")))])
      })))),
    }
  })
  router.route_effectful(with_ems_events, "GET", "/api/v1/sites/:id/meter", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let site_id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match sql.query(db, "SELECT kw FROM home_meter WHERE site_id = ? ORDER BY ts_ms DESC", [PStr(site_id)]) {
      Err(_) => resp.json("[]"),
      Ok(rows) => resp.json(jv.stringify(JList(list.map(rows, fn (row :: sql.Row) -> jv.Json {
        JObj([("kw", JFloat(row_float(row, "kw")))])
      })))),
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words.
# Same capacity_tender pattern as lex-pack-flex — deliberately: home is the
# EXECUTOR-side half of the same flow flex coordinates, so the two manifests
# describe one market from its two ends. No custody chain (the subject is a
# site, not a thing that changes hands) and settles is FALSE: money moves in
# flex's settlement, never here.
fn manifest() -> pos.PackManifest {
  { id: "home", title: "Home", tagline: "A household site delivers committed flexibility, with its appliance actuations and meter readings as the evidence.", pattern: "capacity_tender", subject: "site", subject_ref_field: "site_id", custody_ref_field: "", parties: [{ position: "originator", name: "owner", title: "Owner — sets the site's price ceiling and grants the appliances", field: "owner", required: true }, { position: "executor", name: "home-ems", title: "Home EMS — actuates granted appliances to deliver a committed shed", field: "site_id", required: true }, { position: "attestor", name: "meter", title: "Meter — the site reading delivery evidence is read from", field: "site_id", required: false }], relationships: [{ from: "owner", to: "home-ems", role: "contracted", label: "the owner's policy and grants bound what the EMS may actuate" }, { from: "meter", to: "home-ems", role: "reporting", label: "meter readings evidence the delivered shed" }], event_kinds: ["home.site_registered", "home.limit_updated", "home.meter_reading"], evidence_kinds: ["meter_reading", "ems_event"], settles: false, route_prefix: "/home" }
}

