# wanqm-vrrpwatch - confirms that this router actually took (or released) VRRP mastership.
#
# Meant for the BACKUP role. The primary's alert "lowering priority - handing mastership
# to the backup" states an intent, not a fact: without this, nothing confirms that the
# standby really carries the traffic, or for how long it did.
#
# It is driven by the VRRP hooks, which the installer deliberately does NOT write - every
# write to a VRRP interface property resets its FSM for ~9 s (see the README). Append ONE
# line to the END of both your existing on-master and on-backup actions, asynchronously,
# so the webhook POST can never delay whatever the hooks already do (DHCP, lease sync...):
#   on-master: ... :execute "/system script run wanqm-vrrpwatch"
#   on-backup: ... :execute "/system script run wanqm-vrrpwatch"
#
# The script reads the ACTUAL VRRP state (`master`/`backup` flags of WanQmCfgVrrp), it does
# not take the event from the hook. Up to 0.3.0 the hook passed it in a WanQmVrrpEvent
# global - but VRRP hooks, like netwatch, run in their own global-variable environment, so
# the job started by `:execute` never saw it and returned silently: in a real 29-minute
# failover (ROS 7.24.5) the backup carried the LAN and sent nothing. Old two-line hooks
# keep working, the stray `:global WanQmVrrpEvent` is now a harmless no-op.
# For the same reason the remembered state does NOT live in globals: a job started from a
# hook does not land in the schedulers' environment (verified on ROS 7.24.5 from a real
# hook), so it is kept in this script's own comment, which every context can read:
#   "WAN Quality Monitor (wanqm) | vrrp=master since=<epoch> boot=<epoch>"
# `boot` is the router's boot time; a mismatch (a reboot since) means "no previous state".
# Trade-off: the state is read at run time, not event time. If it has not flipped yet when
# the job starts (or the interface is mid-transition, neither flag set), it re-reads up to
# 3 times 1 s apart; a flap shorter than that goes unreported.
#
# MASTER -> sev=warn (opens an incident), BACKUP -> sev=ok (closes it, with the duration).
# The same state twice in a row (e.g. on-backup after an FSM reset) is silent.
# No previous state (after a reboot): MASTER alerts, BACKUP is only remembered.
# Every run leaves an info line, so a no-op is visible in /log and never silent again.
:do {
/system script run wanqm-config
:global WanQmCfgVrrp;:global WanQmCfgLinkName
:global WanQmNotifySev;:global WanQmNotifyText

:local vid [/interface vrrp find name=$WanQmCfgVrrp]
:if ([:len $vid] = 0) do={
    :log error ("[wanqm] vrrpwatch: VRRP interface " . $WanQmCfgVrrp . " not found")
    :error "no vrrp"
}
:local now ([:tonsec [:timestamp]] / 1000000000)
:local boot ($now - ([:tonsec [/system resource get uptime]] / 1000000000))

# remembered state from the comment: wasMaster (bool) + since (num), only if same boot
:local sid [/system script find name="wanqm-vrrpwatch"]
:local cm ""
:if ([:len $sid] > 0) do={ :set cm [/system script get ($sid->0) comment] }
:local base $cm
:local known false
:local wasMaster false
:local since 0
:local at [:find $cm " | vrrp=" -1]
:if ([:typeof $at] = "num") do={
    :set base [:pick $cm 0 $at]
    :local kv [:pick $cm ($at + 8) [:len $cm]]
    :local p1 [:find $kv " since=" -1]
    :local p2 [:find $kv " boot=" -1]
    :if (([:typeof $p1] = "num") and ([:typeof $p2] = "num")) do={
        :local b [:tonum [:pick $kv ($p2 + 6) [:len $kv]]]
        :if (([:typeof $b] = "num") and ((($b - $boot) < 60) and (($boot - $b) < 60))) do={
            :set wasMaster ([:pick $kv 0 $p1] = "master")
            :set since [:tonum [:pick $kv ($p1 + 7) $p2]]
            :set known true
        }
    }
}

# "master" | "backup" | "" (neither flag: INIT / mid-transition)
:local fState do={
    :local v [/interface vrrp get $1]
    :if (([:typeof ($v->"master")] = "bool") and ($v->"master")) do={ :return "master" }
    :if (([:typeof ($v->"backup")] = "bool") and ($v->"backup")) do={ :return "backup" }
    :return ""
}
# a hook fired, so something changed: re-read while the state is undecided or still the remembered one
:local st [$fState ($vid->0)]
:local tries 0
:while ((($st = "") or ($known and (($st = "master") = $wasMaster))) and ($tries < 3)) do={
    :delay 1
    :set st [$fState ($vid->0)]
    :set tries ($tries + 1)
}

:local changed false
:if ($st != "") do={
    :local isMaster ($st = "master")
    :set changed true
    :if ($known) do={ :set changed ($isMaster != $wasMaster) }
    :if ((!$known) and (!$isMaster)) do={ :set changed false }
}
:log info ("[wanqm] vrrpwatch: " . $WanQmCfgVrrp . " state=" . $st . " known=" . $known . " changed=" . $changed . " rereads=" . $tries)

:if ($st != "") do={
    :local isMaster ($st = "master")
    :local dur -1
    :if ($known and ([:typeof $since] = "num")) do={ :set dur ($now - $since) }
    :if (((!$known) or $changed) and ([:len $sid] > 0)) do={
        /system script set ($sid->0) comment=($base . " | vrrp=" . $st . " since=" . $now . " boot=" . $boot)
    }
    :if ($changed) do={
        :if ($isMaster) do={
            :log warning ("[wanqm] VRRP " . $WanQmCfgVrrp . " -> MASTER (traffic on " . $WanQmCfgLinkName . ")")
            :set WanQmNotifySev "warn"
            :set WanQmNotifyText ("VRRP " . $WanQmCfgVrrp . " MASTER - LAN traffic now goes through " . $WanQmCfgLinkName . " (takeover confirmed)")
        } else={
            :log warning ("[wanqm] VRRP " . $WanQmCfgVrrp . " -> BACKUP after " . $dur . "s as MASTER")
            :set WanQmNotifySev "ok"
            :set WanQmNotifyText ("VRRP " . $WanQmCfgVrrp . " BACKUP - traffic is back on the primary, " . $WanQmCfgLinkName . " carried it for " . $dur . "s")
        }
        :do { /system script run wanqm-notify } on-error={ :log error "[wanqm] vrrpwatch: notify failed" }
    }
}
} on-error={ :log error "[wanqm] vrrpwatch: error" }
