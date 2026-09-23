# wanqm-fuse-up - netwatch up-script, the SAME source is attached to both wanqm-fuse-*
# entries. NOT for direct /import - INSTALL.rsc wires it up.
#
# Restores the priority after the fuse emergency-dropped it - but ONLY where the
# orchestrator is not running: where it runs, it raises the priority itself every 20 s
# after the hold-down, and an immediate restore here would bypass that damping. Where it
# does not run (the backup router - or a primary with the orchestrator disabled for
# maintenance, where the restore skips the hold-down but writes the same value the
# orchestrator would), nothing else would ever restore the priority: ours once sat at an
# emergency 20 for 4.5 days, silently breaking failover in the opposite direction.
#
# The scheduler lookup is deliberately find-then-get: a bare `get [find ...]` throws on
# an empty result, and the on-error wrapper would swallow the WHOLE up-script - leaving
# the priority stuck low, which is exactly the failure this script exists to prevent.
# No scheduler at all counts as "not running" -> restore.
:do {
/system script run wanqm-config
:global WanQmCfgVrrp;:global WanQmCfgPrioGood
:if ([:typeof $WanQmCfgVrrp] != "str") do={
    :log error "[wanqm] FUSE: config not loaded - refusing to touch VRRP"
    :error "no config"
}
:local orchOn false
:local ids [/system scheduler find name="wanqm-orchestrator"]
:if ([:len $ids] > 0) do={
    :if (![/system scheduler get ($ids->0) disabled]) do={ :set orchOn true }
}
:if (!$orchOn) do={
    :local cur [/interface/vrrp get [find name=$WanQmCfgVrrp] priority]
    :if ($cur != $WanQmCfgPrioGood) do={
        /interface/vrrp set [find name=$WanQmCfgVrrp] priority=$WanQmCfgPrioGood
        :log warning ("[wanqm] FUSE: target is back - restoring priority " . $WanQmCfgPrioGood . " from " . $cur . " (no running orchestrator would do it)")
    }
}
} on-error={ :log error "[wanqm] FUSE: up-script failed" }
