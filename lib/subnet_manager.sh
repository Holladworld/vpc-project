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
    
    # Use shorter veth names to stay under 15-character limit
    local vpc_short="${vpc_name:0:6}"  # Use first 6 chars of VPC name
    local type_short="${subnet_type:0:3}"  # Use first 3 chars of type
    
    local veth_host="v${vpc_short}${type_short}"    # Example: vmainpub
    local veth_ns="vn${vpc_short}${type_short}"     # Example: vnmainpub
    
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
    
    # Create veth pair with shorter names
    echo "Creating veth pair: $veth_host <-> $veth_ns"
    if ! ip link add "$veth_host" type veth peer name "$veth_ns"; then
        echo "Error: Failed to create veth pair"
        return 1
    fi
    
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
    
    # Proper IP address calculation for subnets
    local network_part="${subnet_cidr%/*}"  # "10.0.1.0"
    local cidr_mask="${subnet_cidr#*/}"     # "24"
    local namespace_ip="${network_part%.*}.2"  # "10.0.1.2"
    local gateway_ip="${network_part%.*}.1"    # "10.0.1.1"
    
    # FIXED: Add gateway IP to bridge for this subnet (only if not exists)
    echo "Adding gateway IP $gateway_ip/$cidr_mask to bridge"
    if ! ip addr show "$bridge_name" | grep -q "$gateway_ip"; then
        ip addr add "$gateway_ip/$cidr_mask" dev "$bridge_name"
    else
        echo "Gateway IP already exists on bridge"
    fi
    
    # Assign IP to the veth interface in namespace
    echo "Assigning IP address $namespace_ip/$cidr_mask to subnet"
    ip netns exec "$namespace" ip addr add "$namespace_ip/$cidr_mask" dev "$veth_ns"
    
    # FIXED: Set default gateway in namespace (use the actual bridge interface)
    echo "Setting default gateway to $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip" dev "$veth_ns"
    
    # For public subnets
    if [[ "$subnet_type" == "public" ]]; then
        echo "Setting up public subnet capabilities"
        ip netns exec "$namespace" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    fi
    
    echo "✅ Subnet $subnet_type ($subnet_cidr) successfully added to VPC $vpc_name"
    echo "   Namespace: $namespace"
    echo "   IP: $namespace_ip/$cidr_mask, Gateway: $gateway_ip"
    echo "   Interfaces: $veth_host (host) <-> $veth_ns (namespace)"
}

list_subnets() {
    echo "=== Available Subnets ==="
    local namespaces=$(ip netns list)
    
    if [[ -z "$namespaces" ]]; then
        echo "No subnets found"
        return 0
    fi
    
    # FIXED: Clean namespace listing without IDs
    ip netns list | sed 's/ (id:[0-9]*)//g'
    
    echo ""
    echo "=== Subnet Details ==="
    
    # Check if we have permission to access namespaces
    if [[ $EUID -ne 0 ]]; then
        echo "Note: Run with 'sudo' to see detailed IP and routing information"
        echo "Current command only shows namespace names"
        return 0
    fi
    
    for ns in $(ip netns list | awk '{print $1}'); do
        local clean_ns=$(echo "$ns" | sed 's/ (id:[0-9]*)//g')
        echo "Namespace: $clean_ns"
        echo "IP Addresses:"
        # FIXED: Better IP detection
        local ip_info=$(ip netns exec "$ns" ip addr show 2>/dev/null | grep -E "inet.*vn" || ip netns exec "$ns" ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 || echo "  No IP assigned")
        echo "$ip_info"
        
        echo "Routing Table:"
        local route_info=$(ip netns exec "$ns" ip route show 2>/dev/null || echo "  No routes")
        echo "$route_info"
        echo "---"
    done
}

# Helper function to get namespace IP
get_namespace_ip() {
    local namespace="$1"
    
    # Check if we're root before trying to access namespace
    if [[ $EUID -ne 0 ]]; then
        return 1
    fi
    
    # FIXED: Better IP detection that handles namespace IDs
    local clean_namespace=$(echo "$namespace" | sed 's/ (id:[0-9]*)//g')
    ip netns exec "$clean_namespace" ip addr show 2>/dev/null | grep -E "inet.*vn" | head -1 | awk '{print $2}' | cut -d'/' -f1
}

# Helper function to get clean namespace name
get_clean_namespace() {
    local namespace="$1"
    echo "$namespace" | sed 's/ (id:[0-9]*)//g'
}

# Get all namespaces for a VPC
get_vpc_namespaces() {
    local vpc_name="$1"
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        get_clean_namespace "$namespace"
    done
}

# Verify subnet connectivity
verify_subnet_connectivity() {
    local vpc_name="$1"
    
    echo "=== Verifying Subnet Connectivity for VPC: $vpc_name ==="
    
    local namespaces=($(get_vpc_namespaces "$vpc_name"))
    
    for ((i=0; i<${#namespaces[@]}; i++)); do
        for ((j=i+1; j<${#namespaces[@]}; j++)); do
            local ns1="${namespaces[i]}"
            local ns2="${namespaces[j]}"
            local ip2=$(get_namespace_ip "$ns2")
            
            if [[ -n "$ip2" ]]; then
                echo -n "Testing $ns1 -> $ns2 ($ip2): "
                if ip netns exec "$ns1" ping -c 1 -W 1 "$ip2" &>/dev/null; then
                    echo "✅ CONNECTED"
                else
                    echo "❌ FAILED"
                fi
            fi
        done
    done
}
