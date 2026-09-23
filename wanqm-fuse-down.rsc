# wanqm-fuse-down - netwatch backstop, the SAME source is attached to both wanqm-fuse-*
# entries as their down-script. NOT for direct /import - INSTALL.rsc wires it up.
#
# The fuse exists for one scenario only: the scripts themselves are dead (a bug, an
# exhausted scheduler, a broken import) AND the link is hard-down. While the measurement
# is alive the fuse stays silent and leaves the decision to the FSM with its full
# hysteresis - without this gating the fuse bypassed the hysteresis and fought the
# orchestrator, flapping VRRP.
#
# IMPORTANT: netwatch scripts run in their OWN global-variable environment, fully
# isolated from the schedulers' one (verified on ROS 7.24: values written on either
# side are invisible to the other). So this script can NEVER read WanQmHeartbeat.
# The "is the measurement alive" gate therefore works off configuration state, which
# IS shared:
#   1. the wanqm-probe scheduler disabled or gone        -> measurement dead
#   2. its comment carries MEASUREMENT-DEAD              -> dead (the watchdog mirrors
#      the real heartbeat verdict into that comment - it catches a probe that starts
#      and crashes mid-run)
#   3. otherwise: the probe script's run-count, sampled 12 s apart - the scheduler
#      starts it every 10 s, so a frozen count means nothing is being started
#
# The partner check counts "down" entries among comment~"^wanqm-fuse-": when this script
# runs, the OWN entry's status is already "down", so a count >= 2 means "me AND my
# partner". NB: adding a third wanqm-fuse-* entry silently changes the gate to ">=2 of N".
#
# On action the fuse notifies through wanqm-notify DIRECTLY (verified: netwatch can
# `/system script run` and /tool fetch works from its context). The old design staged
# the text in a WanQmFusePending global for wanqm-probe to relay - across the
# environment isolation that relay never fired, and it is gone.
#
# Reads WanQmCfgVrrp and WanQmCfgPrioBad from the config - which is why wanqm-config is
# installed with policy=read only: a caller cannot run a script whose policies exceed
# its own.
:do {
/system script run wanqm-config
:global WanQmCfgVrrp;:global WanQmCfgPrioBad
:global WanQmNotifySev;:global WanQmNotifyText
:if ([:typeof $WanQmCfgVrrp] != "str") do={
    :log error "[wanqm] FUSE: config not loaded - refusing to touch VRRP"
    :error "no config"
}
:if ([:len [/tool/netwatch find comment~"^wanqm-fuse-" status="down"]] >= 2) do={
    # De-synchronize FIRST: both entries usually go down in the same netwatch tick and
    # their scripts run in lockstep - without this both passed the cur!=target guard
    # together and wrote the priority twice (two VRRP FSM resets instead of one;
    # observed live, and :rndnum jitter still collided). Deterministic instead: the
    # entry whose $host matches wanqm-fuse-1 goes first, everyone else waits 3 s and
    # then sees the first writer's effect through the re-check and the guard.
    :local f1 [/tool/netwatch find comment="wanqm-fuse-1"]
    :if ([:len $f1] > 0) do={
        :if ([:tostr $host] != [:tostr [/tool/netwatch get ($f1->0) host]]) do={ :delay 3 }
    }
    # --- gate: is the measurement alive? (see header) ---
    :local alive false
    :local sid [/system scheduler find name="wanqm-probe"]
    :if ([:len $sid] > 0) do={
        :if (![/system scheduler get ($sid->0) disabled]) do={
            :local cm [/system scheduler get ($sid->0) comment]
            :if ([:typeof [:find $cm "MEASUREMENT-DEAD" -1]] = "nil") do={
                :local pid [/system script find name="wanqm-probe"]
                :if ([:len $pid] > 0) do={
                    :local r1 [/system script get ($pid->0) run-count]
                    # 12 s covers one full 10 s probe tick
                    :delay 12s
                    :local r2 [/system script get ($pid->0) run-count]
                    :if ($r2 > $r1) do={ :set alive true }
                }
            }
        }
    }
    # re-check after the jitter/gate delay - the partner may have recovered meanwhile
    :if ([:len [/tool/netwatch find comment~"^wanqm-fuse-" status="down"]] >= 2) do={
        :if ($alive) do={
            :log warning "[wanqm] FUSE: both targets down but the measurement is alive - leaving the decision to the FSM/orchestrator"
        } else={
            :local cur [/interface/vrrp get [find name=$WanQmCfgVrrp] priority]
            :if ($cur != $WanQmCfgPrioBad) do={
                :log error ("[wanqm] FUSE: both targets down AND the measurement is dead - forcing priority " . $WanQmCfgPrioBad)
                /interface/vrrp set [find name=$WanQmCfgVrrp] priority=$WanQmCfgPrioBad
                :set WanQmNotifySev "crit"
                :set WanQmNotifyText ("FUSE: both ICMP targets down AND measurement dead - emergency lowering priority " . $cur . " -> " . $WanQmCfgPrioBad)
                :do { /system script run wanqm-notify } on-error={ :log error "[wanqm] FUSE: notify failed" }
            } else={
                :log warning "[wanqm] FUSE: priority already lowered - skipping (dedup)"
            }
        }
    }
}
} on-error={ :log error "[wanqm] FUSE: down-script failed" }
