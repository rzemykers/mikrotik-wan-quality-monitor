# wanqm-probe - measurement + aggregation + FSM; writes ONLY globals, NEVER touches VRRP
# NOT for direct /import (that would execute it once) - INSTALL.rsc reads this file
# into the script store.
:do {
/system script run wanqm-config
:global WanQmCfgLinkName;:global WanQmCfgMailTo
:global WanQmCfgTargets;:global WanQmCfgWanIf;:global WanQmCfgPings;:global WanQmCfgWinL;:global WanQmCfgWinS
:global WanQmCfgStreakFail;:global WanQmCfgStreakDeg;:global WanQmCfgStreakBadRec;:global WanQmCfgStreakGoodRec
:global WanQmCfgMinDwellS;:global WanQmCfgMinDegDwellS
:global WanQmCfgVoteFail;:global WanQmCfgVoteDeg
:global WanQmW1sent;:global WanQmW1recv;:global WanQmW1rtt;:global WanQmW1jit
:global WanQmW2sent;:global WanQmW2recv;:global WanQmW2rtt;:global WanQmW2jit
:global WanQmW3sent;:global WanQmW3recv;:global WanQmW3rtt;:global WanQmW3jit
:global WanQmW4sent;:global WanQmW4recv;:global WanQmW4rtt;:global WanQmW4jit
:global WanQmVerd1;:global WanQmVerd2;:global WanQmVerd3;:global WanQmVerd4
:global WanQmM1;:global WanQmM2;:global WanQmM3;:global WanQmM4
:global WanQmState;:global WanQmStateSince;:global WanQmLastCond;:global WanQmCondStreak;:global WanQmHeartbeat
:global WanQmNotifySev;:global WanQmNotifyText

:if ([:typeof $WanQmState] = "nothing") do={ /system script run wanqm-init }

:local now ([:tonsec [:timestamp]] / 1000000000)

# fMeasure: $1=target $2=ping count -> {sent;recv;rttUs;jitUs} (-1 = no data)
# A ping succeeded if the record has NO "status" field (a record can carry "time"
# even on error, e.g. net unreachable).
:local fMeasure do={
    :local sent $2
    :local recv 0
    :local sum 0
    :local jsum 0
    :local jcnt 0
    :local prev -1
    :local res [:toarray ""]
    :do { :set res [/ping $1 count=$2 interval=200ms as-value] } on-error={}
    :foreach r in=$res do={
        :if (([:typeof ($r->"status")] = "nothing") and ([:typeof ($r->"time")] = "time")) do={
            :set recv ($recv + 1)
            :local us ([:tonsec ($r->"time")] / 1000)
            :set sum ($sum + $us)
            :if ($prev >= 0) do={
                :local d ($us - $prev)
                :if ($d < 0) do={ :set d (0 - $d) }
                :set jsum ($jsum + $d)
                :set jcnt ($jcnt + 1)
            }
            :set prev $us
        }
    }
    :local rtt -1
    :if ($recv > 0) do={ :set rtt ($sum / $recv) }
    :local jit -1
    :if ($jcnt > 0) do={ :set jit ($jsum / $jcnt) }
    :return {$sent;$recv;$rtt;$jit}
}

# fTrim: $1=array $2=max length (FIFO - keeps the tail)
:local fTrim do={
    :if ([:len $1] > $2) do={ :return [:pick $1 ([:len $1] - $2) [:len $1]] }
    :return $1
}

# fVerdict: $1..$4 = sent/recv/rtt/jit windows, $5 = previous verdict
# -> {verdict;lossL%;rttLus;jitLus}; dead zone = keep the previous verdict
:local fVerdict do={
    :global WanQmCfgWinS;:global WanQmCfgRttOkUs;:global WanQmCfgRttDegUs
    :global WanQmCfgJitOkUs;:global WanQmCfgJitDegUs
    :global WanQmCfgLossOkPct;:global WanQmCfgLossDegPct;:global WanQmCfgLossFailPct
    :local n [:len $1]
    :local sentL 0
    :local recvL 0
    :for i from=0 to=($n - 1) do={
        :set sentL ($sentL + ($1->$i))
        :set recvL ($recvL + ($2->$i))
    }
    :local s0 ($n - $WanQmCfgWinS)
    :if ($s0 < 0) do={ :set s0 0 }
    :local sentS 0
    :local recvS 0
    :for i from=$s0 to=($n - 1) do={
        :set sentS ($sentS + ($1->$i))
        :set recvS ($recvS + ($2->$i))
    }
    :local lossL 0
    :if ($sentL > 0) do={ :set lossL ((($sentL - $recvL) * 100) / $sentL) }
    :local lossS 0
    :if ($sentS > 0) do={ :set lossS ((($sentS - $recvS) * 100) / $sentS) }
    :local rsum 0
    :local rcnt 0
    :local jsum 0
    :local jcnt 0
    :for i from=0 to=($n - 1) do={
        :if (($3->$i) >= 0) do={ :set rsum ($rsum + ($3->$i)); :set rcnt ($rcnt + 1) }
        :if (($4->$i) >= 0) do={ :set jsum ($jsum + ($4->$i)); :set jcnt ($jcnt + 1) }
    }
    :local rttL -1
    :if ($rcnt > 0) do={ :set rttL ($rsum / $rcnt) }
    :local jitL -1
    :if ($jcnt > 0) do={ :set jitL ($jsum / $jcnt) }
    :local v $5
    :if (($lossS >= $WanQmCfgLossFailPct) or ($recvS = 0)) do={
        :set v "FAIL"
    } else={
        :if (($lossL >= $WanQmCfgLossDegPct) or (($rttL >= 0) and ($rttL >= $WanQmCfgRttDegUs)) or (($jitL >= 0) and ($jitL >= $WanQmCfgJitDegUs))) do={
            :set v "DEG"
        } else={
            :if (($lossL < $WanQmCfgLossOkPct) and ($rttL >= 0) and ($rttL < $WanQmCfgRttOkUs) and ($jitL < $WanQmCfgJitOkUs)) do={ :set v "OK" }
        }
    }
    :return {$v;$lossL;$rttL;$jitL}
}

# fFmt: us -> "12.3ms"
:local fFmt do={
    :if ($1 < 0) do={ :return "n/a" }
    :return ("" . ($1 / 1000) . "." . (($1 % 1000) / 100) . "ms")
}

# --- measure + window + verdict: probe 1 (ISP gateway) ---
:local m [$fMeasure ($WanQmCfgTargets->0) $WanQmCfgPings]
:set WanQmW1sent [$fTrim ($WanQmW1sent, ($m->0)) $WanQmCfgWinL]
:set WanQmW1recv [$fTrim ($WanQmW1recv, ($m->1)) $WanQmCfgWinL]
:set WanQmW1rtt [$fTrim ($WanQmW1rtt, ($m->2)) $WanQmCfgWinL]
:set WanQmW1jit [$fTrim ($WanQmW1jit, ($m->3)) $WanQmCfgWinL]
:local r [$fVerdict $WanQmW1sent $WanQmW1recv $WanQmW1rtt $WanQmW1jit $WanQmVerd1]
:set WanQmVerd1 ($r->0)
:set WanQmM1 ("loss=" . ($r->1) . "% rtt=" . [$fFmt ($r->2)] . " jit=" . [$fFmt ($r->3)])

# --- probe 2 (anycast resolver) ---
:set m [$fMeasure ($WanQmCfgTargets->1) $WanQmCfgPings]
:set WanQmW2sent [$fTrim ($WanQmW2sent, ($m->0)) $WanQmCfgWinL]
:set WanQmW2recv [$fTrim ($WanQmW2recv, ($m->1)) $WanQmCfgWinL]
:set WanQmW2rtt [$fTrim ($WanQmW2rtt, ($m->2)) $WanQmCfgWinL]
:set WanQmW2jit [$fTrim ($WanQmW2jit, ($m->3)) $WanQmCfgWinL]
:set r [$fVerdict $WanQmW2sent $WanQmW2recv $WanQmW2rtt $WanQmW2jit $WanQmVerd2]
:set WanQmVerd2 ($r->0)
:set WanQmM2 ("loss=" . ($r->1) . "% rtt=" . [$fFmt ($r->2)] . " jit=" . [$fFmt ($r->3)])

# --- probe 3 (second, independent anycast resolver) ---
:set m [$fMeasure ($WanQmCfgTargets->2) $WanQmCfgPings]
:set WanQmW3sent [$fTrim ($WanQmW3sent, ($m->0)) $WanQmCfgWinL]
:set WanQmW3recv [$fTrim ($WanQmW3recv, ($m->1)) $WanQmCfgWinL]
:set WanQmW3rtt [$fTrim ($WanQmW3rtt, ($m->2)) $WanQmCfgWinL]
:set WanQmW3jit [$fTrim ($WanQmW3jit, ($m->3)) $WanQmCfgWinL]
:set r [$fVerdict $WanQmW3sent $WanQmW3recv $WanQmW3rtt $WanQmW3jit $WanQmVerd3]
:set WanQmVerd3 ($r->0)
:set WanQmM3 ("loss=" . ($r->1) . "% rtt=" . [$fFmt ($r->2)] . " jit=" . [$fFmt ($r->3)])

# --- probe 4 (own remote host - end-to-end over the real production path) ---
:set m [$fMeasure ($WanQmCfgTargets->3) $WanQmCfgPings]
:set WanQmW4sent [$fTrim ($WanQmW4sent, ($m->0)) $WanQmCfgWinL]
:set WanQmW4recv [$fTrim ($WanQmW4recv, ($m->1)) $WanQmCfgWinL]
:set WanQmW4rtt [$fTrim ($WanQmW4rtt, ($m->2)) $WanQmCfgWinL]
:set WanQmW4jit [$fTrim ($WanQmW4jit, ($m->3)) $WanQmCfgWinL]
:set r [$fVerdict $WanQmW4sent $WanQmW4recv $WanQmW4rtt $WanQmW4jit $WanQmVerd4]
:set WanQmVerd4 ($r->0)
:set WanQmM4 ("loss=" . ($r->1) . "% rtt=" . [$fFmt ($r->2)] . " jit=" . [$fFmt ($r->3)])

# heartbeat right after the measurement (even if the FSM below throws, the data is stored)
:set WanQmHeartbeat $now

# --- voting: LINK state = majority of probes ---
# FAIL needs >= VoteFail of 4 (a single remote host going down cannot cause a failover);
# DEGRADED-or-worse needs >= VoteDeg of 4
:local cFail 0
:local cDegW 0
:foreach v in=({$WanQmVerd1;$WanQmVerd2;$WanQmVerd3;$WanQmVerd4}) do={
    :if ($v = "FAIL") do={ :set cFail ($cFail + 1) }
    :if (($v = "FAIL") or ($v = "DEG")) do={ :set cDegW ($cDegW + 1) }
}
:local linkDown false
:do { :if ([/interface get [find name=$WanQmCfgWanIf] running] = false) do={ :set linkDown true } } on-error={}
:local cond "OK"
:if ($cDegW >= $WanQmCfgVoteDeg) do={ :set cond "DEG" }
:if (($cFail >= $WanQmCfgVoteFail) or $linkDown) do={ :set cond "FAIL" }

# --- streak ---
:if ($cond = $WanQmLastCond) do={
    :set WanQmCondStreak ($WanQmCondStreak + 1)
} else={
    :set WanQmCondStreak 1
    :set WanQmLastCond $cond
}

# --- FSM with hysteresis and dwell times ---
:local inState ($now - $WanQmStateSince)
:local newState $WanQmState
:if ($WanQmState = "UNKNOWN") do={
    :if (($cond = "FAIL") and ($WanQmCondStreak >= $WanQmCfgStreakFail)) do={ :set newState "BAD" }
    :if ([:len $WanQmW1sent] >= $WanQmCfgWinL) do={
        :if ($cond = "OK") do={ :set newState "GOOD" }
        :if ($cond = "DEG") do={ :set newState "DEGRADED" }
    }
}
:if ($WanQmState = "GOOD") do={
    :if (($cond = "FAIL") and ($WanQmCondStreak >= $WanQmCfgStreakFail)) do={ :set newState "BAD" }
    :if (($cond = "DEG") and ($WanQmCondStreak >= $WanQmCfgStreakDeg) and ($inState >= $WanQmCfgMinDwellS)) do={ :set newState "DEGRADED" }
}
:if ($WanQmState = "DEGRADED") do={
    :if (($cond = "FAIL") and ($WanQmCondStreak >= $WanQmCfgStreakFail)) do={ :set newState "BAD" }
    :if (($cond = "OK") and ($WanQmCondStreak >= $WanQmCfgStreakGoodRec) and ($inState >= $WanQmCfgMinDegDwellS)) do={ :set newState "GOOD" }
}
:if ($WanQmState = "BAD") do={
    :if (($cond != "FAIL") and ($WanQmCondStreak >= $WanQmCfgStreakBadRec) and ($inState >= $WanQmCfgMinDwellS)) do={ :set newState "DEGRADED" }
}
:if ($newState != $WanQmState) do={
    :local oldState $WanQmState
    :log warning ("[wanqm] " . $WanQmCfgLinkName . " " . $oldState . " -> " . $newState . " (cond=" . $cond . " x" . $WanQmCondStreak . " | p1=" . $WanQmVerd1 . " " . $WanQmM1 . " | p2=" . $WanQmVerd2 . " " . $WanQmM2 . " | p3=" . $WanQmVerd3 . " " . $WanQmM3 . " | p4=" . $WanQmVerd4 . " " . $WanQmM4 . ")")
    :set WanQmState $newState
    :set WanQmStateSince $now
    # --- notify via wanqm-notify (Telegram + SMS when critical + incident correlation) ---
    # Severity: BAD = crit (a real failover, also goes out by SMS), back to GOOD = ok (closes
    # the incident and sends the full timeline), everything else = warn. The text must contain
    # no double quotes and no backslashes - they would break the JSON POST (see wanqm-notify).
    :local sev "warn"
    :if ($newState = "BAD") do={ :set sev "crit" }
    :if ($newState = "GOOD") do={ :set sev "ok" }
    :local metr ("p1=" . $WanQmM1 . " | p2=" . $WanQmM2 . " | p3=" . $WanQmM3 . " | p4=" . $WanQmM4)
    :local body ($WanQmCfgLinkName . ": " . $oldState . " -> " . $newState . " (cond=" . $cond . " x" . $WanQmCondStreak . ")\\n" . $metr)
    :if ($newState = "DEGRADED") do={ :set body ($body . "\\nVRRP untouched - DEGRADED does not lower the priority") }
    :set WanQmNotifySev $sev
    :set WanQmNotifyText $body
    :do { /system script run wanqm-notify } on-error={ :log error "[wanqm] probe: notify failed" }
}
} on-error={ :log error "[wanqm] probe: measurement tick failed" }
