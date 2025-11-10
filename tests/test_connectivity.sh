#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPCCTL="${SCRIPT_DIR}/../vpcctl"

log() {
    echo "[TEST] $*"
}

test_vpc_creation() {
    log "Testing VPC creation..."
    $VPCCTL create-vpc test-vpc-1 10.0.0.0/16
    $VPCCTL create-vpc test-vpc-2 10.1.0.0/16
}

test_subnet_creation() {
    log "Testing subnet creation..."
    $VPCCTL add-subnet test-vpc-1 public 10.0.1.0/24
    $VPCCTL add-subnet test-vpc-1 private 10.0.2.0/24
    $VPCCTL add-subnet test-vpc-2 public 10.1.1.0/24
}

test_connectivity() {
    log "Testing connectivity..."
    
    # Test inter-subnet communication within same VPC
    log "Testing inter-subnet communication..."
    ip netns exec ns-test-vpc-1-public ping -c 2 10.0.2.2 && \
        log "✓ Inter-subnet communication works" || \
        log "✗ Inter-subnet communication failed"
    
    # Test public subnet internet access
    log "Testing public subnet internet access..."
    ip netns exec ns-test-vpc-1-public ping -c 2 8.8.8.8 && \
        log "✓ Public subnet has internet access" || \
        log "✗ Public subnet no internet access"
    
    # Test private subnet isolation
    log "Testing private subnet isolation..."
    ip netns exec ns-test-vpc-1-private ping -c 2 8.8.8.8 && \
        log "✗ Private subnet has internet (should not)" || \
        log "✓ Private subnet properly isolated"
    
    # Test VPC isolation
    log "Testing VPC isolation..."
    ip netns exec ns-test-vpc-1-public ping -c 2 10.1.1.2 && \
        log "✗ VPC isolation broken" || \
        log "✓ VPCs properly isolated"
}

test_peering() {
    log "Testing VPC peering..."
    $VPCCTL create-peering test-vpc-1 test-vpc-2
    
    # After peering, they should be able to communicate
    log "Testing cross-VPC communication after peering..."
    ip netns exec ns-test-vpc-1-public ping -c 2 10.1.1.2 && \
        log "✓ VPC peering working" || \
        log "✗ VPC peering not working"
}

test_firewall() {
    log "Testing firewall rules..."
    $VPCCTL apply-firewall test-vpc-1
    
    # Start test web server in public subnet
    ip netns exec ns-test-vpc-1-public python3 -m http.server 80 &
    local server_pid=$!
    sleep 2
    
    # Test allowed port (80)
    ip netns exec ns-test-vpc-1-private curl -s http://10.0.1.2:80 >/dev/null && \
        log "✓ Port 80 allowed (as per rules)" || \
        log "✗ Port 80 blocked (should be allowed)"
    
    # Test blocked port (22)
    ip netns exec ns-test-vpc-1-private nc -z -w 2 10.0.1.2 22 && \
        log "✗ Port 22 allowed (should be blocked)" || \
        log "✓ Port 22 blocked (as per rules)"
    
    kill $server_pid 2>/dev/null
}

run_all_tests() {
    log "Starting comprehensive VPC tests..."
    
    test_vpc_creation
    test_subnet_creation
    test_connectivity
    test_peering
    test_firewall
    
    log "All tests completed!"
}

run_all_tests