#!/bin/bash
# VPC Peering Functions
# Handles connecting different VPCs together securely
# Implements AWS-style VPC peering with route tables

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
    
    # === CREATE VETH PAIR FOR PEERING ===
    local peer_name="peer-$vpc1-$vpc2"
    local veth1="veth-$vpc1-$vpc2"    # End in VPC1's bridge
    local veth2="veth-$vpc2-$vpc1"    # End in VPC2's bridge
    
    echo "Creating peering veth pair: $veth1 <-> $veth2"
    ip link add "$veth1" type veth peer name "$veth2"
    # Explanation:
    # - Creates a virtual cable connecting the two VPCs
    # - Like laying a dedicated network cable between two offices
    
    # === CONNECT VETH ENDS TO RESPECTIVE BRIDGES ===
    echo "Connecting $veth1 to br-$vpc1"
    ip link set "$veth1" master "br-$vpc1"
    
    echo "Connecting $veth2 to br-$vpc2"  
    ip link set "$veth2" master "br-$vpc2"
    
    # === ACTIVATE THE PEERING INTERFACES ===
    ip link set "$veth1" up
    ip link set "$veth2" up
    
    # === GET VPC CIDR BLOCKS ===
    local vpc1_cidr=$(get_vpc_cidr "$vpc1")
    local vpc2_cidr=$(get_vpc_cidr "$vpc2")
    
    if [[ -z "$vpc1_cidr" || -z "$vpc2_cidr" ]]; then
        echo "Error: Could not determine VPC CIDR blocks"
        return 1
    fi
    
    echo "VPC $vpc1 CIDR: $vpc1_cidr"
    echo "VPC $vpc2 CIDR: $vpc2_cidr"
    
    # === ADD ROUTES TO EACH VPC ===
    # VPC1 needs route to VPC2's network via peering interface
    add_peering_route "$vpc1" "$vpc2_cidr" "$veth1"
    
    # VPC2 needs route to VPC1's network via peering interface  
    add_peering_route "$vpc2" "$vpc1_cidr" "$veth2"
    
    # === SAVE PEERING CONFIGURATION ===
    save_peering_config "$vpc1" "$vpc2" "$veth1" "$veth2"
    
    echo "✅ VPC peering established: $vpc1 ($vpc1_cidr) ↔ $vpc2 ($vpc2_cidr)"
    echo "   Subnets can now communicate across VPCs"
}

# === CHECK IF PEERING EXISTS ===
check_peering_exists() {
    local vpc1="$1"
    local vpc2="$2"
    
    # Check if peering interfaces exist
    if ip link show "veth-$vpc1-$vpc2" &>/dev/null || \
       ip link show "veth-$vpc2-$vpc1" &>/dev/null; then
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
    fi
}

# === ADD PEERING ROUTE ===
add_peering_route() {
    local vpc_name="$1"
    local target_cidr="$2"
    local via_interface="$3"
    
    echo "Adding route in $vpc_name: $target_cidr via $via_interface"
    
    # Get all subnets in this VPC
    for namespace in $(ip netns list | grep "ns-$vpc_name-"); do
        echo "  Adding route in namespace $namespace"
        ip netns exec "$namespace" ip route add "$target_cidr" dev "$via_interface"
        # Explanation:
        # - Adds a specific route for the peer VPC's network
        # - Traffic for target_cidr goes through the peering interface
        # - Without this route, subnets don't know how to reach the other VPC
    done
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
    local veth1="veth-$vpc1-$vpc2"
    local veth2="veth-$vpc2-$vpc1"
    
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
            ip netns exec "$namespace" ip route del "$peer_cidr" 2>/dev/null && \
                echo "Removed route for $peer_cidr from $namespace"
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
        source "$config_file"
        local status="ACTIVE"
        
        # Check if peering interfaces still exist
        if ! ip link show "$VETH1" &>/dev/null || ! ip link show "$VETH2" &>/dev/null; then
            status="BROKEN"
        fi
        
        printf "%-9s %-9s %-9s %-10s\n" "$VPC1" "$VPC2" "$status" "$(echo $CREATED_AT | cut -d' ' -f1)"
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
    
    # Get first public subnet from each VPC
    local vpc1_subnet=$(ip netns list | grep "ns-$vpc1-public" | head -1)
    local vpc2_subnet=$(ip netns list | grep "ns-$vpc2-public" | head -1)
    
    if [[ -z "$vpc1_subnet" || -z "$vpc2_subnet" ]]; then
        echo "Error: Both VPCs need at least one public subnet"
        return 1
    fi
    
    # Get IP addresses from each subnet
    local vpc1_ip=$(get_namespace_ip "$vpc1_subnet")
    local vpc2_ip=$(get_namespace_ip "$vpc2_subnet")
    
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
    
    # Get the first non-loopback IP address
    ip netns exec "$namespace" ip addr show | grep -E "veth.*inet" | head -1 | awk '{print $2}' | cut -d'/' -f1
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
    
    echo "Deploying nginx in $namespace ($namespace_ip)"
    
    # Install nginx in the namespace
    ip netns exec "$namespace" bash -c '
        apt-get update > /dev/null 2>&1
        apt-get install -y nginx > /dev/null 2>&1
        
        # Create custom index page
        cat > /var/www/html/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <title>VPC Test Server</title>
</head>
<body>
    <h1>Hello from $(hostname)</h1>
    <p>Namespace: '"$namespace"'</p>
    <p>IP Address: '"$namespace_ip"'</p>
    <p>Time: $(date)</p>
</body>
</html>
HTML
        
        # Start nginx
        systemctl enable nginx --now > /dev/null 2>&1
        echo "Nginx started on port 80"
    ' &
    
    echo "✅ Nginx deployed in $namespace"
    echo "   Access: curl http://$namespace_ip"
}

# === DEPLOY PYTHON SERVER ===
deploy_python_server() {
    local namespace="$1"
    local namespace_ip=$(get_namespace_ip "$namespace")
    local port="8080"
    
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