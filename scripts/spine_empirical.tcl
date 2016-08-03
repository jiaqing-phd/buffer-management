source "tcp-traffic-gen.tcl"

set ns [new Simulator]
set sim_start [clock seconds]

if {$argc != 24} {
    puts "wrong number of arguments $argc"
    exit 0
}

#### Topology
set link_rate [lindex $argv 0]; #link rate (Gbps)
set mean_link_delay [lindex $argv 1]; #link propagation + processing delay
set host_delay [lindex $argv 2]; #processing delay at end host
set topology_spt [lindex $argv 3]; #number of servers per ToR
set topology_tors [lindex $argv 4]; #number of ToR switches
set topology_spines [lindex $argv 5]; #number of spine (core) switches

#### Traffic
set flow_tot [lindex $argv 6]; #total number of flows to generate
set num_pairs [lindex $argv 7]; #number of senders that a host can receive traffic from
set connections_per_pair [lindex $argv 8]; #the number of parallel connections for each sender-receiver pair
set load [lindex $argv 9]; #average utilization of server-ToR links
set flow_cdf [lindex $argv 10]; #file of flow size CDF
set mean_flow_size [lindex $argv 11]; #average size of the above distributio

#### Transport settings options
set enable_ecn [lindex $argv 12];
set enable_dctcp [lindex $argv 13]
set init_window [lindex $argv 14]
set packet_size [lindex $argv 15]; #packet size in bytes
set rto_min [lindex $argv 16]

#### Switch side options
set switch_alg [lindex $argv 17]
set static_port_pkt [lindex $argv 18]; #static per-port buffer size in packets
set shared_port_bytes [lindex $argv 19]; #dynamic per-port average buffer size in bytes
set enable_shared_buf [lindex $argv 20]; #enable shared buffer management or not
set dt_alpha [lindex $argv 21]; #alpha for DT algorithm
set ecn_thresh [lindex $argv 22]; #ECN marking threshold in packets

### result file
set flowlog [open [lindex $argv 23] w]

set debug_mode 1
set flow_gen 0; #the number of flows that have been generated
set flow_fin 0; #the number of flows that have finished
set source_alg Agent/TCP/FullTcp/Sack

################ Shared Buffer ##################
set tor_shared_buf [expr ($topology_spt + $topology_spines) * $shared_port_bytes]
set spine_shared_buf [expr $topology_tors * $shared_port_bytes]
puts "Shared buffer of ToR switches: $tor_shared_buf"
puts "Shared buffer of spine switches: $spine_shared_buf"

################## TCP #########################
if {$enable_ecn == 1} {
        Agent/TCP set ecn_ 1
        Agent/TCP set old_ecn_ 1
        puts "Enable ECN"
}

if {$enable_dctcp == 1} {
        Agent/TCP set dctcp_ true
        puts "Enable DCTCP"
}

Agent/TCP set dctcp_g_ 0.0625
Agent/TCP set windowInit_ $init_window
Agent/TCP set packetSize_ $packet_size
Agent/TCP set window_ 1256
Agent/TCP set slow_start_restart_ true
Agent/TCP set tcpTick_ 0.000001; # 1us should be enough
Agent/TCP set minrto_ $rto_min
Agent/TCP set rtxcur_init_ $rto_min; # initial RTO
Agent/TCP set maxrto_ 64
Agent/TCP set windowOption_ 0

Agent/TCP/FullTcp set nodelay_ true; # disable Nagle
Agent/TCP/FullTcp set segsize_ $packet_size
Agent/TCP/FullTcp set segsperack_ 1; # ACK frequency
Agent/TCP/FullTcp set interval_ 0.000006; #delayed ACK interval

################ Queue #########################
Queue set limit_ $static_port_pkt
Queue/RED set bytes_ false
Queue/RED set queue_in_bytes_ true
Queue/RED set mean_pktsize_ [expr $packet_size + 40]
Queue/RED set setbit_ true
Queue/RED set gentle_ false
Queue/RED set q_weight_ 1.0
Queue/RED set mark_p_ 1.0
Queue/RED set thresh_ $ecn_thresh
Queue/RED set maxthresh_ $ecn_thresh

if {$enable_shared_buf == 1} {
        Queue/DCTCP set enable_shared_buf_ true
        puts "Enable shared buffer"
}
Queue/DCTCP set thresh_ $ecn_thresh
Queue/DCTCP set mean_pktsize_ [expr $packet_size + 40]
Queue/DCTCP set shared_buf_id_ -1
Queue/DCTCP set alpha_ $dt_alpha
Queue/DCTCP set debug_ false
Queue/DCTCP set pkt_tot_ 0
Queue/DCTCP set pkt_drop_ 0
Queue/DCTCP set pkt_drop_ecn_ 0

