#!/bin/sh
# Entrypoint script for navigator-cluster image
#
# This script configures DNS resolution for k3s when running in Docker.
#
# Problem: On Docker custom networks, /etc/resolv.conf contains 127.0.0.11
# (Docker's internal DNS). k3s detects this loopback address and automatically
# falls back to 8.8.8.8 - but on Docker Desktop (Mac/Windows), external UDP
# traffic to 8.8.8.8:53 doesn't work due to network limitations. The host
# gateway IP (host.docker.internal) is reachable but doesn't run a DNS server
# either.
#
# Solution: Use iptables to proxy DNS from the container's eth0 IP to Docker's
# embedded DNS resolver at 127.0.0.11. Docker's DNS listens on random high
# ports (visible in the DOCKER_OUTPUT iptables chain), so we parse those ports
# and set up DNAT rules to forward DNS traffic from k3s pods. We then point
# k3s's --resolv-conf at the container's routable eth0 IP.
#
# Per k3s docs: "Manually specified resolver configuration files are not
# subject to viability checks."

set -e

RESOLV_CONF="/etc/rancher/k3s/resolv.conf"

# ---------------------------------------------------------------------------
# Configure DNS proxy via iptables
# ---------------------------------------------------------------------------
# Docker's embedded DNS (127.0.0.11) is only reachable from the container's
# own network namespace via iptables OUTPUT rules. k3s pods run in separate
# network namespaces and route through PREROUTING, so they can't reach it
# directly. We solve this by:
#   1. Discovering the real DNS listener ports from Docker's iptables rules
#   2. Picking the container's eth0 IP as a routable DNS address
#   3. Adding DNAT rules so traffic to <eth0_ip>:53 reaches Docker's DNS
#   4. Writing that IP into the k3s resolv.conf

setup_dns_proxy() {
    # Extract Docker's actual DNS listener ports from the DOCKER_OUTPUT chain.
    # Docker sets up rules like:
    #   -A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j DNAT --to-destination 127.0.0.11:<port>
    #   -A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.11:<port>
    UDP_PORT=$(iptables -t nat -S DOCKER_OUTPUT 2>/dev/null \
        | grep -- '-p udp.*--dport 53' \
        | sed -n 's/.*--to-destination 127.0.0.11:\([0-9]*\).*/\1/p' \
        | head -1)
    TCP_PORT=$(iptables -t nat -S DOCKER_OUTPUT 2>/dev/null \
        | grep -- '-p tcp.*--dport 53' \
        | sed -n 's/.*--to-destination 127.0.0.11:\([0-9]*\).*/\1/p' \
        | head -1)

    if [ -z "$UDP_PORT" ] || [ -z "$TCP_PORT" ]; then
        echo "Warning: Could not discover Docker DNS ports from iptables"
        echo "  UDP_PORT=${UDP_PORT:-<not found>}  TCP_PORT=${TCP_PORT:-<not found>}"
        return 1
    fi

    # Get the container's routable (non-loopback) IP
    CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

    if [ -z "$CONTAINER_IP" ]; then
        echo "Warning: Could not determine container IP from eth0"
        return 1
    fi

    echo "Setting up DNS proxy: ${CONTAINER_IP}:53 -> 127.0.0.11 (udp:${UDP_PORT}, tcp:${TCP_PORT})"

    # Forward DNS from pods (PREROUTING) and local processes (OUTPUT) to Docker's DNS
    iptables -t nat -I PREROUTING -p udp --dport 53 -d "$CONTAINER_IP" -j DNAT \
        --to-destination "127.0.0.11:${UDP_PORT}"
    iptables -t nat -I PREROUTING -p tcp --dport 53 -d "$CONTAINER_IP" -j DNAT \
        --to-destination "127.0.0.11:${TCP_PORT}"

    echo "nameserver $CONTAINER_IP" > "$RESOLV_CONF"
    echo "Configured k3s DNS to use ${CONTAINER_IP} (proxied to Docker DNS)"
}

if ! setup_dns_proxy; then
    echo "DNS proxy setup failed, falling back to public DNS servers"
    echo "Note: this may not work on Docker Desktop (Mac/Windows)"
    cat > "$RESOLV_CONF" <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
fi

# Copy bundled manifests to k3s manifests directory.
# These are stored in /opt/navigator/manifests/ because the volume mount
# on /var/lib/rancher/k3s overwrites any files baked into that path.
if [ -d "/opt/navigator/manifests" ]; then
    echo "Copying bundled manifests to k3s..."
    cp /opt/navigator/manifests/*.yaml /var/lib/rancher/k3s/server/manifests/ 2>/dev/null || true
fi

# Execute k3s with the custom resolv-conf
# The --resolv-conf flag tells k3s to use our DNS configuration instead of /etc/resolv.conf
# Per k3s docs: "Manually specified resolver configuration files are not subject to viability checks"
exec /bin/k3s "$@" --resolv-conf="$RESOLV_CONF"
