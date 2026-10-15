# wanqm-notify - THE single notification funnel for wanqm + incident correlation.
# NOT for direct /import (that would execute it once) - INSTALL.rsc reads this file
# into the script store.
#
# Channels:
#   1. Telegram via a LOCAL webhook /notify              - always
#   2. SMS via webhook /sms-send -> REST on the backup router -> LTE modem - sev=crit only
#   3. e-mail - ONLY as a fallback for a POST to /notify that kept failing (see the queue)
#
# Why this is more robust than the old e-mail-only path: the webhook endpoint is LOCAL
# (~1.5 ms away, ttl=63), so the POST does NOT require internet. Neither does the SMS
# (webhook -> REST on the backup router -> LTE modem). The old e-mail went out over SMTP
# through the very link that was failing, so the alert never arrived DURING the outage.
#
# Correlation: the first non-OK alert opens an incident (WanQmIncidentId = "#MMDD-HHMM"),
# every following alert is appended to the WanQmIncidentLog buffer with a relative timestamp,
# and a sev=ok alert closes the incident and sends the FULL timeline as one message. This is
# the answer to "I got 5 e-mails and I cannot tell whether that was one incident or five".
#
# Retry queue: a failed POST is not lost and not mailed straight away. The message - already
# correlated into its incident - goes to WanQmNotifyQueue, and every later run of this script
# first re-sends the queue in order (stopping at the first failure, so a dead webhook costs
# one timeout per run, not one per item), then the current message. wanqm-watchdog drives a
# flush-only run every minute while the queue is not empty. Items older than
# WanQmCfgNotifyRetryS (default 300) go out by e-mail once and are dropped; at most 10 wait.
# Why: in a real outage the FIRST alert (GOOD -> BAD, crit) hit the webhook while the primary
# was still master and the house had no internet - the local webhook answered 500 because its
# own upstream (Telegram) was gone. Three seconds later the backup carried the LAN and the next
# POST went through; the crit one was gone, and the e-mail fallback, sent over the dead link,
# blocked the probe for 21 s and failed too.
# Limits: only the /notify POST is retried, never SMS. The queue is a global, so it is shared
# by the schedulers (probe, orchestrator, watchdog) - an alert queued by the netwatch fuse or
# the VRRP hook lives in THAT environment and is retried only by the next alert from there.
# Two runs flushing in the same second may deliver an item twice - a duplicate beats a loss.
#
# Call (parameters via globals - /system script run takes no arguments):
#   :global WanQmNotifySev "crit"      (crit | warn | ok | flush = only re-send the queue)
#   :global WanQmNotifyText "text"     (NO double quotes and NO backslashes - they break the JSON)
#   /system script run wanqm-notify
:do {
/system script run wanqm-config
:global WanQmCfgMailTo;:global WanQmCfgLinkName
:global WanQmCfgNotifyUrl;:global WanQmCfgNotifyToken
:global WanQmCfgSmsUrl;:global WanQmCfgSmsToken;:global WanQmCfgSmsTo;:global WanQmCfgSmsThrottleS
:global WanQmCfgNotifyHeaders;:global WanQmCfgNotifyBody
:global WanQmCfgSmsHeaders;:global WanQmCfgSmsBody;:global WanQmCfgNotifyRetryS
:global WanQmNotifyQueue
:global WanQmNotifySev;:global WanQmNotifyText;:global WanQmLastSmsAt
:global WanQmIncidentId;:global WanQmIncidentStart;:global WanQmIncidentLog

:local sev "warn"
:if ([:typeof $WanQmNotifySev] = "str") do={ :set sev $WanQmNotifySev }
:local txt "(no text)"
:if ([:typeof $WanQmNotifyText] = "str") do={ :set txt $WanQmNotifyText }
:local now ([:tonsec [:timestamp]] / 1000000000)
:local tag [/system identity get name]
:local flushOnly ($sev = "flush")

# fElapsed: seconds -> "+21s" / "+3m51s"
:local fElapsed do={
    :if ($1 < 60) do={ :return ("+" . $1 . "s") }
    :return ("+" . ($1 / 60) . "m" . ($1 % 60) . "s")
}

# fReplace: $1=text $2=needle $3=replacement -> every occurrence replaced.
# RouterOS has no substring replace, so this does it by hand. The guard of 64 is a
# safety valve: this script sits on the alerting path and must never spin during an outage.
:local fReplace do={
    :local nlen [:len $2]
    :if ($nlen = 0) do={ :return $1 }
    :local out ""
    :local rest $1
    :local guard 0
    :while (([:len $rest] > 0) and ($guard < 64)) do={
        :set guard ($guard + 1)
        :local at [:find $rest $2 -1]
        :if (([:typeof $at] = "nil") or ([:typeof $at] = "nothing")) do={
            :set out ($out . $rest)
            :set rest ""
        } else={
            :set out ($out . [:pick $rest 0 $at] . $3)
            :set rest [:pick $rest ($at + $nlen) [:len $rest]]
        }
    }
    :if ([:len $rest] > 0) do={ :set out ($out . $rest) }
    :return $out
}

# --- incident correlation ---
# RouterOS does not accept literal UTF-8 in strings (verified: emoji get dropped),
# so icons must be written as hex escapes of the UTF-8 bytes.
:local icon "\F0\9F\9F\A1"
:if ($sev = "crit") do={ :set icon "\F0\9F\94\B4" }
:if ($sev = "ok") do={ :set icon "\F0\9F\9F\A2" }

:local haveInc false
:if ([:typeof $WanQmIncidentId] = "str") do={
    :if ([:len $WanQmIncidentId] > 0) do={ :set haveInc true }
}

# the first non-OK alert opens an incident
:if ((!$haveInc) and ($sev != "ok") and (!$flushOnly)) do={
    :local d [/system/clock/get date]
    :local t [/system/clock/get time]
    :set WanQmIncidentId ("#" . [:pick $d 5 7] . [:pick $d 8 10] . "-" . [:pick $t 0 2] . [:pick $t 3 5])
    :set WanQmIncidentStart $now
    :set WanQmIncidentLog [:toarray ""]
    :set haveInc true
}

:local iid ""
:local elapsed 0
:if ($haveInc and (!$flushOnly)) do={
    :set iid $WanQmIncidentId
    :if ([:typeof $WanQmIncidentStart] = "num") do={ :set elapsed ($now - $WanQmIncidentStart) }
    # append to the buffer (capped at 14 entries - protects against overflow during long flapping)
    :local lg $WanQmIncidentLog
    :if ([:typeof $lg] != "array") do={ :set lg [:toarray ""] }
    :if ([:len $lg] < 14) do={
        :set lg ($lg, ([$fElapsed $elapsed] . "  " . $txt))
    }
    :set WanQmIncidentLog $lg
}

# --- build the Telegram message ---
# \\n in the source = two characters (backslash, n) in the string = a proper newline in JSON
:local head ($icon . " [" . $tag . "]")
:if ($haveInc) do={ :set head ($icon . " " . $iid . " [" . $tag . "] " . [$fElapsed $elapsed]) }
:local msg ($head . "\\n" . $txt)

# closing alert: attach the full timeline and close the incident
:if (($sev = "ok") and $haveInc) do={
    :local tl ""
    :foreach e in=$WanQmIncidentLog do={ :set tl ($tl . "\\n" . $e) }
    :set msg ($icon . " " . $iid . " CLOSED [" . $tag . "] - " . [$fElapsed $elapsed] . \
        "\\n----------" . $tl . "\\n----------\\n" . $txt)
    :set WanQmIncidentId ""
    :set WanQmIncidentLog [:toarray ""]
}

# --- channel 1: Telegram via the local webhook ---
# Headers and body come from templates (WanQmCfgNotifyHeaders / WanQmCfgNotifyBody). An
# empty or unset value falls back to the built-in shape, identical to the one used before
# templates existed - so an older config keeps working unchanged.
:local nHdr ""
:if ([:typeof $WanQmCfgNotifyHeaders] = "str") do={ :set nHdr $WanQmCfgNotifyHeaders }
:if ([:len $nHdr] = 0) do={ :set nHdr "Content-Type: application/json,X-Auth-Token: %TOKEN%" }
:set nHdr [$fReplace $nHdr "%TOKEN%" $WanQmCfgNotifyToken]
:local nBody ""
:if ([:typeof $WanQmCfgNotifyBody] = "str") do={ :set nBody $WanQmCfgNotifyBody }
:if ([:len $nBody] = 0) do={ :set nBody "{\"message\":\"%MESSAGE%\"}" }
:local retryS 300
:if ([:typeof $WanQmCfgNotifyRetryS] = "num") do={ :set retryS $WanQmCfgNotifyRetryS }

# the queue: one string per item, "<epoch>\t<sev>\t<incident>\t<message>" (a tab never
# occurs in alert text; an array per item would be flattened by RouterOS on append)
:local q $WanQmNotifyQueue
:if ([:typeof $q] != "array") do={ :set q [:toarray ""] }
:if (!$flushOnly) do={ :set q ($q, ($now . "\t" . $sev . "\t" . $iid . "\t" . $msg)) }
:while ([:len $q] > 10) do={
    :log warning "[wanqm] notify: queue full - dropping the oldest message"
    :set q [:pick $q 1 [:len $q]]
}

# --- channel 1 + 3: POST every queued message in order; e-mail what grew too old ---
:local rest [:toarray ""]
:local blocked false
# escapes live in locals: RouterOS rejects a backslash escape inside a nested [$fn ...] call
:local escNl "\\n"
:local nl "\n"
:foreach e in=$q do={
    :local a [:find $e "\t" -1]
    :local b [:find $e "\t" $a]
    :local c [:find $e "\t" $b]
    :local ts [:tonum [:pick $e 0 $a]]
    :local isev [:pick $e ($a + 1) $b]
    :local iiid [:pick $e ($b + 1) $c]
    :local imsg [:pick $e ($c + 1) [:len $e]]
    :local age ($now - $ts)
    :local sent false
    :if (!$blocked) do={
        :local m $imsg
        :if ($age > 5) do={ :set m ($m . "\\n(queued - delivered " . [$fElapsed $age] . " late)") }
        :local body $nBody
        :set body [$fReplace $body "%SEVERITY%" $isev]
        :set body [$fReplace $body "%ROUTER%" $tag]
        :set body [$fReplace $body "%LINK%" $WanQmCfgLinkName]
        :set body [$fReplace $body "%INCIDENT%" $iiid]
        # %MESSAGE% LAST - alert text may contain a % sign and must never be allowed to
        # expand another placeholder
        :set body [$fReplace $body "%MESSAGE%" $m]
        :do {
            /tool fetch http-method=post output=none \
                url=$WanQmCfgNotifyUrl \
                http-header-field=$nHdr \
                check-certificate=no \
                http-data=$body
            :set sent true
        } on-error={ :set blocked true }
        :if ($sent and ($age > 5)) do={ :log info ("[wanqm] notify: queued message delivered " . [$fElapsed $age] . " late") }
    }
    :if (!$sent) do={
        :if ($age >= $retryS) do={
            :log warning ("[wanqm] notify: POST still failing after " . $age . "s - falling back to e-mail")
            :do {
                /tool/e-mail/send to=$WanQmCfgMailTo \
                    subject=("[wanqm] " . $tag . " " . $WanQmCfgLinkName . " " . $iiid . " (" . $isev . ")") \
                    body=[$fReplace $imsg $escNl $nl]
            } on-error={ :log error "[wanqm] notify: fallback e-mail failed too" }
        } else={
            :set rest ($rest, $e)
        }
    }
}
:set WanQmNotifyQueue $rest
:if ($blocked) do={ :log warning ("[wanqm] notify: POST /notify failed - " . [:len $rest] . " message(s) queued for retry") }

# --- channel 2: SMS - critical only, with a local throttle (defence in depth) ---
:if ($sev = "crit") do={
    # skip while the recipient is __UNSET__ OR still any __PLACEHOLDER__ - the manual
# install path ships the template with __SMS_TO__ and an un-edited copy must not
# try to send SMS
:local smsToSet ([:len $WanQmCfgSmsTo] > 0)
:if ([:typeof [:find $WanQmCfgSmsTo "__" -1]] != "nil") do={ :set smsToSet false }
:if ($smsToSet) do={
        :local pass true
        :if ([:typeof $WanQmLastSmsAt] = "num") do={
            :if (($now - $WanQmLastSmsAt) < $WanQmCfgSmsThrottleS) do={ :set pass false }
        }
        :if ($pass) do={
            :set WanQmLastSmsAt $now
            # SMS: no emoji (GSM7) and truncated - the webhook rejects anything over 480 chars
            :local sms ($tag . " " . $iid . ": " . $txt)
            :if ([:len $sms] > 400) do={ :set sms ([:pick $sms 0 400] . "...") }
            :local sHdr ""
            :if ([:typeof $WanQmCfgSmsHeaders] = "str") do={ :set sHdr $WanQmCfgSmsHeaders }
            :if ([:len $sHdr] = 0) do={ :set sHdr "Content-Type: application/json,X-Auth-Token: %TOKEN%" }
            :set sHdr [$fReplace $sHdr "%TOKEN%" $WanQmCfgSmsToken]
            :local sBody ""
            :if ([:typeof $WanQmCfgSmsBody] = "str") do={ :set sBody $WanQmCfgSmsBody }
            :if ([:len $sBody] = 0) do={ :set sBody "{\"to\":\"%TO%\",\"message\":\"%MESSAGE%\"}" }
            :set sBody [$fReplace $sBody "%SEVERITY%" $sev]
            :set sBody [$fReplace $sBody "%ROUTER%" $tag]
            :set sBody [$fReplace $sBody "%LINK%" $WanQmCfgLinkName]
            :set sBody [$fReplace $sBody "%INCIDENT%" $iid]
            :set sBody [$fReplace $sBody "%TO%" $WanQmCfgSmsTo]
            :set sBody [$fReplace $sBody "%MESSAGE%" $sms]
            :do {
                /tool fetch http-method=post output=none \
                    url=$WanQmCfgSmsUrl \
                    http-header-field=$sHdr \
                    check-certificate=no \
                    http-data=$sBody
            } on-error={ :log error "[wanqm] notify: SMS failed" }
        } else={
            :log warning ("[wanqm] notify: SMS skipped (throttle " . $WanQmCfgSmsThrottleS . "s)")
        }
    }
}
} on-error={ :log error "[wanqm] notify: failed" }
