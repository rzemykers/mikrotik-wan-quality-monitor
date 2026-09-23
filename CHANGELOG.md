# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-23

Installation no longer needs Python — or anything at all beyond the router.

### Changed

- **Pure-RouterOS install**: edit a config template, upload the `wanqm-*.rsc` sources,
  `/import INSTALL.rsc`. The installer reads the uploaded files with `/file read` and
  writes them into the script store — no escaping, no generation step. Requires
  RouterOS 7.13+.
- **Everything installs disabled.** The installer preflights the config against the live
  router (exactly four targets, priorities sane, VRRP/WAN interfaces present, token not
  a placeholder), refuses to touch anything on a broken config, and ends by printing the
  enable commands for your role. A re-import over a running install re-enables
  automatically, so "edit config, re-import" stays one step.
- **The netwatch fuses are config-driven.** Both entries share the same two scripts
  (`wanqm-fuse-down.rsc`, `wanqm-fuse-up.rsc`), which read the VRRP name, `PrioBad` and
  `PrioGood` from the config at run time; the "both targets down" gate counts `down`
  entries instead of naming its partner. The up-script now exists on both roles but
  only acts where the orchestrator is not running.
- `wanqm-config` is installed with `policy=read` and `wanqm-notify` with
  `read,write,test` so the netwatch fuse can run them.
- `build_install.py` is now the *optional* scripted path: same sources, same disabled
  install, same enable listing, tokens injected from `secrets.local`.

### Fixed

- **The fuse's "measurement alive" gate never actually worked.** Netwatch scripts run
  in their own global-variable environment, fully isolated from the schedulers' one
  (verified live on ROS 7.24, in both directions), so the old heartbeat check silently
  read nothing and always judged the measurement dead. The gate is rebuilt on state
  netwatch *can* see: the probe scheduler's disabled flag, a `MEASUREMENT-DEAD` marker
  the watchdog mirrors into its comment, and the probe script's `run-count` sampled
  12 s apart.
- For the same reason the `WanQmFusePending` relay (fuse stages alert text, probe sends
  it) could never fire; the fuse now runs `wanqm-notify` directly, which was verified
  to work from the netwatch context.
- Both fuse entries used to fire in lockstep and write the VRRP priority twice — two
  VRRP FSM resets instead of one (observed live; `:rndnum` jitter still collided). The
  entries now de-synchronize deterministically: `wanqm-fuse-1` acts first, everyone
  else waits 3 s and lands on the `cur != target` guard.
- An un-edited config left `WanQmCfgSmsTo` as the `__SMS_TO__` placeholder, which
  passed the `__UNSET__` check and made every `crit` alert attempt an SMS. The SMS
  channel is now skipped for any `__…__` value.

### Removed

- The dead `WanQmFusePending` relay block in `wanqm-probe` and the fuse's
  `WanQmLastPrioChange` bookkeeping — both invisible across the environment isolation
  described above.
- The primary profile no longer disables pre-existing 5-second netwatch entries — that
  was a leftover of the author's own migration and could have hit unrelated netwatches
  on other people's routers.

## [0.1.0] - 2026-09-21

First public release. The code has been running in production since July 2026 on a
two-router setup — a primary on fibre and a metered LTE backup — and is published
essentially as it runs there, with private addresses, hostnames and tokens replaced by
documentation values.

### Added

- Four-probe measurement layer: 5 pings per target on a 10 s tick, rolling windows of
  loss / RTT / jitter (L = 12 ticks, S = 3 ticks).
- Per-probe verdicts with a threshold dead zone, majority voting (FAIL ≥ 3 of 4,
  DEGRADED ≥ 2 of 4), and a state machine with streaks and dwell times.
- `wanqm-orchestrator` as the single writer of VRRP priority, with hold-down, a flap
  counter and a freeze window.
- Two netwatch fuses as a backstop for the case where the scripts themselves die, gated
  on heartbeat freshness so they cannot fight the FSM.
- `wanqm-notify`: one funnel for every alert, with incident correlation — the first
  non-OK event opens an incident, later events append, and the recovery closes it with
  the full timeline in a single message.
- Configurable webhook request shape: `WanQmCfgNotifyHeaders` / `...Body` and the SMS
  equivalents, with `%MESSAGE%` `%SEVERITY%` `%ROUTER%` `%LINK%` `%INCIDENT%` `%TOKEN%`
  `%TO%` placeholders. Defaults reproduce the original hardcoded shape.
- `build_install.py` with `primary` and `backup` profiles; secrets are injected from
  `secrets.local` so the sources stay shareable, and the generated installer is written
  with mode 600.
- `docs/design.md`: the RouterOS capability survey, threshold rationale, voting and FSM
  tables, VRRP mapping, fuse failure modes and the multi-WAN sketch.

### Notes

- The shipped targets are RFC 5737 documentation addresses and never answer. Edit
  `WanQmCfgTargets` before deploying.
- The target list must hold exactly four entries; the build refuses any other number.

[0.2.0]: https://github.com/rzemykers/mikrotik-wan-quality-monitor/releases/tag/v0.2.0
[0.1.0]: https://github.com/rzemykers/mikrotik-wan-quality-monitor/releases/tag/v0.1.0
