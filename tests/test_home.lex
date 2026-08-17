# tests/test_home.lex — pure-logic coverage for src/home.lex.
#
# price_ok and shed_detail are the pure vocabulary (both also carry examples
# blocks that run at `lex check` time); the effectful routes (register, shed,
# meter, the EMS-compat evidence surface) need a live DB + HA sidecar to
# exercise meaningfully — that is a soft-node deployment's integration
# concern, same division as lex-pack-flex documents.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/home" as home

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

# ---- price_ok ---------------------------------------------------------------
# Must agree with lex-robot src/home.lex's wash_allowed: same integers, same
# inclusive ceiling — one policy, two enforcement points.
fn test_price_ok_matches_robot_gate() -> Result[Unit, Str] {
  assert_true(home.price_ok(15, 15) and not home.price_ok(15, 16), "the ceiling is inclusive: 15c allowed at a 15c ceiling, 16c refused")
}

# ---- shed_detail ------------------------------------------------------------
fn test_shed_detail_carries_the_claim() -> Result[Unit, Str] {
  assert_true(home.shed_detail(0.9, "13:00-14:00", "S-1") == "shed 0.9kW window 13:00-14:00 ref S-1", "the evidence detail must name kw, window and ref")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := home.manifest()
  assert_true(list.is_empty(pos.validate(m)), "home's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(home.manifest().route_prefix == "/home", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_same_pattern_as_flex() -> Result[Unit, Str] {
  assert_true(home.manifest().pattern == "capacity_tender", "home is the executor-side half of flex's capacity_tender flow — the two manifests must name the same pattern")
}

fn test_manifest_does_not_settle() -> Result[Unit, Str] {
  assert_true(not home.manifest().settles, "money moves in lex-pack-flex's settlement, never here — settles must be false")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_price_ok_matches_robot_gate(), test_shed_detail_carries_the_claim(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_same_pattern_as_flex(), test_manifest_does_not_settle()]
}

