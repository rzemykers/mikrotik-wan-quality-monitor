#!/usr/bin/env python3
"""Build the wanqm installation file for a given router.

Usage: python3 build_install.py [primary|backup|all]   (default: all)
  primary -> wanqm-install-primary.rsc  (full deployment: orchestrator + fuses)
  backup  -> wanqm-install-backup.rsc   (backup router: orchestrator DISABLED
             permanently - static priority 70, so the primary always wins VRRP
             unless it is in BAD; the fuse stays active as a backstop)
"""
import pathlib
import re
import sys

D = pathlib.Path(__file__).parent
POLICY = "read,write,test,policy"

PROFILES = {
    "primary": {
        "outfile": "wanqm-install-primary.rsc",
        "config_body": "wanqm-config-primary.body",
        "orchestrator_enabled": True,
        "fuses": True,
        # the fuse forces a priority BELOW the backup's (70), so mastership is really
        # handed over when both the scripts and the link are dead
        "fuse_prio": 30,
        "disable_old_netwatch": True,
    },
    "backup": {
        "outfile": "wanqm-install-backup.rsc",
        "config_body": "wanqm-config-backup.body",
        "orchestrator_enabled": False,
        "fuses": True,
        # the fuse forces a priority BELOW the primary's floor (30), so the backup can
        # never "win" the VRRP election while it is itself dead or degraded (the primary
        # in BAD already sits at 30 - the backup must be lower: 20, the same value as
        # WanQmCfgPrioBad in the backup config)
        "fuse_prio": 20,
        # priority restored when the netwatch target comes back - must equal the backup's
        # static priority (70), because the orchestrator on this router is permanently
        # disabled and nothing else would ever restore it (see the fuse_up comment)
        "fuse_restore_prio": 70,
        "disable_old_netwatch": False,
    },
}


def esc(s: str) -> str:
    return (s.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("$", "\\$")
             .replace("\n", "\\r\\n"))


def load_secrets() -> dict:
    """Read secrets.local (KEY=VALUE) and return a placeholder map.

    Secrets live ONLY there, so the *.body sources stay clean and can be shared safely.
    The generated *.rsc files DO contain the real values (they have to - they go onto the
    router), which is why the build sets them to chmod 600.
    """
    f = D / "secrets.local"
    if not f.exists():
        raise SystemExit(
            "ERROR: secrets.local is missing - without it the tokens would stay as "
            "placeholders and notifications would not work. Copy secrets.local.example "
            "to secrets.local and fill it in."
        )
    out = {}
    for line in f.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[f"__{k.strip()}__"] = v.strip()
    for req in ("__NOTIFY_TOKEN__", "__SMS_TOKEN__", "__SMS_TO__"):
        if req not in out:
            raise SystemExit(f"ERROR: secrets.local does not define {req.strip('_')}")
    return out


SECRETS = load_secrets()


def inject(body: str) -> str:
    for k, v in SECRETS.items():
        body = body.replace(k, v)
    return body


def cfg_str(body: str, name: str) -> str:
    """Read a `:global <name> "value"` string out of the config .body."""
    m = re.search(r'^:global %s\s+"([^"]*)"' % re.escape(name), body, re.M)
    if not m:
        raise SystemExit(f"ERROR: the config file does not define {name}")
    return m.group(1)


def cfg_targets(body: str) -> list:
    """Read the `:global WanQmCfgTargets {...}` list out of the config .body."""
    m = re.search(r'^:global WanQmCfgTargets\s*\{(.+?)\}', body, re.M)
    if not m:
        raise SystemExit("ERROR: the config file does not define WanQmCfgTargets")
    t = re.findall(r'"([^"]+)"', m.group(1))
    if len(t) != 4:
        raise SystemExit(f"ERROR: WanQmCfgTargets must hold exactly 4 targets, found {len(t)} "
                         "- the probe loop is unrolled, see the README")
    return t


SCRIPTS = ["wanqm-config", "wanqm-init", "wanqm-notify", "wanqm-probe",
           "wanqm-report", "wanqm-orchestrator", "wanqm-watchdog"]


