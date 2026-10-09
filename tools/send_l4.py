#!/usr/bin/env python3
"""Send bare IPv4 or IPv6 packets of protocol <proto> whose first four header
bytes are sport|dport, cycling dport over <nports> consecutive values.

Usage: send_l4.py <dst_ip> <proto> <count> [dport_base=8000] [nports=16] [sport=40000]
"""
import socket
import struct
import sys

args = sys.argv[1:] + [None] * 6
dst, proto, count = args[0], int(args[1]), int(args[2])
base, nports, sport = int(args[3] or 8000), int(args[4] or 16), int(args[5] or 40000)

family = socket.AF_INET6 if ":" in dst else socket.AF_INET
s = socket.socket(family, socket.SOCK_RAW, proto)
for i in range(count):
    s.sendto(struct.pack("!HH", sport, base + i % nports) + b"x" * 60, (dst, 0))
print(f"sent {count} proto-{proto} pkts, sport {sport}, dport {base}..{base + nports - 1}")
