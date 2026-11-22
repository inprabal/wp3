#!/bin/bash
set -euo pipefail

cd /home/kali/wifipumpkin3

echo "Starting WP3 captive portal inside wp3-ns..."

sudo ip netns exec wp3-ns \
    runuser -u kali -- \
    /usr/bin/python3 /home/kali/wifipumpkin3/wp3-portal.py
