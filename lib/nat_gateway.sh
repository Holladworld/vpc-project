#!/bin/bash
# NAT Gateway and Routing Functions
# Handles internet access for public subnets and VPC routing
# Implements AWS-style NAT gateway behavior

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
    # Explanation:
    # - This allows the host to route packets between interfaces
    # - Essential for NAT to work
    # - Without this, packets won't be forwarded between subnets and internet
    
    # === GET PUBLIC INTERFACE ===
    local public_interface=$(ip route show default | awk '/default/ {print $5}')
    # Explanation:
    # - `ip route show default` shows the default route (to internet)
    # - `awk '/default/ {print $5}'` extracts the interface name
    # - This finds which interface connects to the internet
    
    if [[ -z "$public_interface" ]]; then
        echo "Error: Could not determine internet interface"
        return 1
    fi
    
    echo "Detected internet interface: $public_interface"
    
    # === GET ALL PUBLIC SUBNETS IN THIS VPC ===
    echo "Finding public subnets in VPC $vpc_name"
    local public_subnets=()
    
    # Look for public subnet namespaces
    for namespace in $(ip netns list | grep "ns-$vpc_name-public"); do
        # Get the subnet CIDR from the namespace
        local subnet_cidr=$(get_subnet_cidr "$namespace")
        if [[ -n "$subnet_cidr" ]]; then
            public_subnets+=("$subnet_cidr")
            echo "Found public subnet: $subnet_cidr"
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
    # Example output: "inet 10.0.1.2/24" -> we want "10.0.1.0/24"
    local ip_info=$(ip netns exec "$namespace" ip addr show | grep -E "veth-ns.*inet " | head -1)
    
    if [[ -n "$ip_info" ]]; then
        # Extract IP/CIDR part: "inet 10.0.1.2/24" -> "10.0.1.2/24"
        local ip_cidr=$(echo "$ip_info" | awk '{print $2}')
        # Convert to subnet CIDR: "10.0.1.2/24" -> "10.0.1.0/24"
        local network_part="${ip_cidr%/*}"  # Remove /24 -> "10.0.1.2"
        local cidr_mask="${ip_cidr#*/}"     # Get 24 from "10.0.1.2/24"
        local base_ip="${network_part%.*}.0"  # "10.0.1.2" -> "10.0.1.0"
        
        echo "${base_ip}/${cidr_mask}"
    fi
    # Explanation:
    # - We need to convert interface IP (10.0.1.2) to subnet CIDR (10.0.1.0/24)
    # - This tells iptables which entire subnet to NAT
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
    # Explanation:
    # - `-t nat` = Use nat table (for address translation)
    # - `POSTROUTING` = Apply rule after routing decision (on way out)
    # - `-s "$subnet_cidr"` = Match traffic from this subnet
    # - `-o "$public_interface"` = Match traffic going out to internet
    # - `-j MASQUERADE` = Rewrite source address to use interface's IP
    # - This makes internet responses come back to the host
    
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
    # Explanation:
    # - `FORWARD` chain handles packets being routed through the host
    # - `-m state --state ESTABLISHED,RELATED` matches ongoing connections
    # - This allows responses to come back to the public subnets
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
    # Explanation:
    # - This allows subnets within same VPC to communicate
    # - Traffic between br-$vpc_name interfaces is allowed
    # - But different VPCs can't talk unless we explicitly allow it
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
    for ns in $(ip netns list | grep "ns-$vpc_name-public"); do
        echo ""
        echo "Testing PUBLIC subnet: $ns"
        
        # Test internet access
        echo -n "  Internet access: "
        if ip netns exec "$ns" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
            echo "✅ WORKS"
        else
            echo "❌ FAILED"
        fi
        
        # Test gateway access
        local gateway=$(get_gateway_for_namespace "$ns")
        if [[ -n "$gateway" ]]; then
            echo -n "  Gateway access ($gateway): "
            if ip netns exec "$ns" ping -c 1 -W 1 "$gateway" &>/dev/null; then
                echo "✅ WORKS"
            else
                echo "❌ FAILED"
            fi
        fi
    done
    
    # Test private subnets
    for ns in $(ip netns list | grep "ns-$vpc_name-private"); do
        echo ""
        echo "Testing PRIVATE subnet: $ns"
        
        # Test internet access (should fail)
        echo -n "  Internet access: "
        if ip netns exec "$ns" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
            echo "❌ UNEXPECTED SUCCESS (private subnet should be isolated)"
        else
            echo "✅ CORRECTLY ISOLATED"
        fi
        
        # Test gateway access
        local gateway=$(get_gateway_for_namespace "$ns")
        if [[ -n "$gateway" ]]; then
            echo -n "  Gateway access ($gateway): "
            if ip netns exec "$ns" ping -c 1 -W 1 "$gateway" &>/dev/null; then
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
    # Explanation:
    # - `ip route show default` shows the default route
    # - `awk '/default/ {print $3}'` extracts the gateway IP
    # - Returns the gateway IP or empty string if no route
}

# === CLEANUP NAT RULES ===
cleanup_nat_rules() {
    local vpc_name="$1"
    
    echo "Cleaning up NAT rules for VPC: $vpc_name"
    
    # This function would remove iptables rules when VPC is deleted
    # We'll implement this in the cleanup phase
    echo "NAT cleanup will be implemented in deletion phase"
}