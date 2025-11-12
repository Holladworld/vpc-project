#!/bin/bash
# NAT Gateway and Routing Functions

# === ENABLE NAT FOR VPC ===
enable_nat() {
    local vpc_name="$1"
    
    if [[ -z "$vpc_name" ]]; then
        echo "Error: VPC name is required"
        echo "Usage: enable-nat <vpc_name>"
        return 1
    fi
    
    local bridge_name="br-$vpc_name"
    
    # Check if VPC exists
    if ! ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name does not exist"
        return 1
    fi
    
    echo "Enabling NAT gateway for VPC: $vpc_name"
    
    # === ENABLE IP FORWARDING ON HOST ===
    echo "Enabling IP forwarding on host"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # === GET PUBLIC INTERFACE ===
    local public_interface=$(ip route show default | awk '/default/ {print $5}')
    
    if [[ -z "$public_interface" ]]; then
        echo "Error: Could not determine internet interface"
        return 1
    fi
    
    echo "Detected internet interface: $public_interface"
    
    # === GET ALL PUBLIC SUBNETS IN THIS VPC ===
    echo "Finding public subnets in VPC $vpc_name"
    local public_subnets=()
    
    # FIXED: Handle namespace IDs properly
    for namespace in $(ip netns list | grep "ns-$vpc_name-public"); do
        local clean_namespace=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
        # Get the subnet CIDR from the namespace
        local subnet_cidr=$(get_subnet_cidr "$clean_namespace")
        if [[ -n "$subnet_cidr" ]]; then
            public_subnets+=("$subnet_cidr")
            echo "Found public subnet: $subnet_cidr (namespace: $clean_namespace)"
        fi
    done
    
    if [[ ${#public_subnets[@]} -eq 0 ]]; then
        echo "Warning: No public subnets found in VPC $vpc_name"
        echo "Create public subnets first: $0 add-subnet $vpc_name public 10.0.1.0/24"
        return 1
    fi
    
    # === SETUP NAT RULES FOR EACH PUBLIC SUBNET ===
    for subnet_cidr in "${public_subnets[@]}"; do
        setup_nat_rules "$vpc_name" "$subnet_cidr" "$public_interface"
    done
    
    # === SETUP BASIC FIREWALL FOR ISOLATION ===
    setup_vpc_isolation "$vpc_name"
    
    echo "✅ NAT gateway enabled for VPC $vpc_name"
    echo "   Public subnets can now access the internet"
    echo "   Private subnets remain isolated"
}

# === GET SUBNET CIDR FROM NAMESPACE ===
get_subnet_cidr() {
    local namespace="$1"
    
    # Get the IP address from the veth interface in the namespace
    local ip_info=$(ip netns exec "$namespace" ip addr show 2>/dev/null | grep -E "vn.*inet" | head -1)
    
    if [[ -n "$ip_info" ]]; then
        # Extract IP/CIDR part: "inet 10.0.1.2/24" -> "10.0.1.2/24"
        local ip_cidr=$(echo "$ip_info" | awk '{print $2}')
        # Convert to subnet CIDR: "10.0.1.2/24" -> "10.0.1.0/24"
        local network_part="${ip_cidr%/*}"  # Remove /24 -> "10.0.1.2"
        local cidr_mask="${ip_cidr#*/}"     # Get 24 from "10.0.1.2/24"
        local base_ip="${network_part%.*}.0"  # "10.0.1.2" -> "10.0.1.0"
        
        echo "${base_ip}/${cidr_mask}"
    fi
}

# === SETUP NAT RULES ===
setup_nat_rules() {
    local vpc_name="$1"
    local subnet_cidr="$2"
    local public_interface="$3"
    
    echo "Setting up NAT for subnet: $subnet_cidr"
    
    # === MASQUERADE RULE (OUTGOING TRAFFIC) ===
    # This makes outgoing traffic appear to come from host instead of subnet
    if ! iptables -t nat -C POSTROUTING -s "$subnet_cidr" -o "$public_interface" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$subnet_cidr" -o "$public_interface" -j MASQUERADE
        echo "  Added MASQUERADE rule for $subnet_cidr -> $public_interface"
    fi
    
    # === FORWARDING RULES (ALLOW TRAFFIC FLOW) ===
    # Allow forwarding FROM public subnets TO internet
    if ! iptables -C FORWARD -s "$subnet_cidr" -o "$public_interface" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s "$subnet_cidr" -o "$public_interface" -j ACCEPT
        echo "  Added FORWARD rule: $subnet_cidr -> internet"
    fi
    
    # Allow forwarding FROM internet back TO public subnets (for responses)
    if ! iptables -C FORWARD -d "$subnet_cidr" -i "$public_interface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -d "$subnet_cidr" -i "$public_interface" -m state --state ESTABLISHED,RELATED -j ACCEPT
        echo "  Added FORWARD rule: internet -> $subnet_cidr (established)"
    fi
}

# === SETUP VPC ISOLATION ===
setup_vpc_isolation() {
    local vpc_name="$1"
    
    echo "Setting up basic isolation for VPC: $vpc_name"
    
    # Allow all traffic within the same VPC bridge
    if ! iptables -C FORWARD -i "br-$vpc_name" -o "br-$vpc_name" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "br-$vpc_name" -o "br-$vpc_name" -j ACCEPT
        echo "  Added internal VPC forwarding: br-$vpc_name <-> br-$vpc_name"
    fi
}

# === TEST CONNECTIVITY ===
test_connectivity() {
    local vpc_name="$1"
    
    if [[ -z "$vpc_name" ]]; then
        echo "Error: VPC name is required"
        echo "Usage: test-connectivity <vpc_name>"
        return 1
    fi
    
    echo "=== Testing Connectivity for VPC: $vpc_name ==="
    
    # Test public subnets
    for namespace in $(ip netns list | grep "ns-$vpc_name-public"); do
        local clean_ns=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
        echo ""
        echo "Testing PUBLIC subnet: $clean_ns"
        
        # Test internet access
        echo -n "  Internet access: "
        if ip netns exec "$clean_ns" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
            echo "✅ WORKS"
        else
            echo "❌ FAILED"
        fi
        
        # Test gateway access
        local gateway=$(get_gateway_for_namespace "$clean_ns")
        if [[ -n "$gateway" ]]; then
            echo -n "  Gateway access ($gateway): "
            if ip netns exec "$clean_ns" ping -c 1 -W 1 "$gateway" &>/dev/null; then
                echo "✅ WORKS"
            else
                echo "❌ FAILED"
            fi
        fi
    done
    
    # Test private subnets
    for namespace in $(ip netns list | grep "ns-$vpc_name-private"); do
        local clean_ns=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
        echo ""
        echo "Testing PRIVATE subnet: $clean_ns"
        
        # Test internet access (should fail)
        echo -n "  Internet access: "
        if ip netns exec "$clean_ns" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
            echo "❌ UNEXPECTED SUCCESS (private subnet should be isolated)"
        else
            echo "✅ CORRECTLY ISOLATED"
        fi
        
        # Test gateway access
        local gateway=$(get_gateway_for_namespace "$clean_ns")
        if [[ -n "$gateway" ]]; then
            echo -n "  Gateway access ($gateway): "
            if ip netns exec "$clean_ns" ping -c 1 -W 1 "$gateway" &>/dev/null; then
                echo "✅ WORKS"
            else
                echo "❌ FAILED"
            fi
        fi
    done
    
    echo ""
    echo "=== Connectivity Test Complete ==="
}

# === GET GATEWAY FOR NAMESPACE ===
get_gateway_for_namespace() {
    local namespace="$1"
    
    # Get the default gateway from namespace's routing table
    ip netns exec "$namespace" ip route show default 2>/dev/null | awk '/default/ {print $3}'
}

# === CLEANUP NAT RULES ===
cleanup_nat_rules() {
    local vpc_name="$1"
    
    echo "Cleaning up NAT rules for VPC: $vpc_name"
    
    # Remove MASQUERADE rules for this VPC
    iptables -t nat -S | grep "br-$vpc_name" | while read rule; do
        iptables -t nat -D ${rule#-A}
    done
    
    # Remove FORWARD rules for this VPC
    iptables -S | grep "br-$vpc_name" | while read rule; do
        iptables -D ${rule#-A}
    done
    
    echo "Cleaned up NAT rules for VPC $vpc_name"
}

# === GET PUBLIC INTERFACE ===
get_public_interface() {
    ip route show default | awk '/default/ {print $5}'
}

# === VERIFY NAT SETUP ===
verify_nat_setup() {
    local vpc_name="$1"
    
    echo "=== Verifying NAT Setup for VPC: $vpc_name ==="
    
    echo "1. Checking NAT rules:"
    iptables -t nat -L POSTROUTING -n -v | grep -E "MASQUERADE|br-$vpc_name" || echo "  No NAT rules found"
    
    echo "2. Checking FORWARD rules:"
    iptables -L FORWARD -n -v | grep -E "br-$vpc_name" || echo "  No FORWARD rules found"
    
    echo "3. Checking IP forwarding:"
    cat /proc/sys/net/ipv4/ip_forward
    
    echo "4. Checking public subnets:"
    for namespace in $(ip netns list | grep "ns-$vpc_name-public"); do
        local clean_ns=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
        echo "  - $clean_ns"
    done
}

# === CHECK INTERNET CONNECTIVITY ===
check_internet_connectivity() {
    local namespace="$1"
    
    echo "Checking internet connectivity for $namespace"
    
    # Test DNS resolution
    echo -n "  DNS resolution: "
    if ip netns exec "$namespace" nslookup google.com 8.8.8.8 &>/dev/null; then
        echo "✅ WORKS"
    else
        echo "❌ FAILED"
    fi
    
    # Test HTTP access
    echo -n "  HTTP access: "
    if ip netns exec "$namespace" curl -s --connect-timeout 3 -I http://google.com &>/dev/null; then
        echo "✅ WORKS"
    else
        echo "❌ FAILED"
    fi
    
    # Test ICMP (ping)
    echo -n "  ICMP (ping): "
    if ip netns exec "$namespace" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
        echo "✅ WORKS"
    else
        echo "❌ FAILED"
    fi
}

# === DIAGNOSE NAT ISSUES ===
diagnose_nat_issues() {
    local vpc_name="$1"
    
    echo "=== NAT Issue Diagnosis for VPC: $vpc_name ==="
    
    echo "1. Host internet connectivity:"
    ping -c 1 -W 1 8.8.8.8 &>/dev/null && echo "  ✅ Host has internet" || echo "  ❌ Host no internet"
    
    echo "2. IP forwarding status:"
    local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    if [[ "$ip_forward" == "1" ]]; then
        echo "  ✅ IP forwarding enabled"
    else
        echo "  ❌ IP forwarding disabled"
    fi
    
    echo "3. Public interface:"
    local public_if=$(get_public_interface)
    if [[ -n "$public_if" ]]; then
        echo "  ✅ Public interface: $public_if"
    else
        echo "  ❌ No public interface found"
    fi
    
    echo "4. NAT rules:"
    iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || echo "  No MASQUERADE rules"
    
    echo "5. Public subnets:"
    local found_public=0
    for namespace in $(ip netns list | grep "ns-$vpc_name-public"); do
        local clean_ns=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
        echo "  - $clean_ns"
        found_public=1
    done
    if [[ $found_public -eq 0 ]]; then
        echo "  ❌ No public subnets found"
    fi
}

# === RESET NAT RULES ===
reset_nat_rules() {
    local vpc_name="$1"
    
    echo "Resetting NAT rules for VPC: $vpc_name"
    
    # Remove all rules for this VPC
    cleanup_nat_rules "$vpc_name"
    
    # Re-enable NAT
    enable_nat "$vpc_name"
    
    echo "NAT rules reset for VPC $vpc_name"
}

# === LIST NAT RULES ===
list_nat_rules() {
    echo "=== Current NAT Rules ==="
    
    echo "NAT Table:"
    iptables -t nat -L -n -v
    
    echo ""
    echo "Filter Table (FORWARD):"
    iptables -L FORWARD -n -v
}

# === RUN ALL TESTS ===
run_nat_tests() {
    local vpc_name="$1"
    
    echo "=== Running Comprehensive NAT Tests for VPC: $vpc_name ==="
    
    verify_nat_setup "$vpc_name"
    echo ""
    test_connectivity "$vpc_name"
    echo ""
    diagnose_nat_issues "$vpc_name"
}
