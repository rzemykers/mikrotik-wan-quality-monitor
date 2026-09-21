# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/rzemykers/mikrotik-wan-quality-monitor/releases/tag/v0.1.0
