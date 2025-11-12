#!/bin/bash
# VPC Peering Functions

# === CREATE VPC PEERING ===
create_peering() {
    local vpc1="$1"
    local vpc2="$2"
    
    if [[ -z "$vpc1" || -z "$vpc2" ]]; then
        echo "Error: Both VPC names are required"
        echo "Usage: create-peering <vpc1> <vpc2>"
        return 1
    fi
    
    # Check if both VPCs exist
    if ! ip link show "br-$vpc1" &>/dev/null; then
        echo "Error: VPC $vpc1 does not exist"
        return 1
    fi
    
    if ! ip link show "br-$vpc2" &>/dev/null; then
        echo "Error: VPC $vpc2 does not exist"
        return 1
    fi
    
    # Check if peering already exists
    if check_peering_exists "$vpc1" "$vpc2"; then
        echo "Peering between $vpc1 and $vpc2 already exists"
        return 0
    fi
    
    echo "Creating VPC peering between $vpc1 and $vpc2"
    
    # Use shorter names to avoid "name not valid ifname" error
    local veth1="vpeer-${vpc1:0:4}-${vpc2:0:4}"
    local veth2="vpeer-${vpc2:0:4}-${vpc1:0:4}"
    
    echo "Creating peering veth pair: $veth1 <-> $veth2"
    if ! ip link add "$veth1" type veth peer name "$veth2"; then
        echo "Error: Failed to create peering veth pair"
        return 1
    fi
    
    # Connect veth ends to respective bridges
    echo "Connecting $veth1 to br-$vpc1"
    if ! ip link set "$veth1" master "br-$vpc1"; then
        echo "Error: Failed to connect $veth1 to br-$vpc1"
        ip link delete "$veth1" 2>/dev/null
        return 1
    fi
    
    echo "Connecting $veth2 to br-$vpc2"  
    if ! ip link set "$veth2" master "br-$vpc2"; then
        echo "Error: Failed to connect $veth2 to br-$vpc2"
        ip link delete "$veth1" 2>/dev/null
        return 1
    fi
    
    # Activate the peering interfaces
    ip link set "$veth1" up
    ip link set "$veth2" up
    
    # Get VPC CIDR blocks
    local vpc1_cidr=$(get_vpc_cidr "$vpc1")
    local vpc2_cidr=$(get_vpc_cidr "$vpc2")
    
    if [[ -z "$vpc1_cidr" || -z "$vpc2_cidr" ]]; then
        echo "Error: Could not determine VPC CIDR blocks"
        ip link delete "$veth1" 2>/dev/null
        return 1
    fi
    
    echo "VPC $vpc1 CIDR: $vpc1_cidr"
    echo "VPC $vpc2 CIDR: $vpc2_cidr"
    
    # FIXED: Calculate proper gateway IPs using the bridge IPs
    local vpc1_gateway=$(get_bridge_ip "$vpc1")
    local vpc2_gateway=$(get_bridge_ip "$vpc2")
    
    echo "VPC $vpc1 Gateway: $vpc1_gateway"
    echo "VPC $vpc2 Gateway: $vpc2_gateway"
    
    # Add routes to each VPC
    if ! add_peering_route "$vpc1" "$vpc2_cidr" "$vpc2_gateway"; then
        echo "Warning: Failed to add some routes to VPC $vpc1"
    fi
    
    if ! add_peering_route "$vpc2" "$vpc1_cidr" "$vpc1_gateway"; then
        echo "Warning: Failed to add some routes to VPC $vpc2"
    fi
    
    # Save peering configuration
    save_peering_config "$vpc1" "$vpc2" "$veth1" "$veth2"
    
    echo "✅ VPC peering established: $vpc1 ($vpc1_cidr) ↔ $vpc2 ($vpc2_cidr)"
    echo "   Subnets can now communicate across VPCs"
}

# === GET BRIDGE IP ===
get_bridge_ip() {
    local vpc_name="$1"
    local bridge_name="br-$vpc_name"
    
    # Get the first IP address from the bridge
    ip addr show "$bridge_name" 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1
}

