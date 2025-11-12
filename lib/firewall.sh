#!/bin/bash
# Firewall Management Functions
# Implements JSON-based security groups like AWS
# Provides network-level security for VPCs and subnets

# === APPLY FIREWALL RULES ===
apply_firewall() {
    local vpc_name="$1"
    local rules_file="$2"
    
    if [[ -z "$vpc_name" || -z "$rules_file" ]]; then
        echo "Error: VPC name and rules file are required"
        echo "Usage: apply-firewall <vpc_name> <rules_file.json>"
        return 1
    fi
    
    if [[ ! -f "$rules_file" ]]; then
        echo "Error: Rules file not found: $rules_file"
        return 1
    fi
    
    # Check if jq is available for JSON parsing
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required for JSON parsing. Install with: apt-get install jq"
        return 1
    fi
    
    echo "Applying firewall rules from $rules_file to VPC: $vpc_name"
    
    # Validate JSON syntax
    if ! jq empty "$rules_file" 2>/dev/null; then
        echo "Error: Invalid JSON in rules file"
        return 1
    fi
    
    # === PROCESS EACH RULE IN JSON FILE ===
    local rules_count=$(jq '.rules | length' "$rules_file")
    echo "Found $rules_count firewall rules to apply"
    
    for ((i=0; i<rules_count; i++)); do
        local subnet=$(jq -r ".rules[$i].subnet" "$rules_file")
        local namespace=$(find_namespace_by_subnet "$vpc_name" "$subnet")
        
        if [[ -n "$namespace" ]]; then
            echo "Applying rules to subnet: $subnet (namespace: $namespace)"
            apply_namespace_rules "$namespace" "$rules_file" "$i"
        else
            echo "Warning: No namespace found for subnet $subnet, skipping rules"
        fi
    done
    
    echo "✅ Firewall rules applied successfully to VPC $vpc_name"
}

# === FIND NAMESPACE BY SUBNET ===
find_namespace_by_subnet() {
    local vpc_name="$1"
    local subnet_cidr="$2"
    
    # Look for namespaces in this VPC that match the subnet
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        local ns_ip=$(get_namespace_ip "$namespace")
        local ns_cidr="${subnet_cidr%/*}"  # Remove /24 from "10.0.1.0/24"
        
        # Check if namespace IP is in the target subnet
        if [[ "$ns_ip" == "$ns_cidr.2" ]]; then
            echo "$namespace"
            return 0
        fi
    done
    
    return 1
}

# === APPLY RULES TO SPECIFIC NAMESPACE ===
apply_namespace_rules() {
    local namespace="$1"
    local rules_file="$2"
    local rule_index="$3"
    
    echo "  Configuring firewall for namespace: $namespace"
    
    # === CLEAR EXISTING RULES ===
    ip netns exec "$namespace" iptables -F  # Flush all rules
    ip netns exec "$namespace" iptables -X  # Delete user-defined chains
    ip netns exec "$namespace" iptables -Z  # Zero counters
    
    # === SET DEFAULT POLICIES ===
    ip netns exec "$namespace" iptables -P INPUT DROP
    ip netns exec "$namespace" iptables -P FORWARD DROP
    ip netns exec "$namespace" iptables -P OUTPUT ACCEPT
    # Explanation:
    # - INPUT: Default deny incoming traffic (secure by default)
    # - FORWARD: Default deny forwarded traffic
    # - OUTPUT: Allow all outgoing traffic (subnets can initiate connections)
    
    # === ALLOW ESTABLISHED CONNECTIONS ===
    ip netns exec "$namespace" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Explanation:
    # - Allows responses to our outgoing connections
    # - Essential for any meaningful network communication
    # - Without this, you can't receive responses to your requests
    
    # === ALLOW LOOPBACK TRAFFIC ===
    ip netns exec "$namespace" iptables -A INPUT -i lo -j ACCEPT
    # Explanation:
    # - Allows localhost communication within the namespace
    # - Many applications require loopback to function properly
    
    # === APPLY JSON RULES ===
    local ingress_count=$(jq ".rules[$rule_index].ingress | length" "$rules_file")
    
    for ((j=0; j<ingress_count; j++)); do
        local port=$(jq -r ".rules[$rule_index].ingress[$j].port" "$rules_file")
        local protocol=$(jq -r ".rules[$rule_index].ingress[$j].protocol" "$rules_file")
        local action=$(jq -r ".rules[$rule_index].ingress[$j].action" "$rules_file")
        
        # Convert action to iptables target
        local iptables_action="ACCEPT"
        if [[ "$action" == "deny" ]]; then
            iptables_action="DROP"
        fi
        
        # Apply the rule
        if [[ "$protocol" == "icmp" ]]; then
            # ICMP rules (ping)
            ip netns exec "$namespace" iptables -A INPUT -p icmp -j "$iptables_action"
            echo "    Rule: $action ICMP (ping)"
        else
            # TCP/UDP rules
            ip netns exec "$namespace" iptables -A INPUT -p "$protocol" --dport "$port" -j "$iptables_action"
            echo "    Rule: $action $protocol port $port"
        fi
    done
    
    echo "  Firewall configured for $namespace"
}

# === GET NAMESPACE IP ===
get_namespace_ip() {
    local namespace="$1"
    ip netns exec "$namespace" ip addr show | grep -E "veth.*inet" | head -1 | awk '{print $2}' | cut -d'/' -f1
}

# === TEST FIREWALL RULES ===
test_firewall() {
    local vpc_name="$1"
    
    echo "=== Testing Firewall Rules for VPC: $vpc_name ==="
    
    # Get all namespaces in this VPC
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        local ns_ip=$(get_namespace_ip "$namespace")
        echo ""
        echo "Testing namespace: $namespace ($ns_ip)"
        
        # Test common ports
        test_port "$namespace" "$ns_ip" 80 "HTTP"
        test_port "$namespace" "$ns_ip" 22 "SSH"
        test_port "$namespace" "$ns_ip" 443 "HTTPS"
        test_port "$namespace" "$ns_ip" 8080 "HTTP-Alt"
        
        # Test ICMP
        test_icmp "$namespace" "$ns_ip"
    done
}

# === TEST PORT ACCESS ===
test_port() {
    local namespace="$1"
    local ip="$2"
    local port="$3"
    local service="$4"
    
    echo -n "  Port $port ($service): "
    
    # Try to connect to the port
    if ip netns exec "$namespace" timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo "✅ OPEN (allowed)"
    else
        echo "🔒 CLOSED (blocked)"
    fi
}

# === TEST ICMP ACCESS ===
test_icmp() {
    local namespace="$1"
    local ip="$2"
    
    echo -n "  ICMP (ping): "
    
    # Try to ping localhost (testing ICMP rules)
    if ip netns exec "$namespace" ping -c 1 -W 1 127.0.0.1 &>/dev/null; then
        echo "✅ ALLOWED"
    else
        echo "🔒 BLOCKED"
    fi
}

# === CLEANUP FIREWALL RULES ===
cleanup_firewall() {
    local vpc_name="$1"
    
    echo "Cleaning up firewall rules for VPC: $vpc_name"
    
    # Remove all iptables rules from namespaces in this VPC
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        echo "  Resetting firewall for: $namespace"
        ip netns exec "$namespace" iptables -F
        ip netns exec "$namespace" iptables -X
        ip netns exec "$namespace" iptables -Z
        ip netns exec "$namespace" iptables -P INPUT ACCEPT
        ip netns exec "$namespace" iptables -P FORWARD ACCEPT
        ip netns exec "$namespace" iptables -P OUTPUT ACCEPT
    done
}
