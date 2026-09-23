# wanqm-report - rollup report every 5 min (log info) - also used to calibrate thresholds
# NOT for direct /import (that would execute it once) - INSTALL.rsc reads this file
# into the script store.
:do {
/system script run wanqm-config
:global WanQmCfgVrrp;:global WanQmCfgLinkName
:global WanQmState;:global WanQmStateSince;:global WanQmHeartbeat
:global WanQmVerd1;:global WanQmVerd2;:global WanQmVerd3;:global WanQmVerd4
:global WanQmM1;:global WanQmM2;:global WanQmM3;:global WanQmM4
:local now ([:tonsec [:timestamp]] / 1000000000)
:local prio [/interface/vrrp get [find name=$WanQmCfgVrrp] priority]
:local hbAge "n/a"
:if ([:typeof $WanQmHeartbeat] = "num") do={ :set hbAge ("" . ($now - $WanQmHeartbeat) . "s") }
:log info ("[wanqm] " . $WanQmCfgLinkName . " state=" . $WanQmState . " prio=" . $prio . " hb=" . $hbAge . " | p1=" . $WanQmVerd1 . " " . $WanQmM1 . " | p2=" . $WanQmVerd2 . " " . $WanQmM2 . " | p3=" . $WanQmVerd3 . " " . $WanQmM3 . " | p4=" . $WanQmVerd4 . " " . $WanQmM4)
} on-error={ :log error "[wanqm] report: failed" }
