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
    
    # Use unique veth names to avoid conflicts
    local veth_host="veth-$vpc_name-$subnet_type"
    local veth_ns="veth-ns-$vpc_name-$subnet_type"
    
    # Check if VPC exists
    if ! ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name does not exist. Create it first."
        return 1
    fi
    
    # Check if namespace already exists
    if ip netns list | grep -q "$namespace"; then
        echo "Error: Subnet $namespace already exists"
        return 1
    fi
    
    # Create network namespace
    echo "Creating network namespace: $namespace"
    ip netns add "$namespace"
    
    # Create veth pair with unique names
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
    
    # FIXED: Proper IP address calculation for subnets
    local network_part="${subnet_cidr%/*}"  # "10.100.1.0"
    local cidr_mask="${subnet_cidr#*/}"     # "24"
    local namespace_ip="${network_part%.*}.2"  # "10.100.1.2"
    local gateway_ip="${network_part%.*}.1"    # "10.100.1.1"
    
    # Assign IP to the veth interface in namespace
    echo "Assigning IP address $namespace_ip/$cidr_mask to subnet"
    ip netns exec "$namespace" ip addr add "$namespace_ip/$cidr_mask" dev "$veth_ns"
    
    # Set default gateway in namespace
    echo "Setting default gateway to $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip"
    
    # For public subnets
    if [[ "$subnet_type" == "public" ]]; then
        echo "Setting up public subnet capabilities"
        ip netns exec "$namespace" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    fi
    
    echo "✅ Subnet $subnet_type ($subnet_cidr) successfully added to VPC $vpc_name"
    echo "   Namespace: $namespace"
    echo "   IP: $namespace_ip/$cidr_mask, Gateway: $gateway_ip"
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

# Helper function to get namespace IP
get_namespace_ip() {
    local namespace="$1"
    ip netns exec "$namespace" ip addr show 2>/dev/null | grep -E "veth.*inet" | head -1 | awk '{print $2}' | cut -d'/' -f1
}