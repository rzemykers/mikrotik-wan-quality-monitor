# INSTALL.rsc - wanqm pure-RouterOS installer. Requires RouterOS >= 7.13 (/file read).
#
# Usage: upload wanqm-config.rsc (your edited copy of a wanqm-config-*.rsc template),
# the wanqm-*.rsc sources and this file, then run FROM A TERMINAL:
#     /import INSTALL.rsc
# (a Winbox-side import swallows :put output - you would not see the summary).
#
# A fresh install leaves EVERYTHING DISABLED and prints the enable commands.
# A re-import over an ACTIVE install (wanqm-probe scheduler enabled) re-enables
# automatically, so "edit config, re-import" keeps working as one step.
# Everything that can fail - missing files, syntax errors, preflight - fails BEFORE
# anything is removed: a failed run never leaves the router without its previous wanqm.

# ---------- helpers (no side effects) ----------
# fFind: base name (no extension) -> full on-router name of <base>.rsc ("" if absent).
# Files may land in the root or under flash/ depending on the board, hence the (^|/)
# prefix; the trailing \.rsc\$ anchor keeps "wanqm-config" from matching
# wanqm-config-primary.rsc. The backslashes deliberately live HERE and not in the
# call sites: the /import parser chokes on a "\\" inside a nested [$f [$g "..."]] call
# (verified on ROS 7.24), while a bare-name argument is safe.
:local fFind do={
    :local ids [/file find name~("(^|/)" . $1 . "\\.rsc\$")]
    :if ([:len $ids] = 0) do={ :return "" }
    :return [/file get ($ids->0) name]
}
# fLoad: exact file name -> whole content as one string. Loops /file read (chunk max
# 32768) until the size reported by /file get is consumed; advances by the ACTUAL bytes
# returned, because the last chunk is short.
:local fLoad do={
    :local size [/file get $1 size]
    :local out ""
    :local o 0
    :while ($o < $size) do={
        :local r [/file read file=$1 chunk-size=32768 offset=$o as-value]
        :local d ($r->"data")
        :if ([:len $d] = 0) do={ :error ("[wanqm-install] read stalled on " . $1 . " at offset " . $o) }
        :set out ($out . $d)
        :set o ($o + [:len $d])
    }
    :return $out
}

# ---------- 1. presence + size check (9 files) ----------
:local specs {"wanqm-config";"wanqm-init";"wanqm-notify";"wanqm-probe";"wanqm-report";"wanqm-orchestrator";"wanqm-watchdog";"wanqm-fuse-down";"wanqm-fuse-up"}
:local missing ""
:foreach s in=$specs do={
    :local f [$fFind $s]
    :if ([:len $f] = 0) do={
        :set missing ($missing . " " . $s . ".rsc")
    } else={
        :if ([/file get $f size] = 0) do={ :set missing ($missing . " " . $s . ".rsc(EMPTY)") }
    }
}
:if ([:len $missing] > 0) do={ :error ("[wanqm-install] missing or empty:" . $missing . " - nothing was changed") }

# ---------- 2. load all sources (still no side effects) ----------
:local srcConfig   [$fLoad [$fFind "wanqm-config"]]
:local srcInit     [$fLoad [$fFind "wanqm-init"]]
:local srcNotify   [$fLoad [$fFind "wanqm-notify"]]
:local srcProbe    [$fLoad [$fFind "wanqm-probe"]]
:local srcReport   [$fLoad [$fFind "wanqm-report"]]
:local srcOrch     [$fLoad [$fFind "wanqm-orchestrator"]]
:local srcWatchdog [$fLoad [$fFind "wanqm-watchdog"]]
:local srcFuseDown [$fLoad [$fFind "wanqm-fuse-down"]]
:local srcFuseUp   [$fLoad [$fFind "wanqm-fuse-up"]]