def build(profile: str) -> None:
    p = PROFILES[profile]

    # The VRRP interface name and the probe targets live in ONE place: the config .body.
    # The netwatch fuses are generated from them, so editing the config is genuinely all
    # a user has to do - there is no second copy here to forget about.
    cfg_src = (D / p["config_body"]).read_text()
    vrrp = cfg_str(cfg_src, "WanQmCfgVrrp")
    # the fuses watch the first two probe targets: first mile + independent transit
    fuse_hosts = tuple(cfg_targets(cfg_src)[:2])

    # The fuse only acts when the measurement is DEAD (heartbeat older than 60s = the
    # scripts died). While the scripts are alive the fuse stays silent and leaves the
    # decision to the FSM with its full hysteresis. Without this gating the fuse bypassed
    # the hysteresis and fought the orchestrator -> VRRP flapping.
    fuse1_down = (''':global WanQmHeartbeat
:global WanQmLastPrioChange
:global WanQmFusePending
:if ([/tool/netwatch get [find comment="wanqm-fuse-2"] status] = "down") do={
    :local alive false
    :if ([:typeof $WanQmHeartbeat] = "num") do={
        :if ((([:tonsec [:timestamp]] / 1000000000) - $WanQmHeartbeat) <= 60) do={ :set alive true }
    }
    :if ($alive) do={
        :log warning "[wanqm] FUSE: both targets down but the measurement is alive - leaving the decision to the FSM/orchestrator"
    } else={
        :local cur [/interface/vrrp get [find name="%s"] priority]
        :if ($cur != %d) do={
            :log error "[wanqm] FUSE: both targets down AND the measurement is dead - forcing priority %d"
            /interface/vrrp set [find name="%s"] priority=%d
            :set WanQmLastPrioChange ([:tonsec [:timestamp]] / 1000000000)
            :set WanQmFusePending ("FUSE: both ICMP targets down AND measurement dead - emergency lowering priority " . $cur . " -> %d")
        } else={
            :log warning "[wanqm] FUSE: priority already lowered - skipping (dedup)"
        }
    }
}''' % (vrrp, p["fuse_prio"], p["fuse_prio"], vrrp, p["fuse_prio"], p["fuse_prio"]))
    fuse2_down = fuse1_down.replace("wanqm-fuse-2", "wanqm-fuse-1")

    # up-script: ONLY where the orchestrator on this router is permanently disabled -
    # otherwise nothing would ever restore the priority after the fuse fired. Confirmed in
    # production: the fuse on the backup router fired during a bad LTE night and the priority
    # stayed at 20 for the next ~4.5 days (noticed only much later). During that window the
    # failover was in fact broken: 20 < the primary's BAD priority (30), so the backup would
    # never have taken over despite being the healthier of the two. Where the orchestrator
    # runs (primary), it raises the priority itself every 20s after the hold-down, so the
    # up-script is unnecessary there.
    fuse_up = ""
    if not p["orchestrator_enabled"]:
        rp = p["fuse_restore_prio"]
        # The `cur != rp` guard is REQUIRED: both netwatch entries fire their up-scripts, and
        # an unconditional write would repeat `set priority` every time a target came back.
        # Measured: ANY change to a VRRP interface property (not just priority - on-master too)
        # resets the VRRP FSM for ~9s. So writing "the same" value is not a no-op, it is a real
        # flap risk. We now write only when the priority actually differs from the target.
        fuse_up = (''':local cur [/interface/vrrp get [find name="%s"] priority]
:if ($cur != %d) do={
    /interface/vrrp set [find name="%s"] priority=%d
    :log warning "[wanqm] FUSE: target is back - restoring priority %d from %s (the orchestrator on this router is permanently disabled, nothing else would do it)"
}''' % (vrrp, rp, vrrp, rp, rp, "$cur"))

    out = [f"# {p['outfile']} - generated by build_install.py (profile: {profile}); load with /import",
           "# clean up the previous installation (idempotent)",
           '/system scheduler remove [find name~"^wanqm-"]',
           '/system script remove [find name~"^wanqm-"]',
           '/tool netwatch remove [find comment~"^wanqm-"]',
           ""]

    for name in SCRIPTS:
        body_file = p["config_body"] if name == "wanqm-config" else f"{name}.body"
        body = inject((D / body_file).read_text())
        out.append(f'/system script add name={name} policy={POLICY} '
                   f'comment="WAN Quality Monitor (wanqm)" source="{esc(body)}"')
        out.append("")

    orch_flags = "" if p["orchestrator_enabled"] else "disabled=yes "
    orch_comment = ("wanqm: VRRP control (active)"
                    if p["orchestrator_enabled"]
                    else "wanqm: VRRP control - PERMANENTLY DISABLED (static backup, metered LTE)")
    out += [
        "# schedulers",
        f'/system scheduler add name=wanqm-init-startup start-time=startup interval=0 '
        f'on-event="/system script run wanqm-init" policy={POLICY} '
        f'comment="wanqm: cold start after reboot"',
        f'/system scheduler add name=wanqm-probe interval=10s '
        f'on-event="/system script run wanqm-probe" policy={POLICY} '
        f'comment="wanqm: measurement+FSM"',
        f'/system scheduler add name=wanqm-report interval=5m '
        f'on-event="/system script run wanqm-report" policy={POLICY} '
        f'comment="wanqm: 5min report (calibration)"',
        f'/system scheduler add name=wanqm-watchdog interval=1m '
        f'on-event="/system script run wanqm-watchdog" policy={POLICY} '
        f'comment="wanqm: heartbeat freshness"',
        f'/system scheduler add name=wanqm-orchestrator interval=20s {orch_flags}'
        f'on-event="/system script run wanqm-orchestrator" policy={POLICY} '
        f'comment="{orch_comment}"',
        "",
    ]

    if p["fuses"]:
        h1, h2 = fuse_hosts
        up_kw = f' up-script="{esc(fuse_up)}"' if fuse_up else ""
        out += [
            "# netwatch fuses - ACTIVE (backstop for a hard DOWN when the scripts die)",
            f'/tool netwatch add comment=wanqm-fuse-1 host={h1} type=icmp interval=10s '
            f'packet-count=10 thr-loss-percent=80 down-script="{esc(fuse1_down)}"{up_kw}',
            f'/tool netwatch add comment=wanqm-fuse-2 host={h2} type=icmp interval=10s '
            f'packet-count=10 thr-loss-percent=80 down-script="{esc(fuse2_down)}"{up_kw}',
            "",
        ]

    if p["disable_old_netwatch"]:
        out += [
            "# disable the old single-netwatch setup - superseded by wanqm; idempotent",
            '/tool netwatch disable [find interval=5s]',
            "",
        ]

    out += ["# initialize state", "/system script run wanqm-init", ""]

    outfile = D / p["outfile"]
    outfile.write_text("\n".join(out))
    # The file carries the injected tokens, so keep it owner-only. chmod AFTER the write:
    # write_text() on an existing file leaves its mode alone, so a pre-existing 644 would
    # otherwise survive and silently expose the tokens.
    outfile.chmod(0o600)
    print(f"OK: {p['outfile']} ({len(outfile.read_text())} B, mode 600)")


targets = sys.argv[1:] or ["all"]
for t in (PROFILES.keys() if targets == ["all"] else targets):
    build(t)
