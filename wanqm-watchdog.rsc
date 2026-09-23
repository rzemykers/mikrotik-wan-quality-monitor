# wanqm-watchdog - guards freshness of the measurement heartbeat; stale -> log error + alert (max 1/30min) + re-init
# NOT for direct /import (that would execute it once) - INSTALL.rsc reads this file
# into the script store.
:do {
/system script run wanqm-config
:global WanQmCfgMailTo
:global WanQmHeartbeat;:global WanQmWdLastAlert
:global WanQmNotifySev;:global WanQmNotifyText
:local now ([:tonsec [:timestamp]] / 1000000000)
# only runs while the measurement scheduler is enabled
:if ([:len [/system scheduler find name="wanqm-probe" disabled=no]] > 0) do={
    :local stale false
    :if ([:typeof $WanQmHeartbeat] != "num") do={
        :set stale true
    } else={
        :if (($now - $WanQmHeartbeat) > 180) do={ :set stale true }
    }
    # Mirror the verdict into the probe scheduler's comment for the netwatch fuse:
    # netwatch scripts live in an isolated global-variable environment and can never
    # see WanQmHeartbeat, but they CAN read configuration. Written only on transitions.
    :local sid [/system scheduler find name="wanqm-probe"]
    :local cm [/system scheduler get ($sid->0) comment]
    :local flagged ([:typeof [:find $cm "MEASUREMENT-DEAD" -1]] != "nil")
    :if ($stale and (!$flagged)) do={
        /system scheduler set ($sid->0) comment=($cm . " | MEASUREMENT-DEAD")
    }
    :if ((!$stale) and $flagged) do={
        :local at [:find $cm " | MEASUREMENT-DEAD" -1]
        :if ([:typeof $at] != "nil") do={
            /system scheduler set ($sid->0) comment=[:pick $cm 0 $at]
        } else={
            /system scheduler set ($sid->0) comment="wanqm: measurement+FSM"
        }
    }
    :if ($stale) do={
        :log error "[wanqm] watchdog: heartbeat older than 180s - reinitializing logic"
        :if ([:typeof $WanQmWdLastAlert] != "num") do={ :set WanQmWdLastAlert 0 }
        :if (($now - $WanQmWdLastAlert) > 1800) do={
            :set WanQmWdLastAlert $now
            # crit: dead measurement means wanqm is blind - that deserves an SMS
            :set WanQmNotifySev "crit"
            :set WanQmNotifyText "WATCHDOG: wanqm measurement is dead (heartbeat >180s) - re-init done, state=UNKNOWN, orchestrator will not raise priority"
            :do { /system script run wanqm-notify } on-error={
                :do { /tool/e-mail/send to=$WanQmCfgMailTo subject="[wanqm] watchdog: measurement is dead" body="wanqm-probe heartbeat older than 180s - re-init done (state=UNKNOWN, orchestrator will not raise priority)." } on-error={}
            }
        }
        /system script run wanqm-init
    }
}
} on-error={ :log error "[wanqm] watchdog: failed" }
