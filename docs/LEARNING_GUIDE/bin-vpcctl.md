#!/bin/bash
# Main VPC CLI - Entry point for the VPC management system
# This file routes commands to the appropriate library functions

# === PATH SETUP ===
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explanation:
# - `dirname "${BASH_SOURCE[0]}"` gets the directory containing this script
# - `cd ... && pwd` changes to that directory and prints working directory
# - This ensures we always know where our script is, even if called from elsewhere

# Get the project root (one level up from bin/)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Explanation:
# - `dirname "$SCRIPT_DIR"` gets the parent directory of SCRIPT_DIR
# - If SCRIPT_DIR is /home/user/vpc-project/bin, then PROJECT_ROOT is /home/user/vpc-project

# === IMPORT LIBRARIES ===
# Load all our module files
source "$PROJECT_ROOT/lib/vpc_core.sh"      # VPC creation/deletion functions
source "$PROJECT_ROOT/lib/subnet_manager.sh" # Subnet management functions  
source "$PROJECT_ROOT/lib/firewall.sh"       # Firewall rule functions
source "$PROJECT_ROOT/lib/peering.sh"        # VPC peering functions
source "$PROJECT_ROOT/config/defaults.sh"    # Configuration settings
# Explanation:
# - `source` loads and executes the file in current shell
# - This makes all functions from these files available here
# - Like `import` in Python or `require` in Node.js

# === MAIN COMMAND ROUTER ===
main() {
    # $1 is the first argument (command name)
    # $2, $3, etc. are additional arguments
    case "$1" in
        create-vpc)    create_vpc "$2" "$3" ;;  # Call create_vpc with args 2 and 3
        delete-vpc)    delete_vpc "$2" ;;       # Call delete_vpc with arg 2
        add-subnet)    add_subnet "$2" "$3" "$4" ;; # Call add_subnet with args 2,3,4
        list-vpcs)     list_vpcs ;;             # Call list_vpcs with no args
        *)             show_usage ;;            # Show help for unknown commands
    esac
    # Explanation:
    # - `case` statement matches the first argument against patterns
    # - `*)` is the default case (like 'else')
    # - `;;` ends each case block
}

# === USAGE INFORMATION ===
show_usage() {
    echo "VPC Management System"
    echo "Usage: $0 {create-vpc|delete-vpc|add-subnet|list-vpcs}"
    echo ""
    echo "Examples:"
    echo "  sudo $0 create-vpc my-vpc 10.0.0.0/16"
    echo "  sudo $0 add-subnet my-vpc public 10.0.1.0/24"
    echo "  sudo $0 list-vpcs"
    echo "  sudo $0 delete-vpc my-vpc"
    # Explanation:
    # - `$0` is the script name (./bin/vpcctl)
    # - This shows users how to use our CLI
}

# === SCRIPT START ===
# Check if any arguments were provided
if [ $# -eq 0 ]; then
    # No arguments - show usage
    show_usage
else
    # Arguments provided - process them
    main "$@"
    # Explanation:
    # - `$#` is number of arguments
    # - `"$@"` means "all arguments as separate words"
    # - This calls main() with all the arguments passed to the script
fi
