#!/bin/bash

ALL_IFACE=$(netstat -i | netstat -i | awk '!/lo/ && !/Kernel/ && !/Iface/ && !/bond/{print $1}')

for IFACE in ${ALL_IFACE}
do
	echo "== Tuning ${IFACE} =="
    echo "Ring Buffer"
    ethtool -G ${IFACE} rx 256 tx 256


# LATENCY policy is rx-usecs 5 and tx-usecs 10
# BULK policy is rx-usecs 62 and tx-usecs 122
# CPU policy is rx-usecs 125 and tx-usecs 250


	echo "Interrupt Coalesce"
        ethtool -C ${IFACE} adaptive-rx off
        ethtool -C ${IFACE} adaptive-tx off
        ethtool -C ${IFACE} rx-usecs 5 tx-usecs 10 tx-frames 0
        ethtool -c ${IFACE}

	echo "Attempting to activate Flow Control"
	ethtool -A ${IFACE} rx on
	ethtool -A ${IFACE} tx on
 	ethtool -A ${IFACE} autoneg off rx off tx off

	echo "Checksum Offloading"
	ethtool -K ${IFACE} tx-checksum-ipv4 on
	ethtool -K ${IFACE} tx-checksum-ipv6 on
        ethtool -K ${IFACE} tso off
        ethtool -k ${IFACE}

	echo "Setting TXQueuelen"
	ip link set txqueuelen 500 dev ${IFACE}

	echo "BQL max setting"
	cat /sys/class/net/${IFACE}/queues/tx-0/byte_queue_limits/limit_max
#	cat /sys/devices/pci0000:00/0000:00:14.0/net/${IFACE}/queues/tx-0/byte_queue_limits

	echo

done

  sysctl -w net.ipv4.tcp_low_latency=1
  sysctl -w net.ipv4.tcp_sack=0
  sysctl -w net.ipv4.tcp_timestamps=0
  sysctl -w net.ipv4.tcp_fastopen=1


#iperf3 -s -D -p 5200 &




ip -s link

echo "
Field	Meaning of Non-Zero Values
errors	Poorly or incorrectly negotiated mode and speed, or damaged network cable.
dropped	Possibly due to iptables or other filtering rules, more likely due to lack of network buffer memory.
overrun	Number of times the network interface ran out of buffer space.
carrier	Damaged or poorly connected network cable, or switch problems.
collsns	Number of collisions, which should always be zero on a switched LAN. Non-zero indicates problems negotiating appropriate duplex mode. A small number that never grows means it happened when the interface came up but hasn't happened since.
"
echo "#iperf3 -s -D -p 5200"
