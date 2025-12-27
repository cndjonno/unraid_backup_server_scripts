#!/bin/bash
# Description: Orchestrates Unraid Backup Server Wake-up and Config Generation
# Author: cndjonno (Refactored)

# 1. SAFETY: Set permissions so only the owner (root) can read/write generated files
umask 0077

############# Basic Settings ########################
startbackup="etherwake"         # Methods: "etherwake", "ipmi", "smartplug"
startsource="etherwake"
source_ipmiadminuser="admin"
source_ipmiadminpassword="password"
dest_ipmiadminuser="admin"
dest_ipmiadminpassword="password"
backup_smartplug_ip="http://xxx.xxx.xxx.xxx"
source_smartplug_ip="http://xxx.xxx.xxx.xxx"

############# Network Settings ######################
sourcemacaddress="xx:xx:xx:xx:xx:xx"
backupmacaddress="xx:xx:xx:xx:xx:xx"
source_server_ip="192.168.1.100"
destination_server_ip="192.168.1.101"

############# Sync Process Settings #################
poweroff="source"             # "none", "both", "source", "backup"
copymaindata="yes"
copyappdata="yes"
switchserver="yes"            # Backup takes over containers?
sync_appdata_both_ways="yes"
sync_maindata_both_ways="no"

# Containers to start/stop (Space separated strings)
# Use quotes correctly inside the array if names contain spaces
declare -a container_start_stop=("null" "null")

# VMs to check prevents shutdown if running
declare -a vms=("null" "null") 
continueifvmsrunning="no"     # "yes" = don't shut down source, shut down backup instead

############# Source Directories ####################
# Arrays are cleaner, but keeping your numbered variable format for compatibility 
# with your destination script logic.
source1=""
source2=""
source3=""
source4=""
source5=""
source6=""
source7=""
source8=""
source9=""

appsource1=""
appsource2=""
appsource3=""
appsource4=""
appsource5=""
appsource6=""
appsource7=""
appsource8=""
appsource9=""

############# Destination Directories ###############
destination1=""
destination2=""
destination3=""
destination4=""
destination5=""
destination6=""
destination7=""
destination8=""
destination9=""

appdestination1=""
appdestination2=""
appdestination3=""
appdestination4=""
appdestination5=""
appdestination6=""
appdestination7=""
appdestination8=""
appdestination9=""

############# Advanced Settings #####################
# Unraid Specific: Using /mnt/cache/ is preferred for appdata if available to avoid FUSE overhead.
# However, /mnt/user/ is safest for compatibility.
BASE_DIR="/mnt/user/appdata/backupserver"
CONFI="${BASE_DIR}/config.cfg"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/$(date +'%Y-%m-%d--%H:%M')--source_to_destination.txt"
MAX_RETRIES=10  # How many 30-second intervals to wait for backup server (5 mins total)

#####################################################
# FUNCTIONS
#####################################################

setup_environment() {
    # Ensure directories exist
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
    if [ ! -d "$BASE_DIR" ]; then
        mkdir -p "$BASE_DIR"
    fi
}

check_vm_status() {
    echo "Checking VM status..."
    vmrunning="false"
    
    for vmval in "${vms[@]}"; do
        if [ "$vmval" == "null" ]; then continue; fi
        
        # Unraid Specific: Robust check using virsh domstate
        # Redirect stderr to dev/null in case VM doesn't exist
        state=$(virsh domstate "$vmval" 2>/dev/null)
        
        if [[ "$state" == "running" ]]; then
            echo "VM '$vmval' is RUNNING."
            vmrunning="true"
        else
            echo "VM '$vmval' is not running (State: $state)."
        fi
    done
}

determine_action() {
    # check if backup server is already online
    if ping -c 1 -W 1 "$destination_server_ip" > /dev/null 2>&1; then
        destserverstatus="on"
        echo "Backup server is ALREADY ONLINE."
        echo "WARNING: If an automated sync requires a fresh boot, this may fail."
        echo "Continuing anyway as requested..."
    else
        destserverstatus="off"
        echo "Backup server is currently OFF."
    fi

    check_vm_status

    if [ "$vmrunning" == "true" ]; then
        if [ "$continueifvmsrunning" == "no" ]; then
            echo "CRITICAL: Specified VMs are running and 'continueifvmsrunning' is set to NO."
            echo "Exiting script to prevent data loss or service interruption."
            exit 1
        else
            echo "VMs are running, but continuing. Source server will NOT shutdown."
            poweroff="backup"
            # If we are not shutting down source, we likely shouldn't switch servers
            if [ "$switchserver" == "yes" ]; then
                 echo "Overriding switchserver to 'no' because Source is staying online."
                 switchserver="no"
            fi
        fi
    else
        echo "No critical VMs running. Proceeding with standard power logic."
    fi

    # Logic for Poweroff flags
    if [ "$poweroff" == "backup" ]; then
        echo "Config: Backup server will shutdown after sync."
        switchserver="no"
    elif [ "$poweroff" == "source" ]; then
        echo "Config: Source server will shutdown after sync."
        switchserver="yes"
    else
        echo "Config: No servers set to power off."
    fi

    if [ "$switchserver" == "yes" ]; then
        copyappdata="yes"
        poweroff="source" # Enforce source shutdown
        echo "Config: Server duties will SWITCH to backup server."
    fi

    # Create the flag file for the destination script
    touch "${BASE_DIR}/start"
    echo "Created trigger file at ${BASE_DIR}/start"
}

