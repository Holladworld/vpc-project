#!/bin/bash
# VPC Core Functions - Handles VPC creation, deletion, and listing
# This is where the main VPC logic lives

# === CREATE VPC ===
create_vpc() {
    # Function to create a new VPC
    # Arguments: vpc_name, cidr_block
    local vpc_name="$1"      # First argument - VPC name
    local cidr_block="$2"    # Second argument - CIDR block
    
    # Explanation of 'local':
    # - Makes variables local to this function
    # - Prevents overwriting global variables
    # - Good practice for function arguments
    
    # Validate inputs
    if [[ -z "$vpc_name" || -z "$cidr_block" ]]; then
        echo "Error: VPC name and CIDR block are required"
        echo "Usage: create-vpc <vpc_name> <cidr_block>"
        return 1  # Return non-zero to indicate error
        # Explanation:
        # - `-z` checks if string is empty
        # - `||` means OR - if either is empty
        # - `return 1` exits function with error code
    fi
    
    echo "Creating VPC: $vpc_name with CIDR: $cidr_block"
    
    # Create Linux bridge (virtual router)
    local bridge_name="br-$vpc_name"
    ip link add "$bridge_name" type bridge
    # Explanation:
    # - `ip link add` creates new network interface
    # - `type bridge` makes it a bridge (virtual switch)
    # - Bridge acts as router for our VPC
    
    # Activate the bridge
    ip link set "$bridge_name" up
    # Explanation:
    # - Network interfaces start in 'down' state
    # - `up` brings the interface online
    
    # Assign IP address to bridge (gateway IP)
    local gateway_ip="${cidr_block%/*}.1"
    # Explanation:
    # - `${cidr_block%/*}` removes everything after / 
    # - "10.0.0.0/16" becomes "10.0.0.0"
    # - We add ".1" to get "10.0.0.1" as gateway
    
    ip addr add "$gateway_ip/24" dev "$bridge_name"
    # Explanation:
    # - `ip addr add` assigns IP address to interface
    # - `/24` is the subnet mask
    # - `dev "$bridge_name"` specifies which device
    
    echo "VPC $vpc_name created successfully!"
    echo "Bridge: $bridge_name, Gateway: $gateway_ip"
}

# === DELETE VPC ===
delete_vpc() {
    local vpc_name="$1"  # VPC name to delete
    
    if [[ -z "$vpc_name" ]]; then
        echo "Error: VPC name is required"
        return 1
    fi
    
    echo "Deleting VPC: $vpc_name"
    
    local bridge_name="br-$vpc_name"
    
    # Remove the bridge (this also removes connected interfaces)
    ip link delete "$bridge_name" 2>/dev/null 
    # Explanation:
    # - `ip link delete` removes network interface
    # - `2>/dev/null` hides error messages if bridge doesn't exist
    # - This is safe to run even if VPC was already deleted
    
    if [ $? -eq 0 ]; then
        echo "VPC $vpc_name deleted successfully!"
        # Explanation:
        # - `$?` contains exit code of last command
        # - 0 means success, non-zero means error
    else
        echo "VPC $vpc_name not found or already deleted"
    fi
}

# === LIST VPCS ===
list_vpcs() {
    echo "=== Available VPCs ==="
    
    # List all bridge interfaces (our VPCs)
    ip link show type bridge
    # Explanation:
    # - `ip link show type bridge` lists only bridge interfaces
    # - Each bridge represents one VPC
    # - Shows interface name, state, and other details
}