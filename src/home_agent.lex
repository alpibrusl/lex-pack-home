# home_agent.lex — the household's LLM-driven EMS persona.
#
# Same loopback-HTTP pattern as lex-pack-flex/src/flex_agent.lex for the
# pack's own routes, plus ONE cross-pack backend: the flex market. The home
# EMS is the SELLER side of flex's capacity_tender flow, so its tools split
# in two:
#
#   self_base_url — this pack's own /home/* routes (register, state, shed,
#                   meter): the site it operates.
#   flex_url      — the flex pack's market routes: commit_flex_tender accepts
#                   an open tender on behalf of this household's site. The
#                   delivery evidence flex later checks is served by THIS
#                   pack's EMS-compat routes, so committing here is a promise
#                   the same agent can actually keep — or fail honestly.
#
# The persona's playbook forbids invented facts: state comes from get_site,
# never from memory, and a shed the sidecar refused is reported as refused.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req := http.with_header(req0, "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str) -> [net] jv.Json {
  let req := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn home_capability() -> cap.Capability {
  cap.inbound("handle", "Operate a household site as its energy manager: register the site, read its state, actuate granted-appliance sheds, report meter readings, and commit the site to open flex tenders.", { title: "HomeEms", description: "Inbound message for the home EMS agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self routes + the flex market as a second backend) ─────────────────
fn make_home_tools(self_base_url :: Str, flex_url :: Str) -> List[t.Tool] {
  [t.define("register_site", "Register a household site: its owner, the HA sidecar URL that actuates its appliances, and the owner's tariff ceiling in integer cents per kWh.", { title: "RegisterSite", description: "Site registration.", fields: [sch.required_str("site_id", []), sch.required_str("owner", []), sch.required_str("ha_url", []), sch.required_int("max_price_cents_kwh", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/home/sites"), jv.stringify(args)))
  }), t.define("get_site", "Read a site's registered policy and its chained home.* events. Check this before acting — never assume site state from memory.", { title: "GetSite", description: "Site lookup.", fields: [sch.required_str("site_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(self_base_url, str.concat("/home/sites/", jstr(args, "site_id")))))
  }), t.define("request_shed", "Actuate a shed at a site: the pack asks the site's HA sidecar to stop the deferrable load, and records delivery evidence ONLY if the sidecar confirms. A refusal (grant denial, unreachable sidecar) comes back as an error and no evidence exists.", { title: "RequestShed", description: "Shed actuation.", fields: [sch.required_str("site_id", []), sch.required_str("ref", []), sch.required_float("kw", []), sch.optional(sch.required_str("window", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/home/sites/", jstr(args, "site_id"), "/shed"], ""), jv.stringify(args)))
  }), t.define("report_meter", "Record a meter reading (kW) for a site — the attestor feed flex's settlement evidence check reads.", { title: "ReportMeter", description: "Meter reading.", fields: [sch.required_str("site_id", []), sch.required_float("kw", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/home/sites/", jstr(args, "site_id"), "/meter"], ""), jv.stringify(args)))
  }), t.define("commit_flex_tender", "Accept an open flex tender on behalf of this household, naming the site that will deliver the shed. Only commit what the site can actually deliver — the delivery evidence is checked at settlement.", { title: "CommitFlexTender", description: "Flex tender commit (seller side).", fields: [sch.required_str("tender_ref", []), sch.required_str("seller", []), sch.required_str("site_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([flex_url, "/flex/tenders/", jstr(args, "tender_ref"), "/commit"], ""), jv.stringify(args)))
  })]
}

# ── System prompt ─────────────────────────────────────────────────────────────
fn home_system_prompt(id :: Str) -> Str {
  str.join(["You are home EMS agent ", id, ". You operate one or more household sites: each has an owner, a tariff ceiling in integer cents per kWh, and an HA sidecar that gates every appliance command with the owner's grant.", " Use get_site for a site's ACTUAL state and policy -- never assume it from memory. Use request_shed to deliver a shed; if the sidecar refuses, report the refusal honestly -- there is no delivery evidence for a shed that did not happen. Use report_meter for readings.", " On the flex market you are a SELLER: use commit_flex_tender to accept an open tender only when the named site can actually deliver it in the window -- settlement will re-check the delivery evidence this pack serves.", " Be precise about kW and windows, respect the owner's price ceiling, and always name the site_id and tender_ref you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ───────────────────────
fn make_home_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, flex_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := home_capability()
  let cfg := { id: id, kind: "home-ems", system_prompt: home_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }, { key: "flex_url", url: flex_url }], intent_roles: [], tools: make_home_tools(self_base_url, flex_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Home EMS agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