wait_for_backup_server() {
    local retry_count=0
    
    # If it was already on, we don't need to wait, but we still proceed
    if [ "$destserverstatus" == "on" ]; then
        return
    fi

    echo "Waiting for backup server to come online..."
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if ping -c 1 -W 1 "$destination_server_ip" > /dev/null 2>&1; then
            echo "Backup server is now ONLINE."
            destserverstatus="on"
            return
        fi
        
        echo "Attempt $((retry_count+1)) of $MAX_RETRIES: Server not up yet. Waiting 30s..."
        ((retry_count++))
        sleep 30
    done

    echo "ERROR: Backup server failed to wake up after $((MAX_RETRIES * 30)) seconds."
    exit 1
}

smartplug_control() {
    local action=$1 # "on" or "off"
    local cmd=""
    if [ "$action" == "on" ]; then cmd="Power%20On"; else cmd="Power%20off"; fi
    
    if [ "$startbackup" == "smartplug" ]; then
        echo "Sending SmartPlug command: $action"
        curl -s "${backup_smartplug_ip}/cm?cmnd=${cmd}" > /dev/null
    fi
}

wake_server() {
    case "$startbackup" in
        "smartplug")
            smartplug_control "off"
            sleep 5
            smartplug_control "on"
            ;;
        "ipmi")
            echo "Sending IPMI Power On command..."
            ipmitool -I lan -H "$destination_server_ip" -U "$dest_ipmiadminuser" -P "$dest_ipmiadminpassword" chassis power on
            ;;
        "etherwake"|*)
            echo "Sending Magic Packet (Wake on LAN)..."
            etherwake -b "$backupmacaddress"
            ;;
    esac
}

write_config_file() {
    echo "Generating Configuration File at $CONFI..."
    
    # OPTIMIZATION: Use cat <<EOF to write the file in one go.
    # Note: We quote the EOF ("EOF") to prevent expansion of variables during writing if we wanted literals,
    # but here we WANT variables to expand, so we use unquoted EOF.
    
    cat > "$CONFI" <<EOF
# Generated Configuration File - Do Not Edit Manually
# Data source directories
source1="$source1"
source2="$source2"
source3="$source3"
source4="$source4"
source5="$source5"
source6="$source6"
source7="$source7"
source8="$source8"
source9="$source9"

# Appdata source directories
appsource1="$appsource1"
appsource2="$appsource2"
appsource3="$appsource3"
appsource4="$appsource4"
appsource5="$appsource5"
appsource6="$appsource6"
appsource7="$appsource7"
appsource8="$appsource8"
appsource9="$appsource9"

# Destination directories
destination1="$destination1"
destination2="$destination2"
destination3="$destination3"
destination4="$destination4"
destination5="$destination5"
destination6="$destination6"
destination7="$destination7"
destination8="$destination8"
destination9="$destination9"

# Appdata destination directories
appdestination1="$appdestination1"
appdestination2="$appdestination2"
appdestination3="$appdestination3"
appdestination4="$appdestination4"
appdestination5="$appdestination5"
appdestination6="$appdestination6"
appdestination7="$appdestination7"
appdestination8="$appdestination8"
appdestination9="$appdestination9"

# System Variables
source_server_ip="$source_server_ip"
destination_server_ip="$destination_server_ip"
poweroff="$poweroff"
startbackup="$startbackup"
startsource="$startsource"
backup_smartplug_ip="$backup_smartplug_ip"
source_smartplug_ip="$source_smartplug_ip"
source_ipmiadminuser="$source_ipmiadminuser"
source_ipmiadminpassword="$source_ipmiadminpassword"
dest_ipmiadminuser="$dest_ipmiadminuser"
dest_ipmiadminpassword="$dest_ipmiadminpassword"
sourcemacaddress="$sourcemacaddress"
backupmacaddress="$backupmacaddress"
copyappdata="$copyappdata"
copymaindata="$copymaindata"
switchserver="$switchserver"
sync_appdata_both_ways="$sync_appdata_both_ways"
sync_maindata_both_ways="$sync_maindata_both_ways"
loglocation="$loglocation"
logname="$logname"

# Arrays reconstructed
container_start_stop=(${container_start_stop[@]})
EOF

    echo "Configuration file written successfully."
}

#####################################################
# MAIN EXECUTION
#####################################################

main() {
    setup_environment
    determine_action
    wake_server
    write_config_file
    wait_for_backup_server
    
    echo "Sequence complete. Destination server should now pick up the job."
}

# Redirect all output to log file AND console (tee)
# mkdir check happens in setup_environment, so we run that first manually
if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR"; fi

main 2>&1 | tee -a "$LOG_FILE"