# ---------- 3. syntax check everything (catches a truncated upload) ----------
:local sources ({"wanqm-config"=$srcConfig;"wanqm-init"=$srcInit;"wanqm-notify"=$srcNotify;"wanqm-probe"=$srcProbe;"wanqm-report"=$srcReport;"wanqm-orchestrator"=$srcOrch;"wanqm-watchdog"=$srcWatchdog;"wanqm-fuse-down"=$srcFuseDown;"wanqm-fuse-up"=$srcFuseUp})
:foreach n,s in=$sources do={
    :do {
        :local t [:parse $s]
    } on-error={ :error ("[wanqm-install] " . $n . " does not parse - truncated upload? Nothing was changed") }
}

# ---------- 4. run the config + preflight (still nothing removed or added) ----------
:do {
    :local fn [:parse $srcConfig]
    $fn
} on-error={ :error "[wanqm-install] wanqm-config.rsc failed while executing - nothing was changed" }
:global WanQmCfgRole;:global WanQmCfgTargets;:global WanQmCfgVrrp;:global WanQmCfgWanIf
:global WanQmCfgNotifyToken;:global WanQmCfgPrioGood;:global WanQmCfgPrioBad
:local warns 0
:if ([:typeof $WanQmCfgRole] != "str") do={
    :error "[wanqm-install] WanQmCfgRole is not set - your config predates this installer; add :global WanQmCfgRole \"primary\" (or \"backup\") to wanqm-config.rsc"
}
:if (!(($WanQmCfgRole = "primary") or ($WanQmCfgRole = "backup"))) do={
    :error ("[wanqm-install] WanQmCfgRole must be \"primary\" or \"backup\", got \"" . $WanQmCfgRole . "\"")
}
:if (([:typeof $WanQmCfgTargets] != "array") or ([:len $WanQmCfgTargets] != 4)) do={
    :error "[wanqm-install] WanQmCfgTargets must hold exactly 4 targets - the probe loop is unrolled, see the README"
}
:if ($WanQmCfgPrioBad >= $WanQmCfgPrioGood) do={
    :error "[wanqm-install] WanQmCfgPrioBad must be lower than WanQmCfgPrioGood - the fuse writes these to VRRP"
}
:foreach t in=$WanQmCfgTargets do={
    :if (([:pick $t 0 8] = "192.0.2.") or ([:pick $t 0 11] = "198.51.100.") or ([:pick $t 0 10] = "203.0.113.")) do={
        :put ("WARN: target " . $t . " is a documentation address - it never answers; edit WanQmCfgTargets")
        :set warns ($warns + 1)
    }
}
:if ([:len [/interface vrrp find name=$WanQmCfgVrrp]] = 0) do={
    :put ("WARN: VRRP interface \"" . $WanQmCfgVrrp . "\" not found - orchestrator and fuse will log errors until it exists")
    :set warns ($warns + 1)
}
:if ([:len [/interface find name=$WanQmCfgWanIf]] = 0) do={
    :put ("WARN: WAN interface \"" . $WanQmCfgWanIf . "\" not found - check WanQmCfgWanIf")
    :set warns ($warns + 1)
}
:local tokBad ([:len $WanQmCfgNotifyToken] = 0)
:if ([:typeof [:find $WanQmCfgNotifyToken "__" -1]] != "nil") do={ :set tokBad true }
:if ([:typeof [:find $WanQmCfgNotifyToken "change-me" -1]] != "nil") do={ :set tokBad true }
:if ($tokBad) do={
    :put "WARN: WanQmCfgNotifyToken is still a placeholder - webhook POSTs will fail, alerts fall back to e-mail"
    :set warns ($warns + 1)
}

# ---------- 5. POINT OF NO RETURN ----------
:local wasActive ([:len [/system scheduler find name="wanqm-probe" disabled=no]] > 0)
/system scheduler remove [find name~"^wanqm-"]
/system script remove [find name~"^wanqm-"]
/tool netwatch remove [find comment~"^wanqm-"]

