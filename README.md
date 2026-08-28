# lex-pack-home

Home domain pack — the household as a party. Granted appliances deliver committed flexibility, and the appliance actuations plus meter readings are the delivery evidence: the **executor-side half** of [`lex-pack-flex`](https://github.com/alpibrusl/lex-pack-flex)'s `capacity_tender` flow (flex tenders and settles; home delivers and evidences).

The actuation behind a shed is the site's own **HA sidecar** ([`lex-robot`](https://github.com/alpibrusl/lex-robot)'s `sidecar/ha_sidecar.py` — a runtime HTTP dependency recorded per site, not a `lex.toml` dependency), which gates every appliance command with the household's grant. Evidence honesty is the design rule: a `limit_updated` entry is recorded **only** when the sidecar confirmed the actuation — this pack never mints evidence for things that did not happen.

## Routes

```
POST /home/sites              — {site_id, owner, ha_url, max_price_cents_kwh}
GET  /home/sites/:id          — site + policy + its chained home.* events
POST /home/sites/:id/shed     — {ref, kw, window}: actuate via the HA sidecar
POST /home/sites/:id/meter    — {kw}: record a reading
GET  /api/v1/sites/:id/events — EMS-compat evidence surface: [{event_type, detail}]
GET  /api/v1/sites/:id/meter  — EMS-compat: [{kw}]
```

The two `/api/v1/...` routes serve exactly the surface `lex-pack-flex`'s settlement evidence check reads (`limit_updated` entries + newest meter reading) — point flex's `ems_url` at a mounted home pack and a household site becomes a checkable flex seller with **zero flex changes**.

## Usage

```lex
import "lex-pack-home/home" as home

# in your router-wiring code:
let r := home.mount(router.new(), db)
```

`home.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue. Prices are integer cents per kWh throughout — never floats in a budget.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the positions catalogue) → a soft-node deployment mounting it alongside `lex-pack-flex` (the market it sells into). Device control lives in `lex-robot` (the HA sidecar and its grants); cross-party mechanism lives here and in flex — one market described from its two ends.

## License


Copyright (c) 2026 lex-pack-home contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

