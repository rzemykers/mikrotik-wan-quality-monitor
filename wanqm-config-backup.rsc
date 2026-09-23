# wanqm-config - WAN Quality Monitor: backup router parameters (THE only place to edit)
# Backup router on metered 5G/LTE. The orchestrator here is DISABLED ON PURPOSE and
# PERMANENTLY - this router keeps a static priority of 70. Reason: the LTE link has a
# monthly data cap while the primary link does not, so the backup must NEVER outbid the
# primary on its own (primary runs 80 / DEGRADED-noop / 30). Even a well-chosen priority
# map would risk the opposite scenario (backup > primary while the primary link is fine).
# So on this router wanqm only measures, logs and alerts (informational), plus the
# netwatch fuse as a backstop.
# RTT/jitter in microseconds (us), loss in %, times in seconds
# Role drives the installer's enable listing (the backup never enables the orchestrator)
:global WanQmCfgRole "backup"
:global WanQmCfgLinkName "lte1"
# LTE has no pingable IP gateway (interface route) - no P1 equivalent here;
# P1-P3=anycast resolvers (transit), P4=own remote host (end-to-end, same as primary)
# !! EXACTLY FOUR targets - the probe loop is unrolled. A fifth is ignored; fewer
# !! than four leaves a slot that fails every tick and permanently eats one vote.
# !! These are RFC 5737 documentation addresses. They do NOT respond to ping.
# !! Replace all four with your own targets before deploying, or every probe FAILs.
:global WanQmCfgTargets {"192.0.2.2";"192.0.2.3";"192.0.2.4";"198.51.100.10"}
:global WanQmCfgWanIf "lte1"
:global WanQmCfgVrrp "vrrp1"
# e-mail is a FALLBACK only, used when the POST to the notification webhook fails
:global WanQmCfgMailTo "you@example.com"
# notifications: local webhook. Note - THIS router is the one sending SMS (its LTE modem),
# so the SMS path from here is: webhook -> REST back to this very router -> modem.
# Put your tokens straight in here - this copy of the template is meant to be edited
# and must never land in a public repo. (The __NAME__ placeholders also serve the
# optional scripted build: build_install.py + secrets.local.)
:global WanQmCfgNotifyUrl "https://n8n.example.com/webhook/notify"
:global WanQmCfgNotifyToken "__NOTIFY_TOKEN__"
:global WanQmCfgSmsUrl "https://n8n.example.com/webhook/sms-send"
:global WanQmCfgSmsToken "__SMS_TOKEN__"
# Leave __UNSET__ (or the placeholder) to safely skip the SMS channel entirely
:global WanQmCfgSmsTo "__SMS_TO__"
:global WanQmCfgSmsThrottleS 900
# --- HTTP request shape (templates) ---
# Placeholders: %MESSAGE% %SEVERITY% %ROUTER% %LINK% %INCIDENT% %TOKEN% %TO%
# %MESSAGE% is substituted LAST, so alert text can never expand another placeholder.
# An empty value means "use the built-in default" - identical to the values below.
# NOTE: alert text still may not contain " or \ - the body is concatenated, not escaped.
# Other receivers:
#   Gotify: headers "Content-Type: application/json,X-Gotify-Key: %TOKEN%"
#           body    "{\"title\":\"wanqm %ROUTER%\",\"message\":\"%MESSAGE%\"}"
#   ntfy:   headers "Content-Type: application/json,Authorization: Bearer %TOKEN%"
#           body    "{\"topic\":\"wanqm\",\"message\":\"%MESSAGE%\",\"tags\":[\"%SEVERITY%\"]}"
#   Slack:  headers "Content-Type: application/json"   (the token lives in the webhook URL)
#           body    "{\"text\":\"%MESSAGE%\"}"
:global WanQmCfgNotifyHeaders "Content-Type: application/json,X-Auth-Token: %TOKEN%"
:global WanQmCfgNotifyBody "{\"message\":\"%MESSAGE%\"}"
:global WanQmCfgSmsHeaders "Content-Type: application/json,X-Auth-Token: %TOKEN%"
:global WanQmCfgSmsBody "{\"to\":\"%TO%\",\"message\":\"%MESSAGE%\"}"
# voting: same as primary - FAIL >= 3 of 4, DEG >= 2 of 4
:global WanQmCfgVoteFail 3
:global WanQmCfgVoteDeg 2
# measurement: 5 pings per tick (10s), long window L=12 ticks (~2 min), short S=3 (30 s)
:global WanQmCfgPings 5
:global WanQmCfgWinL 12
:global WanQmCfgWinS 3
# LTE thresholds - set these from YOUR baseline, these are only a starting point
# OK ~ baseline+margin, DEG ~ 2.5x baseline; calibrate after a week of reports
:global WanQmCfgRttOkUs 30000
:global WanQmCfgRttDegUs 45000
:global WanQmCfgJitOkUs 10000
:global WanQmCfgJitDegUs 20000
:global WanQmCfgLossOkPct 2
:global WanQmCfgLossDegPct 5
:global WanQmCfgLossFailPct 60
# FSM: required streaks (in 10 s ticks) and minimum dwell times per state (s)
:global WanQmCfgStreakFail 2
:global WanQmCfgStreakDeg 3
:global WanQmCfgStreakBadRec 6
:global WanQmCfgStreakGoodRec 12
:global WanQmCfgMinDwellS 30
:global WanQmCfgMinDegDwellS 60
# VRRP priorities - the orchestrator here stays disabled, but these are NOT mere
# reference values: the netwatch fuse WRITES them. With both fuse targets down and the
# measurement dead it forces PrioBad (20 - deliberately below the primary's BAD floor
# of 30, so a dead backup can never win the election), and when a target comes back the
# up-script restores PrioGood (70 - the backup's static priority; nothing else would
# restore it, ours once sat at 20 for 4.5 days). Change them only together with the
# primary's map. PrioDeg stays unused.
:global WanQmCfgPrioGood 70
:global WanQmCfgPrioDeg 65
:global WanQmCfgPrioBad 20
# orchestrator: damping (inactive - scheduler permanently disabled)
:global WanQmCfgHoldDownS 60
:global WanQmCfgFlapMax 3
:global WanQmCfgFlapWinS 900
:global WanQmCfgFreezeS 1800
:global WanQmCfgHbMaxAgeS 60
