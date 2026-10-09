#!/bin/bash
# Per-RX-queue packet counters. `rxq.sh <if>` prints a snapshot;
# `rxq.sh <if> <snapshot-file>` prints the non-zero deltas since that snapshot.
snap() { ethtool -S "$1" | awk -F'[ :]+' '/^ +rx[0-9]+_packets:/{print $2, $3}'; }
[ -z "$2" ] && { snap "$1"; exit; }
join <(sort "$2") <(snap "$1" | sort) | awk '$3 > $2 {print $1, $3 - $2}' | sort -V
