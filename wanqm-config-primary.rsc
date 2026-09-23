# wanqm-config - WAN Quality Monitor: primary router parameters (THE only place to edit)
# RTT/jitter in microseconds (us), loss in %, times in seconds
# Role drives the installer's enable listing (the backup never enables the orchestrator)
:global WanQmCfgRole "primary"
:global WanQmCfgLinkName "wan1"
# P1=ISP gateway (first mile), P2/P3=anycast resolvers (transit), P4=own remote host
# (e.g. your VPS / the far end of a site-to-site tunnel) - true end-to-end path probe
# !! EXACTLY FOUR targets - the probe loop is unrolled. A fifth is ignored; fewer
# !! than four leaves a slot that fails every tick and permanently eats one vote.
# !! These are RFC 5737 documentation addresses. They do NOT respond to ping.
# !! Replace all four with your own targets before deploying, or every probe FAILs.
:global WanQmCfgTargets {"192.0.2.1";"192.0.2.2";"192.0.2.3";"198.51.100.10"}
# voting: FAIL needs >= VoteFail out of 4 (a single remote host going down must not
# trigger a failover on its own); DEGRADED-or-worse needs >= VoteDeg out of 4
:global WanQmCfgVoteFail 3
:global WanQmCfgVoteDeg 2
:global WanQmCfgWanIf "ether1"
:global WanQmCfgVrrp "vrrp1"
# e-mail is a FALLBACK only, used when the POST to the notification webhook fails
:global WanQmCfgMailTo "you@example.com"
# notifications: point these at a LOCAL webhook endpoint (n8n, Node-RED, anything).
# Local matters: the POST then needs no internet, so the alert still arrives WHILE the
# WAN is down. Put your tokens straight in here - this copy of the template is meant to
# be edited and must never land in a public repo. (The __NAME__ placeholders also serve
# the optional scripted build: build_install.py + secrets.local.)
:global WanQmCfgNotifyUrl "https://n8n.example.com/webhook/notify"
:global WanQmCfgNotifyToken "__NOTIFY_TOKEN__"
:global WanQmCfgSmsUrl "https://n8n.example.com/webhook/sms-send"
:global WanQmCfgSmsToken "__SMS_TOKEN__"
# Leave __UNSET__ (or the placeholder) to safely skip the SMS channel entirely
:global WanQmCfgSmsTo "__SMS_TO__"
# SMS throttle local to the router (defence in depth next to the rate limit in the webhook)
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
# measurement: 5 pings per tick (10s), long window L=12 ticks (~2 min), short S=3 (30 s)
:global WanQmCfgPings 5
:global WanQmCfgWinL 12
:global WanQmCfgWinS 3
# per-probe thresholds (enter OK / enter DEGRADED / FAIL) - calibrate after a week of reports
:global WanQmCfgRttOkUs 25000
:global WanQmCfgRttDegUs 40000
:global WanQmCfgJitOkUs 8000
:global WanQmCfgJitDegUs 15000
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
# VRRP priorities: the backup router holds a static priority of 70.
# PrioGood and PrioBad are LOAD-BEARING for the netwatch fuse as well: it forces
# PrioBad when both fuse targets are down and the measurement is dead, and (only where
# no orchestrator runs) the up-script restores PrioGood.
:global WanQmCfgPrioGood 80
# PrioDeg is UNUSED by the orchestrator: DEGRADED never touches VRRP priority.
# Every write to `/interface vrrp set priority` resets the VRRP FSM on RouterOS, and
# 75 protected nothing anyway since it was always above the backup's 70.
# Kept as a reference value for a possible future score-based model.
:global WanQmCfgPrioDeg 75
:global WanQmCfgPrioBad 30
# orchestrator: damping
:global WanQmCfgHoldDownS 60
:global WanQmCfgFlapMax 3
:global WanQmCfgFlapWinS 900
:global WanQmCfgFreezeS 1800
:global WanQmCfgHbMaxAgeS 60
