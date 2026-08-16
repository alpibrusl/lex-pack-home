# tests/test_home_agent.lex — pure-logic coverage for src/home_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error — so, same as lex-pack-flex, this file forces a real
# runtime error when count_failures(...) > 0 to keep lex test/lex ci real
# gates.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/home_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn tools() -> List[t.Tool] {
  agent.make_home_tools("http://127.0.0.1:8100", "http://127.0.0.1:8200")
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(tools(), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_five_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(tools()) == 5, "four self routes plus the flex commit — exactly 5 tools should be defined")
}

fn test_register_site_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("site_id", JStr("casa-1")), ("owner", JStr("alfonso")), ("ha_url", JStr("http://127.0.0.1:8900")), ("max_price_cents_kwh", JInt(15))])
  match schema_of("register_site") {
    None => Err("register_site tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("register_site's schema must accept home.lex's documented POST /home/sites body"),
      Ok(_) => pass(),
    },
  }
}

fn test_request_shed_schema_requires_ref() -> Result[Unit, Str] {
  let bad := JObj([("site_id", JStr("casa-1")), ("kw", JFloat(0.9))])
  match schema_of("request_shed") {
    None => Err("request_shed tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("request_shed's schema must require ref — evidence needs a name"),
    },
  }
}

fn test_request_shed_schema_accepts_without_window() -> Result[Unit, Str] {
  let sample := JObj([("site_id", JStr("casa-1")), ("ref", JStr("S-1")), ("kw", JFloat(0.9))])
  match schema_of("request_shed") {
    None => Err("request_shed tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("request_shed's window is optional and its schema must say so"),
      Ok(_) => pass(),
    },
  }
}

fn test_commit_flex_tender_schema_requires_tender_ref() -> Result[Unit, Str] {
  let bad := JObj([("seller", JStr("home-ems-1")), ("site_id", JStr("casa-1"))])
  match schema_of("commit_flex_tender") {
    None => Err("commit_flex_tender tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("commit_flex_tender's schema must require tender_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_five_tools_defined(), test_register_site_schema_accepts_documented_shape(), test_request_shed_schema_requires_ref(), test_request_shed_schema_accepts_without_window(), test_commit_flex_tender_schema_requires_tender_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

