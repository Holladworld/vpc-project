#!/bin/bash
# VPC Core Functions - Handles VPC creation, deletion, and listing

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
    
    # Create Linux bridge
    ip link add "$bridge_name" type bridge
    ip link set "$bridge_name" up
    
    # FIXED: Proper gateway IP calculation
    # For CIDR 10.200.0.0/16, gateway should be 10.200.0.1
    local base_ip="${cidr_block%/*}"  # Remove /16 part -> "10.200.0.0"
    local gateway_ip="${base_ip%.*}.1"  # Replace last octet with .1 -> "10.200.0.1"
    
    # Get the subnet prefix from CIDR (the number after /)
    local prefix="${cidr_block#*/}"
    
    # Assign IP to bridge with correct subnet
    ip addr add "$gateway_ip/$prefix" dev "$bridge_name"
    
    echo "VPC $vpc_name created successfully!"
    echo "Bridge: $bridge_name, Gateway: $gateway_ip"
}

delete_vpc() {
    local vpc_name="$1"
    
    if [[ -z "$vpc_name" ]]; then
        echo "Error: VPC name is required"
        return 1
    fi
    
    echo "Deleting VPC: $vpc_name"
    
    local bridge_name="br-$vpc_name"
    
    # Remove the bridge
    ip link delete "$bridge_name" 2>/dev/null 
    
    if [ $? -eq 0 ]; then
        echo "VPC $vpc_name deleted successfully!"
    else
        echo "VPC $vpc_name not found or already deleted"
    fi
}

list_vpcs() {
    echo "=== Available VPCs ==="
    ip link show type bridge | grep -E "^[0-9]+: br-" || echo "No VPCs found"
}