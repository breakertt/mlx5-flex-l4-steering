# mlx5-flex-l4-steering

**Hardware: BlueField-3 (verified) · BlueField-2 (verified with an earlier
revision) · ConnectX-7 (TBC)**

Write-up: [Steering unknown IP protocols to RX queues on mlx5](https://tianyigao.net/blog/2026/mlx5-rss/)

A three-patch Linux mlx5 series that makes these ethtool rules work:

```
ethtool -N <if> flow-type ip4 l4proto <N> l4data <value> m <mask> action <queue>
ethtool -N <if> flow-type ip6 l4proto <N> l4data <value> m <mask> action <queue>
```

They steer packets of an IP protocol the NIC does not parse to RX queues by
the first four bytes of that protocol's header (for most transports, the
source and destination ports). Stock mlx5 rejects any rule with `l4data`
(`-EINVAL`). RSS cannot help either: for an unknown protocol it hashes only
the IP addresses, so all traffic between one pair of hosts lands on one queue.

The series uses the programmable flex parser that the firmware of some NVIDIA
NICs provides (see Requirements):

* on the first `l4data` rule for protocol N, the driver creates a parse graph
  node (general object `0x22`): entered from the IP node when the IPv4
  protocol or IPv6 next header is N, a fixed 4-byte header, one sample of
  dword 0;
* each rule matches the firmware-assigned sample in
  `misc_parameters_4.prog_sample_field_{id,value}_0`;
* the node is reference counted by the rules and destroyed with the last one.

This is steering by exact match, not hashing: a flex parser sample cannot be
an RSS hash input. To spread traffic, install one rule per bucket (see Usage).

## Patches

Based on Linux **v6.18.55** (the current LTS), in `git format-patch` form:

| patch | change |
|---|---|
| `0001-net-mlx5-Add-flex-parser-parse-graph-node-definition.patch` | PRM layout of the parse graph node, its capability bit and enums, in `include/linux/mlx5/mlx5_ifc.h` |
| `0002-net-mlx5e-ethtool-Match-l4_4_bytes-of-IPv4-flows.patch` | the parse graph node and `l4_4_bytes` for `IP_USER_FLOW` (`flow-type ip4`), in `en_fs_ethtool.c` |
| `0003-net-mlx5e-ethtool-Match-l4_4_bytes-of-IPv6-flows.patch` | `l4_4_bytes` for `IPV6_USER_FLOW` (`flow-type ip6`) |

`0000-cover-letter.patch` describes the series and its testing. Each patch
builds on its own with `W=1` without warnings and passes
`checkpatch.pl --strict` with no errors, warnings or checks. The series is
kept here for use on 6.18; it is not submitted upstream.

## Requirements

**Hardware.** A NIC whose firmware has the programmable parser:

| hardware | status |
|---|---|
| BlueField-3 B3220 (`900-9D3B6-00CV-AA0`, MT43244, integrated ConnectX-7), fw 32.47.3576 | verified with this series on 6.18.55 |
| BlueField-2 (`MBF2H332A-AEEOT`, integrated ConnectX-6 Dx) | an earlier revision worked; this series not re-tested |
| standalone ConnectX-7 | TBC |
| standalone ConnectX-6 Dx (MT2892) | not supported: firmware has no `PROG_PARSE_GRAPH` option |
| ConnectX-4 Lx (MT27710) | not supported: rules fail with `Operation not supported` |

BlueField-2 integrates ConnectX-6 Dx and offers the setting; a standalone
ConnectX-6 Dx does not.

**Firmware configuration** (persistent across reboots and OS reinstalls, so
back it up first):

```
TS=$(date +%Y%m%d-%H%M%S)
mstconfig -d <pci> -f nvconfig-$TS.bak backup      # restorable backup
mstconfig -d <pci> q > nvconfig-$TS.txt            # readable snapshot
mstconfig -d <pci> -y set PROG_PARSE_GRAPH=1 FLEX_PARSER_PROFILE_ENABLE=4
mstfwreset -d <pci> -y -l 3 reset
```

