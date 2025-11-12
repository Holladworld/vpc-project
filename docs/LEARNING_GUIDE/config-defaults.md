#!/bin/bash
# Configuration defaults for VPC system
# This file contains all settings and constants

# === PATHS AND DIRECTORIES ===
readonly LOG_DIR="./logs"
readonly CONFIG_DIR="./configs"
# Explanation:
# - `readonly` makes variable constant (cannot be changed)
# - UPPERCASE naming convention for constants
# - These define where we store logs and configurations

# === NETWORK DEFAULTS ===
readonly INTERNET_INTERFACE="eth0"  # Default internet-facing interface
readonly DEFAULT_VPC_CIDR="10.0.0.0/16"  # Default CIDR for VPCs
# Explanation:
# - These are default values that can be overridden
# - "eth0" is typical name for first Ethernet interface

# === COLOR DEFINITIONS ===
# ANSI color codes for pretty output
readonly RED='\033[0;31m'    # Red color
readonly GREEN='\033[0;32m'  # Green color  
readonly YELLOW='\033[1;33m' # Yellow color
readonly BLUE='\033[0;34m'   # Blue color
readonly NC='\033[0m'        # No Color (reset)
# Explanation:
# - \033 is escape character for terminal colors
# - [0;31m means "normal intensity, red foreground"
# - [0m means "reset to default"
# - Usage: echo -e "${RED}Error${NC}"

# === LOGGING SETTINGS ===
readonly LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
# Explanation:
# - Controls how much detail we log
# - Can be changed to "DEBUG" for troubleshooting
