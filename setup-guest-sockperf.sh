#!/usr/bin/env bash
# setup-guest-sockperf.sh — install sockperf inside halt-test VM
# Run as root on panther04.
set -euo pipefail

GUEST_IP=${1:-192.168.122.244}

ssh -o StrictHostKeyChecking=no root@$GUEST_IP bash <<'REMOTE'
set -euo pipefail
dnf install -y epel-release
dnf install -y gcc gcc-c++ automake autoconf libtool make git
if [[ ! -d /opt/sockperf ]]; then
  git clone https://github.com/Mellanox/sockperf.git /opt/sockperf
  cd /opt/sockperf
  ./autogen.sh
  ./configure
  make -j$(nproc)
  make install
fi
sockperf --version || echo "sockperf installed"
REMOTE

echo "sockperf ready in guest."
echo "Start server with:"
echo "  ssh root@$GUEST_IP 'sockperf server --tcp -i 0.0.0.0 -p 11111 --daemonize'"
