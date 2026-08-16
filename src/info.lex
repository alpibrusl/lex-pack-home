# info.lex — the home agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the home-ems persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "home", title: "Home", tagline: "Household sites as governed flex sellers: granted appliances deliver committed sheds, with actuations and meter readings as the evidence.", personas: [{ kind: "home-ems", title: "Home EMS", tagline: "Registers sites, actuates granted-appliance sheds, reports meter readings, and commits sites to flex tenders it can actually deliver.", suggested_prompts: ["Register site casa-1 for owner alfonso with HA sidecar http://127.0.0.1:8900 and a 15 c/kWh ceiling.", "What is the state of site casa-1?", "Deliver a 0.9 kW shed at casa-1 for window 13:00-14:00, ref S-1.", "Commit tender T-100 for seller home-ems-1 with site casa-1."] }] }
}

