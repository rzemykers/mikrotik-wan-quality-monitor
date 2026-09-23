# WAN Quality Monitor (wanqm)

[![Version](https://img.shields.io/github/v/release/rzemykers/mikrotik-wan-quality-monitor?color=blue)](https://github.com/rzemykers/mikrotik-wan-quality-monitor/releases)
[![RouterOS](https://img.shields.io/badge/RouterOS-7.x-293239)](https://help.mikrotik.com/docs/spaces/ROS/pages/47579229/Scripting)
[![In production](https://img.shields.io/badge/in%20production-since%20Jul%202026-41BDF5)](docs/design.md#6-mapping-to-vrrp)
[![Dependencies](https://img.shields.io/badge/dependencies-none-4c1)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/rzemykers/mikrotik-wan-quality-monitor?style=flat)](https://github.com/rzemykers/mikrotik-wan-quality-monitor/stargazers)

**SD-WAN-style WAN quality monitoring and VRRP failover for MikroTik RouterOS.**

Netwatch fails over on a two-second hiccup. This doesn't.

<p align="center">
  <img src="docs/img/topology.jpg" width="620" alt="Isometric topology: two routers linked by VRRP - the master on the left glowing green with a fibre WAN uplink and four ICMP probes into the cloud, the backup on the right in amber on LTE - and a cyan POST arrow going down into a LAN box, not out to the internet">
</p>

`wanqm` pings four targets every 10 s — always four — keeps rolling windows of loss / RTT / jitter,
takes a majority vote across the probes, and feeds the result into a state machine with
hysteresis and dwell times. Only then does anything touch VRRP priority — and only one
script is ever allowed to write it.

Running in production on RouterOS 7.23–7.24 since July 2026: a week of observation, zero
false positives, and a real ISP blip that flapped the old Netwatch while `wanqm` stayed `GOOD`.

---

## Quick start

No tooling needed — everything happens on the router.

```sh
cp wanqm-config-primary.rsc wanqm-config.rsc   # standby router: use -backup instead
$EDITOR wanqm-config.rsc                       # targets, WAN interface, VRRP name, webhook token
scp INSTALL.rsc wanqm-*.rsc admin@router:      # or drag them into Winbox > Files
```

Then, **in a terminal on the router** (a Winbox-side import would swallow the output):

```
/import INSTALL.rsc
```

The installer preflights your config against the live router — it refuses to run on a
broken config *before* touching anything — and installs everything **disabled**. It ends
by printing the exact enable commands for your role; on the primary:

```
/system scheduler enable [find name~"^wanqm-"]
/tool netwatch enable [find comment~"^wanqm-fuse-"]
```

Run them when you're happy, then delete the uploaded files — they carry your webhook
token (`/file remove [find name~"(^|/)wanqm-.*\.rsc\$"]`). Within ~2 minutes of
enabling you should see a report line every 5 min in `/log print where message~"wanqm"`:

```
[wanqm] wan1 state=GOOD prio=80 hb=3s | p1=OK loss=0% rtt=8.1ms jit=0.1ms | p2=OK ...
```

Re-importing is idempotent — edit the config, upload, `/import` again. A re-import over
a **running** install re-enables everything by itself, so config changes stay one step.

> **The shipped targets are documentation addresses and never answer.** They are
> placeholders, not defaults: edit `WanQmCfgTargets` first, or all four probes FAIL
> and the link is judged down.
>
> **Give it exactly four targets.** The count is not configurable — a fifth is ignored,
> and fewer than four quietly makes failover trigger-happy. [Why](#configuration).

> **First two minutes are a grace period.** Cold start leaves the state at `UNKNOWN`
> and the orchestrator never raises priority on a state it doesn't trust.

---

## Notifications (optional)

`wanqm-notify` is the single funnel for every alert — probe, orchestrator, watchdog and
fuse all go through it. Point it at something **on your LAN**: then the alert still goes
out *while* the WAN is down. The first non-OK event opens an incident, later events append
to it, and the recovery closes it with the full timeline in one message.

All of it lives in your `wanqm-config.rsc`:

| Setting | Meaning |
|---|---|
| `WanQmCfgNotifyUrl` | webhook URL for the main channel |
| `WanQmCfgNotifyToken` | sent as the `X-Auth-Token` header |
| `WanQmCfgSmsUrl` | webhook URL for SMS (`crit` severity only) |
| `WanQmCfgSmsToken` | same, for the SMS endpoint |
| `WanQmCfgSmsTo` | recipient in E.164; leave `__UNSET__` to disable SMS entirely |
| `WanQmCfgSmsThrottleS` | minimum seconds between SMS (default 900) |
| `WanQmCfgMailTo` | fallback e-mail, used **only** when the POST fails |

**The request shape is a template.** The defaults reproduce the original behaviour, so
leaving them alone changes nothing:

| Setting | Default |
|---|---|
| `WanQmCfgNotifyHeaders` | `Content-Type: application/json,X-Auth-Token: %TOKEN%` |
| `WanQmCfgNotifyBody` | `{"message":"%MESSAGE%"}` |
| `WanQmCfgSmsHeaders` | as above |
| `WanQmCfgSmsBody` | `{"to":"%TO%","message":"%MESSAGE%"}` |

Placeholders: `%MESSAGE%` `%SEVERITY%` `%ROUTER%` `%LINK%` `%INCIDENT%` `%TOKEN%` `%TO%`.

Pointing wanqm at a different receiver is therefore a config change, not a code change:

```
# ntfy
:global WanQmCfgNotifyHeaders "Content-Type: application/json,Authorization: Bearer %TOKEN%"
:global WanQmCfgNotifyBody "{\"topic\":\"wanqm\",\"message\":\"%MESSAGE%\",\"tags\":[\"%SEVERITY%\"]}"

# Gotify
:global WanQmCfgNotifyHeaders "Content-Type: application/json,X-Gotify-Key: %TOKEN%"
:global WanQmCfgNotifyBody "{\"title\":\"wanqm %ROUTER%\",\"message\":\"%MESSAGE%\"}"

# Slack (the token lives in the webhook URL)
:global WanQmCfgNotifyHeaders "Content-Type: application/json"
:global WanQmCfgNotifyBody "{\"text\":\"%MESSAGE%\"}"
```

It is still **POST-only** — there is no GET mode.

Four things worth knowing:

- `%MESSAGE%` is substituted **last**, on purpose. Alert text routinely contains a `%`
  (`loss=6%`), and could in principle contain something that looks like a placeholder;
  substituting it last guarantees nothing from the message body gets expanded again.
- `check-certificate=no` is set, because the endpoint is assumed to be a LAN service,
  frequently behind an internal CA. Change it if that is not your situation.
- Alert text must contain no `"` and no `\` — the body is concatenated, not escaped.
- Without any webhook at all, everything still works. You just read the logs.

---

## What it installs

| Component | Interval | Role |
|---|---|---|
| `wanqm-config` | on demand | all parameters — installed from **your `wanqm-config.rsc`, the only file you edit** |
| `wanqm-probe` | 10 s | measure, aggregate, run the FSM; writes globals only |
| `wanqm-orchestrator` | 20 s | the **only** writer of VRRP priority |
| `wanqm-watchdog` | 60 s | heartbeat freshness; re-init if measurement dies |
| `wanqm-report` | 5 min | rollup log line, also used to calibrate thresholds |
| `wanqm-notify` | on demand | single notification funnel + incident correlation |
| `wanqm-init` | at startup | cold start: clean windows, `UNKNOWN`, no VRRP writes |
| 2× netwatch fuse | 10 s | backstop for a hard DOWN **if the scripts themselves die** |

Measurement never touches VRRP. The two layers talk in one direction only, through globals.

---

## How it decides

```
4 probes × 5 pings / 10 s tick      (four: fixed, not configurable)
        │
        ├─ rolling windows:  L = 12 ticks (~2 min)   S = 3 ticks (30 s)
        │
        ├─ per-probe verdict:  FAIL / DEGRADED / OK   (dead zone keeps the old one)
        │
        ├─ vote:  FAIL ≥ 3 of 4   ·   DEGRADED ≥ 2 of 4   ·   link down → FAIL now
        │
        └─ FSM with streaks + dwell  →  GOOD / DEGRADED / BAD / UNKNOWN
                                              │
                                     orchestrator → VRRP priority
```

| Per-probe verdict | Condition |
|---|---|
| `FAIL` | loss(S) ≥ 60 % **or** zero replies in S |
| `DEGRADED` | loss(L) ≥ 5 % **or** RTT(L) ≥ 40 ms **or** jitter(L) ≥ 15 ms |
| `OK` | loss(L) < 2 % **and** RTT(L) < 25 ms **and** jitter(L) < 8 ms |
| in between | keep the previous verdict (threshold hysteresis) |

| Transition | Requires | Why |
|---|---|---|
| GOOD → BAD | FAIL × 2 ticks (20 s) | hard outages must fail fast |
| GOOD → DEGRADED | DEGRADED × 3 ticks (30 s) | a 1–2 s spike is < 15 % of the long window |
| BAD → DEGRADED | not-FAIL × 6 ticks (60 s) | recovery is slower than failure |
| DEGRADED → GOOD | OK × 12 ticks (~2 min) | promote only after a full clean window |

| State | VRRP priority | Effect |
|---|---|---|
| `GOOD` | 80 | master |
| `DEGRADED` | **never lowered** | alert only — normally no write at all; see the gotcha below |
| `BAD` | 30 | hands mastership to the backup |
| `UNKNOWN` | untouched | fail-safe: never raise blindly |

Plus damping: 60 s hold-down before any raise, and raising freezes for 30 min after
3 priority changes in 15 min.

---

## Configuration

Everything lives in one file: your copy of a config template (`wanqm-config.rsc`).
The five you actually have to change:

```
:global WanQmCfgRole    "primary"   # or "backup" - drives the installer's enable listing
:global WanQmCfgTargets {"192.0.2.1";"192.0.2.2";"192.0.2.3";"198.51.100.10"}
:global WanQmCfgWanIf   "ether1"
:global WanQmCfgVrrp    "vrrp1"
:global WanQmCfgPrioGood 80      # must straddle your backup router's priority
```

Pick the targets deliberately — they are the whole point:

1. **your ISP gateway** — first mile, the most sensitive indicator
2. **a public anycast resolver** — transit quality, independent of your ISP
3. **a second resolver, different operator** — tells a dead host from a dead link
4. **your own remote host** — end-to-end over the path that actually carries your traffic

**It has to be exactly four.** The probe loop is unrolled, not iterated: a fifth target is
silently ignored, and fewer than four is worse — the missing slot pings nothing, fails every
tick, and permanently spends one of the votes. With a dead slot, `FAIL ≥ 3 of 4` starts
tripping on two genuine failures instead of three. Four targets, always; the build refuses
to run with any other number.

The two netwatch fuses watch the first two targets, and everything they write —
the VRRP interface name, the emergency priority (`PrioBad`), the restore priority
(`PrioGood`) — is read from the config at run time. Nothing about your setup is
duplicated in the installer: the config file really is the only thing you edit.

Leave the thresholds alone for the first week, read `wanqm-report` output, then set
OK ≈ p95 of your normal RTT and DEGRADED ≈ 2× baseline.

### Two routers

The standby router runs from the `wanqm-config-backup.rsc` template (`WanQmCfgRole
"backup"`): it measures, logs and alerts, but its orchestrator scheduler is never
enabled — the enable listing the installer prints deliberately skips it — and its
priority stays static. If the backup link is metered, it must never win the election on
its own merit; the primary should hold mastership whenever it is not in `BAD`. The only
thing that moves the backup's priority is the fuse: down to `PrioBad` in an emergency,
back to `PrioGood` when a target returns.

## RouterOS gotchas

The non-obvious things this project ran into. They cost days; they're the reason some of
the code looks the way it does.

- **Every write to a VRRP interface property resets the VRRP FSM** for ~9 s — a spurious
  BACKUP→MASTER cycle. Not just `priority`, and regardless of direction or size: raising
  75 → 80 (both above the backup's 70) triggered a full flap. Hence: `DEGRADED` never
  lowers priority — its target *is* `PrioGood`, so in the normal case target equals
  current and nothing is written at all. The one thing it does do is raise the priority
  back after a fuse emergency-dropped it, which is the proof the link is alive again.
  Raises also jump straight to the target instead of stepping, and every writer guards
  on `cur != target`.
- **A netwatch fuse must be gated on the heartbeat.** Ungated, it bypasses the hysteresis
  and fights the orchestrator — VRRP flaps. It fires only when the scripts are provably
  dead (heartbeat older than 60 s).
- **A fuse without an up-script is a trap** on any router whose orchestrator is disabled:
  nothing restores the priority afterwards. Ours sat at an emergency 20 for 4.5 days,
  silently breaking failover in the opposite direction.
- **Literal UTF-8 in strings is dropped.** Emoji must be hex escapes of the UTF-8 bytes:
  `"\F0\9F\94\B4"` is 🔴.
- **`/ping ... as-value` success is a record with *no* `status` field.** A failed record
  can still carry a `time`, so counting on `time` alone silently inflates your results.
- **Globals die on reboot** — hence `wanqm-init` on a `start-time=startup` scheduler, and
  a state of `UNKNOWN` that is explicitly not actionable.
- **Text sent to the webhook may contain no `"` and no `\`** — it is interpolated straight
  into JSON.

---

## Scripted builds (optional)

If you deploy often and want a single self-contained installer with the tokens already
injected, `build_install.py` (Python 3, no dependencies) reads the same sources plus a
`secrets.local` (copy `secrets.local.example`) and emits one `wanqm-install-<role>.rsc`
per router, chmod 600. It installs the same things, equally disabled, and prints the
same enable commands. The manual path above never needs it.

---

## Design notes

Why it works this way — the RouterOS capability survey, the threshold rationale, the
voting and FSM tables, and what production forced us to change:
**[docs/design.md](docs/design.md)**.

---

## Requirements

RouterOS **7.13 or newer** (the installer reads the uploaded files with `/file read`;
developed on 7.23, in production on 7.24) and a VRRP interface. Nothing else: no
packages, no external dependencies, nothing to run off-router.

---

## License

MIT — see [LICENSE](LICENSE).
