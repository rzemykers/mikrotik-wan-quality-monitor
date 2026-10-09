# wanqm-vrrpwatch - confirms that this router actually took (or released) VRRP mastership.
#
# Meant for the BACKUP role. The primary's alert "lowering priority - handing mastership
# to the backup" states an intent, not a fact: without this, nothing confirms that the
# standby really carries the traffic, or for how long it did.
#
# It is driven by the VRRP hooks, which the installer deliberately does NOT write - every
# write to a VRRP interface property resets its FSM for ~9 s (see the README). Append the
# two lines to the END of your existing on-master / on-backup actions, asynchronously, so
# the webhook POST can never delay whatever the hooks already do (DHCP, lease sync...):
#   on-master: ... :global WanQmVrrpEvent "master"; :execute "/system script run wanqm-vrrpwatch"
#   on-backup: ... :global WanQmVrrpEvent "backup"; :execute "/system script run wanqm-vrrpwatch"
#
# MASTER -> sev=warn (opens an incident), BACKUP -> sev=ok (closes it, with the duration).
# The same event twice in a row (e.g. on-backup after an FSM reset) is silent.
# No previous state (after a reboot): "master" alerts, "backup" is only remembered.
:do {
/system script run wanqm-config
:global WanQmCfgVrrp;:global WanQmCfgLinkName
:global WanQmVrrpEvent;:global WanQmVrrpWasMaster;:global WanQmVrrpSince
:global WanQmNotifySev;:global WanQmNotifyText

:if (([:typeof $WanQmVrrpEvent] = "str") and (($WanQmVrrpEvent = "master") or ($WanQmVrrpEvent = "backup"))) do={
    :local isMaster ($WanQmVrrpEvent = "master")
    :local now ([:tonsec [:timestamp]] / 1000000000)
    :local known ([:typeof $WanQmVrrpWasMaster] = "bool")
    :local changed true
    :if ($known) do={ :set changed ($isMaster != $WanQmVrrpWasMaster) }
    :if ((!$known) and (!$isMaster)) do={ :set changed false }
    :local dur -1
    :if ($known and ([:typeof $WanQmVrrpSince] = "num")) do={ :set dur ($now - $WanQmVrrpSince) }
    :if ((!$known) or $changed) do={
        :set WanQmVrrpWasMaster $isMaster
        :set WanQmVrrpSince $now
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
