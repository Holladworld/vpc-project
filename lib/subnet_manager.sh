#!/bin/bash
# Subnet Management Functions
# Handles creating public/private subnets as network namespaces
# Connects subnets to VPC bridges using veth pairs

# === ADD SUBNET TO VPC ===
add_subnet() {
    # Function to add a subnet to an existing VPC
    # Arguments: vpc_name, subnet_type, subnet_cidr
    local vpc_name="$1"       # VPC to add subnet to
    local subnet_type="$2"    # "public" or "private" 
    local subnet_cidr="$3"    # CIDR for the subnet (e.g., 10.0.1.0/24)
        
    # === INPUT VALIDATION ===
    if [[ -z "$vpc_name" || -z "$subnet_type" || -z "$subnet_cidr" ]]; then
        echo "Error: VPC name, subnet type, and CIDR are required"
        echo "Usage: add-subnet <vpc_name> <public|private> <subnet_cidr>"
        return 1
    fi
    
    # Validate subnet type
    if [[ "$subnet_type" != "public" && "$subnet_type" != "private" ]]; then
        echo "Error: Subnet type must be 'public' or 'private'"
        return 1
    fi
    
    echo "Adding $subnet_type subnet to VPC $vpc_name: $subnet_cidr"
    
    # === SETUP VARIABLES ===
    local bridge_name="br-$vpc_name"          # VPC bridge name
    local namespace="ns-$vpc_name-$subnet_type" # Network namespace name
    local veth_host="veth-$vpc_name-$subnet_type" # veth end on host side
    local veth_ns="veth-ns-$vpc_name-$subnet_type" # veth end in namespace
    
        
    # === CHECK IF VPC EXISTS ===
    if ! ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name does not exist. Create it first."
        return 1
    fi
    
    # === CREATE NETWORK NAMESPACE ===
    echo "Creating network namespace: $namespace"
    ip netns add "$namespace"
    
    # === CREATE VETH PAIR (VIRTUAL ETHERNET CABLE) ===
    echo "Creating veth pair: $veth_host <-> $veth_ns"
    ip link add "$veth_host" type veth peer name "$veth_ns"
    
    # === CONNECT VETH TO NAMESPACE ===
    echo "Moving $veth_ns to namespace $namespace"
    ip link set "$veth_ns" netns "$namespace"
    
    # === CONNECT VETH TO BRIDGE ===
    echo "Connecting $veth_host to bridge $bridge_name"
    ip link set "$veth_host" master "$bridge_name"
    
    # === BRING INTERFACES UP ===
    echo "Activating network interfaces"
    ip link set "$veth_host" up
    
    # Bring up interface inside namespace
    ip netns exec "$namespace" ip link set "$veth_ns" up
    
    # Bring up loopback interface in namespace (always good practice)
    ip netns exec "$namespace" ip link set lo up
    
    # === ASSIGN IP ADDRESS TO SUBNET ===
    echo "Assigning IP address $subnet_cidr to subnet"
    ip netns exec "$namespace" ip addr add "$subnet_cidr" dev "$veth_ns"
    
    # === CONFIGURE ROUTING ===
    # Calculate gateway IP (bridge IP for this subnet)
    local gateway_ip="${subnet_cidr%.*}.1"
    
    echo "Setting default gateway to $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip"
    
    # === SETUP FOR PUBLIC SUBNETS ===
    if [[ "$subnet_type" == "public" ]]; then
        echo "Setting up public subnet capabilities"
        setup_public_subnet "$vpc_name" "$namespace" "$subnet_cidr"
    fi
    
    echo "✅ Subnet $subnet_type ($subnet_cidr) successfully added to VPC $vpc_name"
    echo "   Namespace: $namespace"
    echo "   Gateway: $gateway_ip"
}

# === SETUP PUBLIC SUBNET ===
setup_public_subnet() {
    local vpc_name="$1"
    local namespace="$2" 
    local subnet_cidr="$3"
    
    echo "Configuring public subnet for internet access"
    
    # Enable IP forwarding in the namespace
    ip netns exec "$namespace" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
}

# === LIST SUBNETS ===
list_subnets() {
    echo "=== Available Subnets ==="
    
    # List all network namespaces (each represents a subnet)
    ip netns list
    
    # Show which namespaces are connected to which bridges
    echo ""
    echo "=== Subnet Connections ==="
    for namespace in $(ip netns list | awk '{print $1}'); do
        echo "Namespace: $namespace"
        ip netns exec "$namespace" ip addr show | grep -E "inet |^[0-9]+:"
        echo "---"
    done
   
}