################ Multipathing ###########################
$ns rtproto DV
Agent/rtProto/DV set advertInterval [expr 2 * $flow_tot]
Node set multiPath_ 1
Classifier/MultiPath set perflow_ true
Classifier/MultiPath set debug_ false
#if {$debug_mode != 0} {
#        Classifier/MultiPath set debug_ true
#}

######################## Topoplgy #########################
set topology_servers [expr $topology_spt * $topology_tors]; #number of servers
set topology_x [expr ($topology_spt + 0.0) / $topology_spines]

puts "$topology_servers servers in total, $topology_spt servers per rack"
puts "$topology_tors ToR switches"
puts "$topology_spines spine switches"
puts "Oversubscription ratio $topology_x"
flush stdout

for {set i 0} {$i < $topology_servers} {incr i} {
        set s($i) [$ns node]
}

for {set i 0} {$i < $topology_tors} {incr i} {
        set tor($i) [$ns node]
}

for {set i 0} {$i < $topology_spines} {incr i} {
        set spine($i) [$ns node]
}

set qid 0

############ Edge links ##############
for {set i 0} {$i < $topology_servers} {incr i} {
        set j [expr $i/$topology_spt]; # ToR ID
        $ns duplex-link $s($i) $tor($j) [set link_rate]Gb [expr $host_delay + $mean_link_delay] $switch_alg

        ######### configure shared buffer for ToR to server links #######
        set L [$ns link $tor($j) $s($i)]
        set q [$L set queue_]
        $q set shared_buf_id_ $j
        $q set-shared-buffer $j $tor_shared_buf
        $q register
        set queues($qid) $q
        incr qid
}

############ Core links ##############
for {set i 0} {$i < $topology_tors} {incr i} {
        for {set j 0} {$j < $topology_spines} {incr j} {
                $ns duplex-link $tor($i) $spine($j) [set link_rate]Gb $mean_link_delay $switch_alg

                ######### configure shared buffer for ToR to spine links #######
                set L [$ns link $tor($i) $spine($j)]
                set q [$L set queue_]
                $q set shared_buf_id_ $i
                $q set-shared-buffer $i $tor_shared_buf
                $q register
                set queues($qid) $q
                incr qid

                ######## configure shared buffer for spine to ToR links ########
                set L [$ns link $spine($j) $tor($i)]
                set q [$L set queue_]
                $q set shared_buf_id_ [expr $j + $topology_tors]
                $q set-shared-buffer [expr $j + $topology_tors] $spine_shared_buf
                $q register
                set queues($qid) $q
                incr qid
        }
}

######## print information of shared buffer switches #######
$q print

#############  Agents ################
set lambda [expr ($link_rate * $load * 1000000000)/($mean_flow_size * 8.0 / $packet_size * ($packet_size + 40))]
puts "Edge link average utilization: $load"
puts "Arrival: Poisson with inter-arrival [expr 1 / $lambda * 1000] ms"
puts "Average flow size: $mean_flow_size bytes"
puts "Setting up connections ..."; flush stdout

set snd_interval [expr $topology_servers / ($num_pairs + 1)]

for {set j 0} {$j < $topology_servers} {incr j} {
        for {set i 1} {$i <= $num_pairs} {incr i} {
                set snd_id [expr ($j + $i * $snd_interval) % $topology_servers]

                if {$j == $snd_id} {
                        puts "Error: $j == $snd_id"
                        flush stdout
                        exit 0
                } else {
                        puts -nonewline "($snd_id $j) "
                        set agtagr($snd_id,$j) [new Agent_Aggr_pair]
                        $agtagr($snd_id,$j) setup $s($snd_id) $s($j) "$snd_id $j" $connections_per_pair "TCP_pair" $source_alg
                        ## Note that RNG seed should not be zero
                        $agtagr($snd_id,$j) set_PCarrival_process [expr $lambda / $num_pairs] $flow_cdf [expr 17*$snd_id+1244*$j] [expr 33*$snd_id+4369*$j]
                        $agtagr($snd_id,$j) attach-logfile $flowlog

                        $ns at 0.1 "$agtagr($snd_id,$j) warmup 0.5 $packet_size"
                        $ns at 1 "$agtagr($snd_id,$j) init_schedule"
                }
        }
        puts ""
        flush stdout
}

puts "Initial agent creation done"
puts "Simulation started!"
$ns run