# ---------- 6. scripts ----------
# wanqm-config gets policy=read ONLY: it just sets globals, and the netwatch fuse (which
# has no `policy` policy) must be able to `/system script run` it - a caller cannot run
# a script whose policies exceed its own.
/system script add name=wanqm-config policy=read comment="WAN Quality Monitor (wanqm)" source=$srcConfig
/system script add name=wanqm-init policy=read,write,test,policy comment="WAN Quality Monitor (wanqm)" source=$srcInit
# wanqm-notify gets read,write,test (no `policy`): the netwatch fuse runs it directly,
# and a caller cannot run a script whose policies exceed its own.
/system script add name=wanqm-notify policy=read,write,test comment="WAN Quality Monitor (wanqm)" source=$srcNotify
/system script add name=wanqm-probe policy=read,write,test,policy comment="WAN Quality Monitor (wanqm)" source=$srcProbe
/system script add name=wanqm-report policy=read,write,test,policy comment="WAN Quality Monitor (wanqm)" source=$srcReport
/system script add name=wanqm-orchestrator policy=read,write,test,policy comment="WAN Quality Monitor (wanqm)" source=$srcOrch
/system script add name=wanqm-watchdog policy=read,write,test,policy comment="WAN Quality Monitor (wanqm)" source=$srcWatchdog

# ---------- 7. schedulers (all disabled) ----------
:local orchComment "wanqm: VRRP control (enable on the primary only)"
:if ($WanQmCfgRole = "backup") do={ :set orchComment "wanqm: VRRP control - KEEP DISABLED on the backup (static priority by design)" }
/system scheduler add name=wanqm-init-startup start-time=startup interval=0 disabled=yes on-event="/system script run wanqm-init" policy=read,write,test,policy comment="wanqm: cold start after reboot"
/system scheduler add name=wanqm-probe interval=10s disabled=yes on-event="/system script run wanqm-probe" policy=read,write,test,policy comment="wanqm: measurement+FSM"
/system scheduler add name=wanqm-report interval=5m disabled=yes on-event="/system script run wanqm-report" policy=read,write,test,policy comment="wanqm: 5min report (calibration)"
/system scheduler add name=wanqm-watchdog interval=1m disabled=yes on-event="/system script run wanqm-watchdog" policy=read,write,test,policy comment="wanqm: heartbeat freshness"
/system scheduler add name=wanqm-orchestrator interval=20s disabled=yes on-event="/system script run wanqm-orchestrator" policy=read,write,test,policy comment=$orchComment

# ---------- 8. netwatch fuses (disabled; both entries share the same scripts) ----------
/tool netwatch add comment=wanqm-fuse-1 host=($WanQmCfgTargets->0) type=icmp interval=10s packet-count=10 thr-loss-percent=80 disabled=yes down-script=$srcFuseDown up-script=$srcFuseUp
/tool netwatch add comment=wanqm-fuse-2 host=($WanQmCfgTargets->1) type=icmp interval=10s packet-count=10 thr-loss-percent=80 disabled=yes down-script=$srcFuseDown up-script=$srcFuseUp

# ---------- 9. init + summary ----------
/system script run wanqm-init
:put ("[wanqm-install] OK  role=" . $WanQmCfgRole . "  warnings=" . $warns)
:log info ("[wanqm] install OK role=" . $WanQmCfgRole . " warnings=" . $warns)
:put "SECURITY: the uploaded .rsc files carry your webhook tokens - remove them now:"
:put "  /file remove [find name~\"(^|/)wanqm-.*\\.rsc\$\"]"
:if ($wasActive) do={
    :put "[wanqm-install] previous install was ACTIVE - re-enabling"
    :if ($WanQmCfgRole = "primary") do={
        /system scheduler enable [find name~"^wanqm-"]
    } else={
        /system scheduler enable [find name~"^wanqm-" name!="wanqm-orchestrator"]
    }
    /tool netwatch enable [find comment~"^wanqm-fuse-"]
    :log info "[wanqm] install: re-enabled (was active)"
} else={
    :put "Everything is installed DISABLED. Review the warnings above, then enable:"
    :if ($WanQmCfgRole = "primary") do={
        :put "  /system scheduler enable [find name~\"^wanqm-\"]"
    } else={
        :put "  /system scheduler enable [find name~\"^wanqm-\" name!=\"wanqm-orchestrator\"]"
    }
    :put "  /tool netwatch enable [find comment~\"^wanqm-fuse-\"]"
    :put "First two minutes stay in UNKNOWN (cold-start grace) - a report line appears every 5 min."
}
