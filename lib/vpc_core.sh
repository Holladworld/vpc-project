#!/bin/bash
# VPC Core Functions - Handles VPC creation, deletion, and listing

# === CREATE VPC ===
create_vpc() {
    local vpc_name="$1"
    local cidr_block="$2"
    
    if [[ -z "$vpc_name" || -z "$cidr_block" ]]; then
        echo "Error: VPC name and CIDR block are required"
        echo "Usage: create-vpc <vpc_name> <cidr_block>"
        return 1
    fi
    
    echo "Creating VPC: $vpc_name with CIDR: $cidr_block"
    
    local bridge_name="br-$vpc_name"
    
    # Check if VPC already exists
    if ip link show "$bridge_name" &>/dev/null; then
        echo "Error: VPC $vpc_name already exists"
        return 1
    fi
    
    # Create bridge (VPC router)
    ip link add "$bridge_name" type bridge
    ip link set "$bridge_name" up
    
    # FIXED: Proper IP address calculation
    # For CIDR 10.100.0.0/16, gateway should be 10.100.0.1
    local network_part="${cidr_block%/*}"  # "10.100.0.0"
    local cidr_mask="${cidr_block#*/}"     # "16"
    
    # Convert to proper gateway IP
    local gateway_ip
    if [[ "$cidr_mask" -eq 16 ]]; then
        gateway_ip="${network_part%.*}.1"  # "10.100.0.0" -> "10.100.0.1"
    elif [[ "$cidr_mask" -eq 24 ]]; then
        gateway_ip="${network_part%.*}.1"  # "10.100.1.0" -> "10.100.1.1"
    else
        gateway_ip="${network_part%.*}.1"  # Default case
    fi
    
    # Assign bridge IP with proper subnet mask
    echo "Assigning gateway IP: $gateway_ip/$cidr_mask"
    ip addr add "$gateway_ip/$cidr_mask" dev "$bridge_name"
    
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Create config directory and save VPC configuration properly
    local config_dir="$PROJECT_ROOT/.vpc_configs"
    mkdir -p "$config_dir"
    
    cat > "${config_dir}/${vpc_name}.conf" << CONF
VPC_NAME="$vpc_name"
CIDR_BLOCK="$cidr_block"
BRIDGE_NAME="$bridge_name"
BRIDGE_IP="$gateway_ip"
CREATED_AT="$(date)"
STATUS="ACTIVE"
CONF

    echo "VPC $vpc_name created successfully!"
    echo "Bridge: $bridge_name, Gateway: $gateway_ip/$cidr_mask"
}

# === DELETE VPC ===
delete_vpc() {
    local vpc_name="$1"
    
    if [[ -z "$vpc_name" ]]; then
        echo "Error: VPC name is required"
        return 1
    fi
    
    local config_file="$PROJECT_ROOT/.vpc_configs/$vpc_name.conf"
    
    if [[ ! -f "$config_file" ]]; then
        echo "Error: VPC $vpc_name not found"
        return 1
    fi
    
    echo "Deleting VPC: $vpc_name"
    
    # Load configuration
    source "$config_file"
    
    # Delete all namespaces for this VPC
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        echo "Deleting namespace: $namespace"
        ip netns delete "$namespace"
    done
    
    # Delete bridge
    ip link delete "$BRIDGE_NAME" 2>/dev/null && echo "Deleted bridge: $BRIDGE_NAME"
    
    # Remove configuration
    rm -f "$config_file"
    
    echo "VPC $vpc_name deleted successfully!"
}

# === LIST VPCS ===
list_vpcs() {
    echo "=== Available VPCs ==="
    
    local config_dir="$PROJECT_ROOT/.vpc_configs"
    
    if [[ ! -d "$config_dir" ]] || [[ -z "$(ls -A "$config_dir")" ]]; then
        echo "No VPCs found"
        return 0
    fi
    
    echo "VPC Name         CIDR Block         Bridge Name      Status"
    echo "--------         ----------         -----------      ------"
    
    for config_file in "$config_dir"/*.conf; do
        source "$config_file"
        local bridge_status="DOWN"
        ip link show "$BRIDGE_NAME" &>/dev/null && bridge_status="UP"
        printf "%-15s %-18s %-15s %-10s\n" "$VPC_NAME" "$CIDR_BLOCK" "$BRIDGE_NAME" "$bridge_status"
    done
}

# Helper function to get VPC CIDR
get_vpc_cidr() {
    local vpc_name="$1"
    local config_file="$PROJECT_ROOT/.vpc_configs/$vpc_name.conf"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        echo "$CIDR_BLOCK"
    fi
}