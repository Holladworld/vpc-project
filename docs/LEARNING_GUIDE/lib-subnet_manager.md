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
    
    # Explanation of arguments:
    # - vpc_name: Which VPC this subnet belongs to
    # - subnet_type: Determines if subnet can reach internet
    # - subnet_cidr: IP range for this specific subnet
    
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
    
    # Explanation of naming:
    # - namespace: "ns-myvpc-public" - clearly identifies purpose
    # - veth pairs: "veth-myvpc-public" and "veth-ns-myvpc-public"
    # - This naming prevents conflicts between multiple VPCs
    
    # === CHECK IF VPC EXISTS ===
    if ! ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name does not exist. Create it first."
        return 1
        # Explanation:
        # - `ip link show` checks if network interface exists
        # - `&>/dev/null` redirects both stdout and stderr to null
        # - `!` negates the result (true if command fails)
    fi
    
    # === CREATE NETWORK NAMESPACE ===
    echo "Creating network namespace: $namespace"
    ip netns add "$namespace"
    # Explanation:
    # - `ip netns add` creates a new network namespace
    # - Namespace is an isolated network environment
    # - Like a separate virtual computer with its own network stack
    
    # === CREATE VETH PAIR (VIRTUAL ETHERNET CABLE) ===
    echo "Creating veth pair: $veth_host <-> $veth_ns"
    ip link add "$veth_host" type veth peer name "$veth_ns"
    # Explanation:
    # - `veth` = Virtual Ethernet Device
    # - Creates two connected network interfaces
    # - Like a network cable with two ends
    # - Traffic sent into one end comes out the other
    
    # === CONNECT VETH TO NAMESPACE ===
    echo "Moving $veth_ns to namespace $namespace"
    ip link set "$veth_ns" netns "$namespace"
    # Explanation:
    # - `netns` moves network interface to another namespace
    # - After this, $veth_ns only exists inside the namespace
    # - $veth_host remains in the main host namespace
    
    # === CONNECT VETH TO BRIDGE ===
    echo "Connecting $veth_host to bridge $bridge_name"
    ip link set "$veth_host" master "$bridge_name"
    # Explanation:
    # - `master` connects interface to a bridge
    # - Bridge acts like a network switch
    # - Now traffic can flow: namespace <-> veth <-> bridge <-> other subnets
    
    # === BRING INTERFACES UP ===
    echo "Activating network interfaces"
    ip link set "$veth_host" up
    # Explanation:
    # - Network interfaces start in 'down' state
    # - `up` brings the interface online
    # - Host side of veth is now active
    
    # Bring up interface inside namespace
    ip netns exec "$namespace" ip link set "$veth_ns" up
    # Explanation:
    # - `ip netns exec` runs command inside a network namespace
    # - We're bringing up the namespace-side veth interface
    # - Now both ends of the veth pair are active
    
    # Bring up loopback interface in namespace (always good practice)
    ip netns exec "$namespace" ip link set lo up
    # Explanation:
    # - `lo` is loopback interface (like 127.0.0.1 in normal system)
    # - Some applications expect loopback to be available
    # - This prevents weird issues later
    
    # === ASSIGN IP ADDRESS TO SUBNET ===
    echo "Assigning IP address $subnet_cidr to subnet"
    ip netns exec "$namespace" ip addr add "$subnet_cidr" dev "$veth_ns"
    # Explanation:
    # - Assigns the CIDR to the veth interface inside namespace
    # - Example: "10.0.1.0/24" gives addresses 10.0.1.1 - 10.0.1.254
    # - The interface automatically gets the first IP (.1)
    
    # === CONFIGURE ROUTING ===
    # Calculate gateway IP (bridge IP for this subnet)
    local gateway_ip="${subnet_cidr%.*}.1"
    # Explanation:
    # - `${subnet_cidr%.*}` removes everything after last dot
    # - "10.0.1.0/24" becomes "10.0.1"
    # - We add ".1" to get gateway IP "10.0.1.1"
    
    echo "Setting default gateway to $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip"
    # Explanation:
    # - `ip route add default` sets the default route
    # - `via "$gateway_ip"` means "send unknown traffic to this gateway"
    # - This makes the bridge the router for this subnet
    
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
    # Explanation:
    # - `sysctl -w` changes kernel parameters at runtime
    # - `net.ipv4.ip_forward=1` enables packet forwarding
    # - Needed for NAT to work properly
    # - `> /dev/null` hides the success message
    
    # Note: We'll add NAT rules in the routing module
    # This function prepares the namespace for public access
}

# === LIST SUBNETS ===
list_subnets() {
    echo "=== Available Subnets ==="
    
    # List all network namespaces (each represents a subnet)
    ip netns list
    # Explanation:
    # - `ip netns list` shows all network namespaces
    # - Our naming convention makes it clear which VPC they belong to
    # - Example: "ns-myvpc-public", "ns-myvpc-private"
    
    # Show which namespaces are connected to which bridges
    echo ""
    echo "=== Subnet Connections ==="
    for namespace in $(ip netns list | awk '{print $1}'); do
        echo "Namespace: $namespace"
        ip netns exec "$namespace" ip addr show | grep -E "inet |^[0-9]+:"
        echo "---"
    done
    # Explanation:
    # - `ip netns list | awk '{print $1}'` gets just namespace names
    # - Loop through each namespace and show its network configuration
    # - Shows IP addresses and interface names for each subnet
}