Both settings are needed; with only `PROG_PARSE_GRAPH=1`, node creation fails
with "unsupported header length field mode". To revert, restore the backup
(`mstconfig -d <pci> -f nvconfig-<ts>.bak set_raw`) and reset the firmware again.

**Kernel.** `CONFIG_MLX5_EN_RXNFC=y`.

## Building

In a kernel tree: `git am patches/000[1-9]-*.patch`, then build as usual.

Out of tree, against the running kernel's build tree:

```
./build.sh                       # or: ./build.sh /path/to/kernel/build
```

It copies `mlx5/`, `mlxfw/` and `include/linux/mlx5/` from the kernel tree
into `./build`, applies the series, and builds `mlx5_core.ko` with the patched
`mlx5_ifc.h` ahead of the kernel's own (the series only adds definitions, so
the other mlx5 modules are unaffected). Distribution kernels usually ship
headers without driver sources; take `drivers/net/ethernet/mellanox/` from the
matching kernel source package.

Load it (not over a management connection that runs on an mlx5 port):

```
rmmod mlx5_ib mlx5_core
insmod build/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko
```

The module is not installed; a reboot brings back the stock driver.

## Usage

`l4data` is the first four bytes after the IP header, read as a big-endian
number, as the ethtool UAPI defines `l4_4_bytes`. For a header that starts
with 16-bit source and destination ports, `l4data = (sport << 16) | dport`.

`m` is ethtool's mask of bits to **ignore**: `m 0` compares all 32 bits,
`m 0xfffffff0` compares only the low nibble of the destination port.

16 buckets on the destination port's low nibble:

```
IF=<if>
ethtool -K $IF ntuple on
for k in $(seq 0 15); do
  ethtool -N $IF flow-type ip4 l4proto 253 l4data $k m 0xfffffff0 action $k
done
```

Use `flow-type ip6` for IPv6; IPv4 and IPv6 rules for the same protocol can
coexist. One exact (sport, dport) pair to queue 7:

```
ethtool -N $IF flow-type ip4 l4proto 253 l4data $(( (40000 << 16) | 8003 )) m 0 action 7
```

Queue-aligned delivery: a server listening on ports P..P+15 with thread j
pinned to core j, and the interrupt of queue j pinned to core j, gets each
port's packets on its own thread's core with
`l4data $(( (P + j) & 0xf )) m 0xfffffff0 action $j` for j = 0..15.

`ethtool -n $IF` lists rules, `ethtool -N $IF delete <id>` removes one.

## Behaviour and limits

* **Protocols the fixed parser handles are refused** with `-EINVAL`: TCP (6),
  UDP (17), ICMP (1), ICMPv6 (58), IPIP (4), IPv6 (41), GRE (47), ESP (50),
  and the IPv6 extension headers 0, 43, 44, 59 and 60. The firmware does
  accept a parse graph node on such a protocol, but the node then takes over
  from the built-in handling: on GRE it collapsed the inner-header RSS of
  *all* GRE traffic to one queue (64000 packets: 24 queues → 1 queue, 7016
  dropped). The node is entered from the IP node, which serves IPv4 and IPv6
  alike, so the IPv6-only protocols are refused for `ip4` rules too.
  Use the `tcp4` / `udp4` / `tcp6` / `udp6` flow types for TCP and UDP.
* **One protocol per port at a time.** A rule for a second protocol fails
  with `-EBUSY` (and a kernel message) until the first protocol's rules are
  deleted.
* **One network interface per PCI function.** The parse graph node lives in
  the function's firmware but is tracked per network interface. That is the
  normal case (e.g. each BlueField-3 port is one function with one interface).
  Setups with several interfaces on one function, such as SR-IOV switchdev
  representors or IPoIB child interfaces, are not handled: two interfaces
  could each install a node on the same function.
