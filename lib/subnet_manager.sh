#!/bin/bash
# Subnet Management Functions

add_subnet() {
    local vpc_name="$1"
    local subnet_type="$2" 
    local subnet_cidr="$3"
    
    if [[ -z "$vpc_name" || -z "$subnet_type" || -z "$subnet_cidr" ]]; then
        echo "Error: VPC name, subnet type, and CIDR are required"
        echo "Usage: add-subnet <vpc_name> <public|private> <subnet_cidr>"
        return 1
    fi
    
    if [[ "$subnet_type" != "public" && "$subnet_type" != "private" ]]; then
        echo "Error: Subnet type must be 'public' or 'private'"
        return 1
    fi
    
    echo "Adding $subnet_type subnet to VPC $vpc_name: $subnet_cidr"
    
    local bridge_name="br-$vpc_name"
    local namespace="ns-$vpc_name-$subnet_type"
    
    # SHORTEN interface names to under 15 characters
    local veth_host="veth-$subnet_type"
    local veth_ns="veth-ns-$subnet_type"
    
    # Check if VPC exists
    if ! ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name does not exist. Create it first."
        return 1
    fi
    
    # Create network namespace
    echo "Creating network namespace: $namespace"
    ip netns add "$namespace"
    
    # Create veth pair with shorter names
    echo "Creating veth pair: $veth_host <-> $veth_ns"
    ip link add "$veth_host" type veth peer name "$veth_ns"
    
    # Move one end to namespace
    echo "Moving $veth_ns to namespace $namespace"
    ip link set "$veth_ns" netns "$namespace"
    
    # Connect to bridge
    echo "Connecting $veth_host to bridge $bridge_name"
    ip link set "$veth_host" master "$bridge_name"
    
    # Bring interfaces up
    echo "Activating network interfaces"
    ip link set "$veth_host" up
    ip netns exec "$namespace" ip link set "$veth_ns" up
    ip netns exec "$namespace" ip link set lo up
    
    # FIXED: Proper IP address calculation
    # For subnet CIDR 10.200.1.0/24, namespace gets 10.200.1.2
    local base_ip="${subnet_cidr%/*}"  # Remove /24 part -> "10.200.1.0"
    local namespace_ip="${base_ip%.*}.2"  # Replace last octet with .2 -> "10.200.1.2"
    
    echo "Assigning IP address $namespace_ip/24 to subnet"
    ip netns exec "$namespace" ip addr add "$namespace_ip/24" dev "$veth_ns"
    
    # FIXED: Proper gateway calculation  
    # Gateway is .1 in the same subnet -> "10.200.1.1"
    local gateway_ip="${base_ip%.*}.1"
    
    echo "Setting default gateway to $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip"
    
    # For public subnets
    if [[ "$subnet_type" == "public" ]]; then
        echo "Setting up public subnet capabilities"
        ip netns exec "$namespace" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    fi
    
    echo "✅ Subnet $subnet_type ($subnet_cidr) successfully added to VPC $vpc_name"
    echo "   Namespace: $namespace"
    echo "   IP: $namespace_ip, Gateway: $gateway_ip"
}

list_subnets() {
    echo "=== Available Subnets ==="
    ip netns list
    
    echo ""
    echo "=== Subnet Details ==="
    for ns in $(ip netns list | awk '{print $1}'); do
        echo "Namespace: $ns"
        echo "IP Addresses:"
        ip netns exec "$ns" ip addr show | grep "inet " || echo "  No IP assigned"
        echo "Routing Table:"
        ip netns exec "$ns" ip route show || echo "  No routes"
        echo "---"
    done
}