#!/usr/bin/env python3
"""nscan — TCP port scanner (nmap-lite).
iOS 无原生 nmap(SDK 缺 Linux 网络头), 用内置原生 python3 直跑。
用法:
  python3 nscan.py <host> [ports]        # ports 默认 1-1000
  python3 nscan.py -p 22,80 <host>       # nmap 风格 -p
  python3 nscan.py <host> 1-1000,22,443  # 混合区间
"""
import socket
import sys
import argparse
from concurrent.futures import ThreadPoolExecutor


def scan(ip, port, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return (port, s.connect_ex((ip, port)) == 0)
    finally:
        s.close()


def parse_ports(spec):
    ports = []
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            lo, hi = (int(x) for x in part.split('-', 1))
            ports += list(range(lo, hi + 1))
        else:
            ports.append(int(part))
    return ports


def main():
    ap = argparse.ArgumentParser(description='nscan: TCP port scanner (nmap-lite)')
    ap.add_argument('host')
    ap.add_argument('ports', nargs='?', default='1-1000')
    ap.add_argument('-p', dest='pflag', help='ports (nmap 风格, 如 22,80 或 1-1000)')
    ap.add_argument('-t', '--timeout', type=float, default=1.0)
    a = ap.parse_args()
    ports = parse_ports(a.pflag or a.ports)
    open_ports = []
    with ThreadPoolExecutor(max_workers=100) as ex:
        for pt, ok in ex.map(lambda p: scan(a.host, p, a.timeout), ports):
            if ok:
                open_ports.append(pt)
    print('Open ports on %s: %s' % (a.host, sorted(open_ports)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
