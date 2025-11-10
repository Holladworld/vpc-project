#!/bin/bash

start_web_servers() {
    log "Starting demo web servers..."
    
    # Start web server in public subnet
    ip netns exec ns-test-vpc-1-public sh -c 'cd /tmp && python3 -m http.server 8080 > /tmp/public_web.log 2>&1 &'
    log "Web server started in public subnet (port 8080)"
    
    # Start web server in private subnet  
    ip netns exec ns-test-vpc-1-private sh -c 'cd /tmp && python3 -m http.server 8080 > /tmp/private_web.log 2>&1 &'
    log "Web server started in private subnet (port 8080)"
    
    # Test accessibility
    log "Testing web server accessibility..."
    
    log "Public subnet web server (from private subnet):"
    ip netns exec ns-test-vpc-1-private curl -s http://10.0.1.2:8080 >/dev/null && \
        log "✓ Public web server accessible from private subnet" || \
        log "✗ Public web server not accessible"
    
    log "Private subnet web server (from public subnet):"
    ip netns exec ns-test-vpc-1-public curl -s http://10.0.2.2:8080 >/dev/null && \
        log "✓ Private web server accessible from public subnet" || \
        log "✗ Private web server not accessible"
}

show_status() {
    log "Current VPC Status:"
    echo "=== Network Namespaces ==="
    ip netns list
    
    echo "=== Bridges ==="
    ip link show type bridge
    
    echo "=== Web Server Processes ==="
    ps aux | grep "python3 -m http.server" | grep -v grep
}

case "$1" in
    start)
        start_web_servers
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {start|status}"
        exit 1
        ;;
esac