* Devices without the capability fail with `-EOPNOTSUPP`.
* One flex parser sample of the device is in use while any `l4data` rule exists.
* Exact match only: skewed port usage gives skewed queue load.
* Tested on x86-64 (little-endian) only.

## Verification (6.18.55, BlueField-3)

Receiver: Xeon Silver 4314, 32 channels, RX ring 1024, patched `mlx5_core`.
Sender: one Python raw-socket process (`tools/send_l4.py`, about 300k
packets/s), protocol 253, sport 40000, dport 8000..8015 in turn. Per-queue
counts are `ethtool -S` deltas (`tools/rxq.sh`).

| test | result |
|---|---|
| stock driver, any `l4data` rule | `Invalid argument` |
| IPv4, 16 nibble rules, 160000 packets | 16 queues × exactly 10000 |
| IPv6, 16 nibble rules, 160000 packets | 16 queues × exactly 10000 |
| IPv4, no rules, 160000 packets (3 runs) | 1 queue; 205 to 3356 dropped (`rx_out_of_buffer`) |
| IPv4, 16 nibble rules, 160000 packets (3 runs) | 16 × 10000; 0 dropped |
| exact (40000, 8003) → queue 7, 16000 packets, IPv4 and IPv6 | queue 7: exactly 1000 each |
| IPv4 rule added to live IPv6 rules, same protocol | shares the node, steers correctly |
| rule for protocol 254 while 253 is live (ip4 and ip6) | `Device or resource busy` |
| refused protocols (13 for ip4, 7 for ip6) | `Invalid argument` |
| `l4proto` 2, 51, 132, 146, 253 (ip4), 132 (ip6) | accepted |
| ConnectX-4 Lx port | `Operation not supported` |
| UDP to 64 ports + a `udp4` rule, IPv6 ping, with a node live | RSS over 32 queues unchanged; `udp4` rule exact; ping 0% loss |
| 50 add/delete cycles over four protocols, ip4 and ip6 | 50/50 succeed (no sample leak) |
| `rmmod` with live ip4 and ip6 rules, reload, re-add | clean; rules gone after reload; re-added rule works |

No warnings in `dmesg` across the run.

## Files

| path | description |
|---|---|
| `patches/` | the series (`git format-patch`, with cover letter) |
| `build.sh` | out-of-tree build of the patched `mlx5_core` |
| `tools/send_l4.py` | raw IPv4/IPv6 sender for any protocol, cycling the destination port |
| `tools/rxq.sh` | per-RX-queue packet counter snapshot / delta |

## Pitfalls

* A parse graph node on a protocol the NIC already parses silently replaces
  that parsing (the GRE result above). This is why those protocols are refused.
* The ethtool CLI inverts `m`: set bits are ignored, not compared.
* Without steering, a burst of an unknown protocol into one queue overflows
  that queue's ring (`rx_out_of_buffer`) well before the link is busy.

## License

The patches carry the licence of the mlx5 files they modify (GPL-2.0 or the
OpenIB.org BSD licence). The tools are GPL-2.0.

## Acknowledgements

Thanks to Boris for the hint that started this. Developed with the
assistance of Claude Opus.

## Changelog

* 2026-10-09 (c): split into three patches (definitions / IPv4 / IPv6); code
  unchanged; per-interface scope documented.
* 2026-10-09 (b): reworked as a netdev-style series: PRM definitions moved to
  `mlx5_ifc.h` with offset-accurate reserved fields; capability check
  (`-EOPNOTSUPP`); IPv6 (`flow-type ip6`); refused-protocol list extended to
  ICMPv6 and IPv6 extension headers; logic folded into `en_fs_ethtool.c`
  following the GENEVE TLV object pattern, without the earlier poison and
  pre-reference handling; `build.sh`. Re-verified on BlueField-3.
* 2026-10-09 (a): generic `l4proto` (was one fixed protocol); network-order
  `l4data`; 4-byte parse graph header; fixed-parser protocols refused;
  rebased on Linux 6.18.55.
