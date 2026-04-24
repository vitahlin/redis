# Regression test for redis/redis#9956:
#
# When the Redis instance a Sentinel monitors becomes unreachable in a way
# that leaves a pending asynchronous error on the socket (e.g. ICMP port
# unreachable after a Kubernetes pod IP rotation), a buggy hiredis returns
# 0 from redisNetRead on EAGAIN without consuming SO_ERROR. Because
# ae_epoll.c maps EPOLLERR to AE_READABLE|AE_WRITABLE and EPOLLERR is
# level-triggered until SO_ERROR is cleared, the event loop busy-loops and
# pins Sentinel at ~100% CPU until SENTINEL RESET is issued.

source "../tests/includes/init-tests.tcl"

# ---------- Prerequisite gate ----------
proc can_inject_icmp_unreachable {} {
    if {[exec uname] ne "Linux"} { return 0 }
    if {[catch {exec id -u} uid] || $uid ne "0"} { return 0 }
    if {[catch {exec sh -c "command -v iptables"}]} { return 0 }
    return 1
}

# ---------- Helpers ----------

# Return (utime + stime) jiffies from /proc/$pid/stat, robust against a
# literal ')' appearing inside the comm field.
proc proc_cpu_jiffies {pid} {
    set fh [open "/proc/$pid/stat" r]
    set line [read $fh]
    close $fh
    set tail [string range $line [expr {[string last ")" $line] + 2}] end]
    set f [regexp -all -inline {\S+} $tail]
    # After "state", utime is at offset 11, stime at offset 12.
    return [expr {[lindex $f 11] + [lindex $f 12]}]
}

# Average CPU% used by $pid over $dur_ms milliseconds.
proc measure_cpu_pct {pid dur_ms} {
    set hz [exec getconf CLK_TCK]
    set t0 [proc_cpu_jiffies $pid]
    after $dur_ms
    set t1 [proc_cpu_jiffies $pid]
    set elapsed_jiffies [expr {double($dur_ms) * $hz / 1000.0}]
    return [expr {100.0 * ($t1 - $t0) / $elapsed_jiffies}]
}

# Find the source port of the ESTABLISHED TCP connection owned by $pid
# whose remote endpoint is $remote_ip:$remote_port. Returns "" if none.
proc find_src_port_for_remote {pid remote_ip remote_port} {
    set parts [split $remote_ip "."]
    set hex_ip [format "%02X%02X%02X%02X" \
        [lindex $parts 3] [lindex $parts 2] \
        [lindex $parts 1] [lindex $parts 0]]
    set hex_port [format "%04X" $remote_port]
    set key "${hex_ip}:${hex_port}"

    set fh [open "/proc/$pid/net/tcp" r]
    set data [read $fh]
    close $fh
    foreach line [split $data "\n"] {
        set fields [regexp -all -inline {\S+} $line]
        if {[llength $fields] < 4} continue
        # fields: sl local_address rem_address st ...
        if {[lindex $fields 2] eq $key && [lindex $fields 3] eq "01"} {
            set local [lindex $fields 1]
            set hex [lindex [split $local ":"] 1]
            return [expr "0x$hex"]
        }
    }
    return ""
}

# ---------- Skip path ----------
if {![can_inject_icmp_unreachable]} {
    test "#9956 busy-loop on EPOLLERR (requires Linux+root+iptables)" {
        puts "  \[skipped: prerequisites not met on this host\]"
    }
    return
}

# ---------- The actual test ----------
test "Sentinel does not busy-loop when peer becomes ICMP-unreachable (#9956)" {
    lassign [S 0 SENTINEL GET-MASTER-ADDR-BY-NAME mymaster] master_host master_port
    set sentinel_pid [get_instance_attrib sentinel 0 pid]

    # Quiesce the other sentinels so their own connections to the master
    # do not pull everyone into failover logic while we poison Sentinel 0.
    for {set i 1} {$i < $::instances_count} {incr i} {
        kill_instance sentinel $i
    }

    # Let Sentinel 0 settle and (re)establish its master link.
    after 500
    wait_for_condition 50 100 {
        [find_src_port_for_remote $sentinel_pid $master_host $master_port] ne ""
    } else {
        fail "Sentinel 0 has no ESTABLISHED connection to $master_host:$master_port"
    }
    set sport [find_src_port_for_remote $sentinel_pid $master_host $master_port]
    puts "  sentinel pid=$sentinel_pid  master=$master_host:$master_port  sport=$sport"

    # Idle Sentinel should sit well below 30% CPU.
    set baseline [measure_cpu_pct $sentinel_pid 1000]
    puts "  baseline CPU: [format %.1f $baseline]%"
    assert {$baseline < 30.0}

    # Inject ICMP port-unreachable for only this flow. Using --sport keeps
    # the rule surgical: we only poison Sentinel 0's existing hiredis link
    # to the master. A correct fix lets Sentinel tear down the dead socket
    # and reconnect with a different ephemeral port, bypassing the rule.
    set rule [list OUTPUT -p tcp \
        -d $master_host --dport $master_port --sport $sport \
        -j REJECT --reject-with icmp-port-unreachable]
    exec iptables -I {*}$rule

    # Give the event loop a couple of seconds to either tear the dead
    # connection down (fixed) or settle into the pathological busy-loop
    # (buggy). Sentinel pings every ~1s, so by t=2s at least one PING has
    # been rejected and the socket has SO_ERROR set.
    after 2000

    set cpu [measure_cpu_pct $sentinel_pid 2000]
    puts "  CPU under injected ICMP-unreachable: [format %.1f $cpu]%"

    # Always clean the rule before asserting so a failed assert does not
    # leave stale netfilter state on the host.
    catch {exec iptables -D {*}$rule}

    # Buggy hiredis: ~100% on a single core.
    # Fixed hiredis: back near baseline (reconnected on a fresh sport).
    assert {$cpu < 50.0}
}
