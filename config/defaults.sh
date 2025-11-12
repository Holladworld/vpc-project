#!/bin/bash
# Configuration defaults for VPC system
# This file contains all settings and constants

# === PATHS AND DIRECTORIES ===
readonly LOG_DIR="./logs"
readonly CONFIG_DIR="./configs"

# === NETWORK DEFAULTS ===
readonly INTERNET_INTERFACE="eth0"  # Default internet-facing interface
readonly DEFAULT_VPC_CIDR="10.0.0.0/16"  # Default CIDR for VPCs

# === COLOR DEFINITIONS ===
# ANSI color codes for pretty output
readonly RED='\033[0;31m'    # Red color
readonly GREEN='\033[0;32m'  # Green color  
readonly YELLOW='\033[1;33m' # Yellow color
readonly BLUE='\033[0;34m'   # Blue color
readonly NC='\033[0m'        # No Color (reset)

# === LOGGING SETTINGS ===
readonly LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