# === CHECK IF PEERING EXISTS ===
check_peering_exists() {
    local vpc1="$1"
    local vpc2="$2"
    
    # Check if peering interfaces exist using shorter names
    local veth1="vpeer-${vpc1:0:4}-${vpc2:0:4}"
    local veth2="vpeer-${vpc2:0:4}-${vpc1:0:4}"
    
    if ip link show "$veth1" &>/dev/null || ip link show "$veth2" &>/dev/null; then
        return 0  # Peering exists
    else
        return 1  # Peering doesn't exist
    fi
}

# === GET VPC CIDR BLOCK ===
get_vpc_cidr() {
    local vpc_name="$1"
    local config_file="$PROJECT_ROOT/.vpc_configs/$vpc_name.conf"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        echo "$CIDR_BLOCK"
    else
        return 1
    fi
}

# === ADD PEERING ROUTE ===
add_peering_route() {
    local vpc_name="$1"
    local target_cidr="$2"
    local gateway_ip="$3"
    
    echo "Adding route in $vpc_name: $target_cidr via $gateway_ip"
    
    local route_added=0
    
    # Get all subnets in this VPC
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        echo "  Adding route in namespace $namespace"
        if ip netns exec "$namespace" ip route add "$target_cidr" via "$gateway_ip" 2>/dev/null; then
            ((route_added++))
        else
            echo "    Warning: Failed to add route in $namespace"
        fi
    done
    
    if [[ $route_added -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# === SAVE PEERING CONFIGURATION ===
save_peering_config() {
    local vpc1="$1"
    local vpc2="$2"
    local veth1="$3"
    local veth2="$4"
    
    local peering_dir="$PROJECT_ROOT/.vpc_peerings"
    mkdir -p "$peering_dir"
    
    local config_file="$peering_dir/peer-$vpc1-$vpc2.conf"
    
    cat > "$config_file" << CONFIG
VPC1="$vpc1"
VPC2="$vpc2"
VETH1="$veth1"
VETH2="$veth2"
CREATED_AT="$(date)"
CONFIG
    
    echo "Saved peering configuration: $config_file"
}

# === DELETE VPC PEERING ===
delete_peering() {
    local vpc1="$1"
    local vpc2="$2"
    
    if [[ -z "$vpc1" || -z "$vpc2" ]]; then
        echo "Error: Both VPC names are required"
        echo "Usage: delete-peering <vpc1> <vpc2>"
        return 1
    fi
    
    echo "Deleting VPC peering between $vpc1 and $vpc2"
    
    # === REMOVE PEERING INTERFACES ===
    local veth1="vpeer-${vpc1:0:4}-${vpc2:0:4}"
    local veth2="vpeer-${vpc2:0:4}-${vpc1:0:4}"
    
    if ip link show "$veth1" &>/dev/null; then
        ip link delete "$veth1"
        echo "Removed peering interface: $veth1"
    fi
    
    if ip link show "$veth2" &>/dev/null; then
        ip link delete "$veth2"  
        echo "Removed peering interface: $veth2"
    fi
    
    # === REMOVE PEERING ROUTES ===
    remove_peering_routes "$vpc1" "$vpc2"
    remove_peering_routes "$vpc2" "$vpc1"
    
    # === REMOVE CONFIGURATION ===
    local config_file="$PROJECT_ROOT/.vpc_peerings/peer-$vpc1-$vpc2.conf"
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        echo "Removed peering configuration"
    fi
    
    echo "✅ VPC peering between $vpc1 and $vpc2 deleted"
    echo "   VPCs are now isolated from each other"
}

# === REMOVE PEERING ROUTES ===
remove_peering_routes() {
    local vpc_name="$1"
    local peer_vpc="$2"
    
    local peer_cidr=$(get_vpc_cidr "$peer_vpc")
    
    if [[ -n "$peer_cidr" ]]; then
        for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
            # Remove the specific route for peer VPC
            if ip netns exec "$namespace" ip route del "$peer_cidr" 2>/dev/null; then
                echo "Removed route for $peer_cidr from $namespace"
            fi
        done
    fi
}

# === LIST PEERING CONNECTIONS ===
list_peerings() {
    local peering_dir="$PROJECT_ROOT/.vpc_peerings"
    
    echo "=== VPC Peering Connections ==="
    
    if [[ ! -d "$peering_dir" ]] || [[ -z "$(ls -A "$peering_dir")" ]]; then
        echo "No VPC peerings found"
        return 0
    fi
    
    echo "VPC1      VPC2      Status    Created"
    echo "----      ----      ------    -------"
    
    for config_file in "$peering_dir"/*.conf; do
        if [[ -f "$config_file" ]]; then
            source "$config_file"
            local status="ACTIVE"
            
            # Check if peering interfaces still exist
            if ! ip link show "$VETH1" &>/dev/null || ! ip link show "$VETH2" &>/dev/null; then
                status="BROKEN"
            fi
            
            printf "%-9s %-9s %-9s %-10s\n" "$VPC1" "$VPC2" "$status" "$(echo $CREATED_AT | cut -d' ' -f1)"
        fi
    done
}

# === TEST VPC ISOLATION ===
test_isolation() {
    local vpc1="$1"
    local vpc2="$2"
    
    if [[ -z "$vpc1" || -z "$vpc2" ]]; then
        echo "Error: Both VPC names are required"
        echo "Usage: test-isolation <vpc1> <vpc2>"
        return 1
    fi
    
    echo "=== Testing VPC Isolation: $vpc1 vs $vpc2 ==="
    
    # FIXED: Get ANY subnet from each VPC (not just public)
    local vpc1_subnet=$(ip netns list | grep "ns-$vpc1-" | head -1)
    local vpc2_subnet=$(ip netns list | grep "ns-$vpc2-" | head -1)
    
    if [[ -z "$vpc1_subnet" || -z "$vpc2_subnet" ]]; then
        echo "Error: Both VPCs need at least one subnet (any type)"
        echo "Available subnets for $vpc1: $(ip netns list | grep "ns-$vpc1-" || echo "none")"
        echo "Available subnets for $vpc2: $(ip netns list | grep "ns-$vpc2-" || echo "none")"
        return 1
    fi
    
    # Get IP addresses from each subnet
    local vpc1_ip=$(get_namespace_ip "$vpc1_subnet")
    local vpc2_ip=$(get_namespace_ip "$vpc2_subnet")
    
    if [[ -z "$vpc1_ip" || -z "$vpc2_ip" ]]; then
        echo "Error: Could not get IP addresses from subnets"
        echo "VPC1 $vpc1_subnet IP: $vpc1_ip"
        echo "VPC2 $vpc2_subnet IP: $vpc2_ip"
        return 1
    fi
    
    echo "Testing connectivity:"
    echo "  From: $vpc1_subnet ($vpc1_ip)"
    echo "  To:   $vpc2_subnet ($vpc2_ip)"
    
    # Test connectivity before peering (should fail)
    echo -n "Before peering: "
    if ip netns exec "$vpc1_subnet" ping -c 1 -W 1 "$vpc2_ip" &>/dev/null; then
        echo "❌ CONNECTED (isolation broken!)"
    else
        echo "✅ ISOLATED (correct behavior)"
    fi
    
    # Check if peering exists
    if check_peering_exists "$vpc1" "$vpc2"; then
        echo -n "After peering: "
        if ip netns exec "$vpc1_subnet" ping -c 1 -W 1 "$vpc2_ip" &>/dev/null; then
            echo "✅ CONNECTED (peering working)"
        else
            echo "❌ DISCONNECTED (peering broken)"
        fi
    else
        echo "Peering not established - use: create-peering $vpc1 $vpc2"
    fi
}

# === GET NAMESPACE IP ===
get_namespace_ip() {
    local namespace="$1"
    
    # FIXED: Better IP detection that works with our interface names
    ip netns exec "$namespace" ip addr show 2>/dev/null | grep -E "inet.*vn" | head -1 | awk '{print $2}' | cut -d'/' -f1
}

# === DEPLOY TEST APPLICATION ===
deploy_app() {
    local vpc_name="$1"
    local subnet_type="$2"
    local app_type="$3"
    
    if [[ -z "$vpc_name" || -z "$subnet_type" || -z "$app_type" ]]; then
        echo "Error: VPC name, subnet type, and app type are required"
        echo "Usage: deploy-app <vpc_name> <public|private> <nginx|python>"
        return 1
    fi
    
    local namespace="ns-$vpc_name-$subnet_type"
    
    if ! ip netns list | grep -q "$namespace"; then
        echo "Error: Subnet $namespace does not exist"
        return 1
    fi
    
    echo "Deploying $app_type application in $namespace"
    
    case "$app_type" in
        nginx)
            deploy_nginx "$namespace"
            ;;
        python)
            deploy_python_server "$namespace"
            ;;
        *)
            echo "Error: Unknown app type. Use 'nginx' or 'python'"
            return 1
            ;;
    esac
}

# === DEPLOY NGINX ===
deploy_nginx() {
    local namespace="$1"
    local namespace_ip=$(get_namespace_ip "$namespace")
    
    if [[ -z "$namespace_ip" ]]; then
        echo "Error: Could not get IP address for namespace $namespace"
        return 1
    fi
    
    echo "Deploying nginx in $namespace ($namespace_ip)"
    
    # Install nginx in the namespace (simplified - skip actual install for testing)
    ip netns exec "$namespace" bash -c "
        # Create a simple Python server instead since nginx installation requires internet
        mkdir -p /tmp/web
        cat > /tmp/web/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <title>VPC Test Server</title>
</head>
<body>
    <h1>Hello from VPC Test Server</h1>
    <p>Namespace: $namespace</p>
    <p>IP Address: $namespace_ip</p>
    <p>Time: \$(date)</p>
</body>
</html>
HTML
        
        # Start Python HTTP server on port 80
        cd /tmp/web
        nohup python3 -m http.server 80 > /tmp/server.log 2>&1 &
        echo \"Server started on port 80\"
    " &
    
    echo "✅ Web server deployed in $namespace"
    echo "   Access: curl http://$namespace_ip"
}

# === DEPLOY PYTHON SERVER ===
deploy_python_server() {
    local namespace="$1"
    local namespace_ip=$(get_namespace_ip "$namespace")
    local port="8080"
    
    if [[ -z "$namespace_ip" ]]; then
        echo "Error: Could not get IP address for namespace $namespace"
        return 1
    fi
    
    echo "Deploying Python HTTP server in $namespace ($namespace_ip:$port)"
    
    # Start Python HTTP server in background
    ip netns exec "$namespace" bash -c "
        # Create test content
        mkdir -p /tmp/web
        cat > /tmp/web/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <title>Python Test Server</title>
</head>
<body>
    <h1>Python HTTP Server</h1>
    <p>Namespace: $namespace</p>
    <p>IP: $namespace_ip</p>
    <p>Port: $port</p>
    <p>This is a test Python server</p>
</body>
</html>
HTML
        
        # Start server
        cd /tmp/web
        nohup python3 -m http.server $port > /tmp/python-server.log 2>&1 &
        echo \"Python server started on port $port\"
    " &
    
    echo "✅ Python server deployed in $namespace"
    echo "   Access: curl http://$namespace_ip:$port"
}

# === RUN ALL TESTS ===
run_tests() {
    echo "Running VPC peering tests..."
    # This function can be called from the main CLI
    echo "Use: sudo ./bin/vpcctl test-isolation <vpc1> <vpc2>"
}

# === CLEANUP ALL ===
cleanup_all() {
    echo "Cleaning up all VPC peerings..."
    
    # Remove all peering interfaces
    for interface in $(ip link show | grep "vpeer-" | awk -F: '{print $2}' | awk '{print $1}'); do
        ip link delete "$interface" 2>/dev/null && echo "Removed: $interface"
    done
    
    # Remove peering configurations
    local peering_dir="$PROJECT_ROOT/.vpc_peerings"
    if [[ -d "$peering_dir" ]]; then
        rm -rf "$peering_dir"
        echo "Removed peering configurations"
    fi
}