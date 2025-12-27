#!/bin/bash
# -----------------------------------------------------------------------------------------
# TITLE:        Unraid Backup Server Script (Optimized & Documented)
# AUTHOR:       System Administrator / Gemini AI
# DESCRIPTION:  Syncs data/appdata from a Source Unraid server to a Backup Unraid server.
#               Manages Docker container states (start/stop) to ensure database integrity.
# PLATFORM:     Unraid (Slackware-based Linux)
# -----------------------------------------------------------------------------------------

# --- SAFETY: Set standard permissions ---
# umask 0022 results in: Directories 755 (drwxr-xr-x), Files 644 (rw-r--r--)
# This prevents creating world-writable files (security risk) while allowing readability.
umask 0022

###########################################################################################
#                                 CONFIGURATION SECTION                                   #
###########################################################################################

# Network Settings
source_server_ip="192.168.4.2"

# Automation Flags
forcestart="no"       # Set to "yes" to run backup even if source didn't request it
checkandstart="no"    # Set to "yes" to wake up containers if source is dead (failover)

# Container Management
# List the exact names of Docker containers to manage during backup.
declare -a container_list=("EmbyServerBeta" "swag") 

# Constants & Paths
HOST="root@${source_server_ip}"
CONFIG_DIR="/mnt/user/appdata/backupserver"
CONFIG_FILE="${CONFIG_DIR}/config.cfg"
LOCK_FILE="${CONFIG_DIR}/start"

# Unraid Specific Tooling
# This is the built-in Unraid script for GUI/Email/Discord notifications.
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

# Default Variables (Fail-safes)
# These are initialized here so the script doesn't crash if config.cfg fails to load.
copymaindata="no"
copyappdata="no"
switchserver="no"
poweroff="no"
logname="/mnt/user/appdata/backupserver/backup.log"


###########################################################################################
#                                   HELPER FUNCTIONS                                      #
###########################################################################################

# -----------------------------------------------------------------------------------------
# Function: send_notification
# Purpose:  Sends system alerts using Unraid's native notification system.
#           Alerts appear in the WebUI and any configured agents (Discord, Email, etc.).
# Inputs:   $1 = Severity (normal, warning, alert)
#           $2 = Message Content
# -----------------------------------------------------------------------------------------
send_notification() {
    local severity="$1" 
    local message="$2"
    
    # Print to console for manual debugging
    echo "[${severity^^}] ${message}"
    
    # Send to Unraid GUI if the tool exists
    if [ -x "$NOTIFY" ]; then
        "$NOTIFY" -e "Backup Script" -s "Backup Event" -d "${message}" -i "${severity}"
    fi
}

###########################################################################################
#                                 CORE SYNC LOGIC                                         #
###########################################################################################

# -----------------------------------------------------------------------------------------
# Function: Check_Source_Server
# Purpose:  1. Verifies connectivity to the source server.
#           2. Downloads the latest config.cfg from the source.
#           3. Checks for the existence of the 'start' lock file on the source.
# Logic:    If server is unreachable and failover is enabled, it starts local containers.
# -----------------------------------------------------------------------------------------
Check_Source_Server() {
    echo "Checking source server status..."
    
    if ! ping -c3 -q "$source_server_ip" &>/dev/null; then
        sourceserverstatus="off"
        echo "Source server ($source_server_ip) is unreachable."

        if [ "$checkandstart" == "yes" ]; then
            send_notification "warning" "Source server down. Initiating Failover: Starting containers."
            startcontainers_failover
        else
            echo "Source is down and Failover is disabled. Exiting."
        fi
        exit 0
    else
        sourceserverstatus="on"
        mkdir -p "$CONFIG_DIR"

        # Attempt to pull the config file
        if ! rsync -avhsP "$HOST":"$CONFIG_DIR/" "$CONFIG_DIR/"; then
            echo "Error: Could not sync config file from source."
            # If we can't get the config, we default to NOT running the heavy syncs
            start="no"
        else
            # Source the configuration file safely
            if [ -f "$CONFIG_FILE" ]; then
                # shellcheck source=/dev/null
                source "$CONFIG_FILE"
            else
                echo "Warning: Config file missing locally after sync attempt."
            fi
        fi

        # Check for remote start flag/lock file
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "[ -f $LOCK_FILE ]"; then
            start="yes"
        else
            start="no"
        fi
    fi
}

# -----------------------------------------------------------------------------------------
# Function: sync_data_loop
# Purpose:  Iterates through numbered variables (source1..9, dest1..9) and runs rsync.
# Inputs:   $1 = "main" (for array data) or "appdata" (for docker appdata)
# Safety:   Includes CRITICAL checks to ensure source/dest variables are not empty.
#           This prevents "rsync --delete / /" scenarios which wipe servers.
# -----------------------------------------------------------------------------------------
sync_data_loop() {
    local type="$1" 
    
    # Loop 1 through 9
    for i in {1..9}; do
        # Indirect variable expansion to get values of source1, source2, etc.
        if [ "$type" == "main" ]; then
            local src_var="source$i"
            local dest_var="destination$i"
        else
            local src_var="appsource$i"
            local dest_var="appdestination$i"
        fi

        local src="${!src_var}"
        local dest="${!dest_var}"

        # 1. SKIP IF EMPTY: If variables aren't set in config, skip this number
        if [[ -z "$src" ]] || [[ -z "$dest" ]]; then
            continue
        fi
        
        # 2. ROOT PROTECTION: Prevent accidental sync to root directory
        if [[ "$dest" == "/" ]]; then
            echo "CRITICAL SAFETY ERROR: Destination is set to root (/). Skipping Set $i."
            send_notification "alert" "Skipped Sync Set $i due to root destination safety check."
            continue
        fi

        echo "-----------------------------------------------------"
        echo "Syncing $type Set $i"
        echo "Source:      $src"
        echo "Destination: $dest"
        echo "-----------------------------------------------------"
        
        # 3. EXECUTE RSYNC
        # --delete: Removes files on backup that no longer exist on source
        # --timeout: Fails if no data transferred for 600 seconds (prevents hangs)
        rsync -avhsP --delete --timeout=600 "$HOST":"$src" "$dest"
        
        local rsync_status=$?
        if [ $rsync_status -ne 0 ]; then
             send_notification "alert" "Rsync failed for $src with error code $rsync_status"
        fi
    done
}

# -----------------------------------------------------------------------------------------
# Function: syncmaindata
# Purpose:  Wrapper that checks if 'copymaindata' is enabled before triggering the loop.
# -----------------------------------------------------------------------------------------
syncmaindata() {
    if [ "$copymaindata" == "yes" ]; then
        echo "Initiating Main Data Sync..."
        sync_data_loop "main"
    else
        echo "Main Data Sync skipped (Config setting: copymaindata != yes)"
    fi
}

# -----------------------------------------------------------------------------------------
# Function: syncappdata
# Purpose:  Wrapper for Appdata sync. 
# Logic:    1. STOPS containers on Backup (prevent DB corruption).
#           2. STOPS containers on Source (prevent DB corruption).
#           3. Runs the sync.
#           4. STARTS containers (based on configuration).
# -----------------------------------------------------------------------------------------
syncappdata() {
    if [ "$copyappdata" == "yes" ]; then
        echo "Initiating Appdata Sync..."
        
        shutdowncontainers "backup"
        shutdowncontainers "source"
        
        sync_data_loop "appdata"
        
        startupcontainers
    else
        echo "Appdata Sync skipped (Config setting: copyappdata != yes)"
    fi
}

###########################################################################################
#                            CONTAINER MANAGEMENT LOGIC                                   #
###########################################################################################

# -----------------------------------------------------------------------------------------
# Function: shutdowncontainers
# Purpose:  Stops the containers defined in 'container_list'.
# Inputs:   $1 = "source" (Remote server) or "backup" (Local server)
# -----------------------------------------------------------------------------------------
shutdowncontainers() {
    local target="$1"
    
    # Skip if list is empty
    if [ ${#container_list[@]} -eq 0 ]; then return; fi

    if [ "$target" == "source" ]; then
        echo "Stopping containers on REMOTE (Source)..."
        for cont in "${container_list[@]}"; do
            ssh "$HOST" "docker stop \"$cont\""
        done
    else
        echo "Stopping containers on LOCAL (Backup)..."
        for cont in "${container_list[@]}"; do
            docker stop "$cont"
        done
    fi
    
    echo "Waiting 10s for databases to flush and close gracefully..."
    sleep 10
}

# -----------------------------------------------------------------------------------------
# Function: startupcontainers
# Purpose:  Restarts containers after sync is complete.
# Logic:    Determines WHERE to start containers based on 'switchserver' variable.
#           switchserver=yes -> Start on Backup (Failover mode/Migration)
#           switchserver=no  -> Start on Source (Standard Backup)
# -----------------------------------------------------------------------------------------
startupcontainers() {
    if [ ${#container_list[@]} -eq 0 ]; then return; fi

    if [ "$switchserver" == "yes" ]; then
        echo "Starting containers on LOCAL (Backup) server..."
        for cont in "${container_list[@]}"; do
            docker start "$cont"
        done
    elif [ "$switchserver" == "no" ]; then
        echo "Starting containers on REMOTE (Source) server..."
        for cont in "${container_list[@]}"; do
            ssh "$HOST" "docker start \"$cont\""
        done
    fi
}

# -----------------------------------------------------------------------------------------
# Function: startcontainers_failover
# Purpose:  Emergency function called only if Source server is detected as offline.
# -----------------------------------------------------------------------------------------
startcontainers_failover() { 
    if [ ${#container_list[@]} -eq 0 ]; then return; fi
    
    echo "Failover Triggered: Starting local containers."
    for cont in "${container_list[@]}"; do
       docker start "$cont"
    done
}

###########################################################################################
#                               CLEANUP & SHUTDOWN                                        #
###########################################################################################

# -----------------------------------------------------------------------------------------
# Function: endandshutdown
# Purpose:  1. Deletes the 'start' lock file on the source (job done).
#           2. Checks 'poweroff' config to see if either server should shut down.
#           3. Sends final success notification.
# -----------------------------------------------------------------------------------------
endandshutdown() {
    # Remove remote lock file to signal completion
    ssh "$HOST" "rm -f $LOCK_FILE"

    if [ "$poweroff" == "backup" ]; then
        send_notification "normal" "Backup complete. Shutting down LOCAL server."
        /sbin/powerdown
    elif [ "$poweroff" == "source" ]; then
        send_notification "normal" "Backup complete. Shutting down SOURCE server."
        ssh "$HOST" '/sbin/powerdown'
        
        # Create a local marker so we know we shut the source down intentionally
        touch "${CONFIG_DIR}/i_shutdown_source_server"
    else
        send_notification "normal" "Backup job finished successfully. No shutdown requested."
    fi
}

###########################################################################################
#                                   MAIN EXECUTION                                        #
###########################################################################################

# -----------------------------------------------------------------------------------------
# Function: Main_Sync_Function
# Purpose:  The orchestrator. Checks flags and calls the sync functions in order.
# -----------------------------------------------------------------------------------------
Main_Sync_Function() {
    # Run if the source requested it ($start) OR if we forced it locally ($forcestart)
    if [ "$start" == "yes" ] || [ "$forcestart" == "yes" ]; then
        send_notification "normal" "Starting Backup Routine..."
        
        syncmaindata 
        syncappdata 
        endandshutdown 
        
    else
        echo "Sync not requested by source, and 'forcestart' is not enabled."
        echo "Exiting."
    fi
}

# -----------------------------------------------------------------------------------------
# Script Entry Point
# -----------------------------------------------------------------------------------------

# 1. Run server checks
Check_Source_Server

# 2. Run Main Routine with logging
#    We use 'tee' to send output to the local console AND append it to the log file 
#    on the REMOTE server via SSH.
if [[ -n "$logname" ]]; then
    echo "Logging output to local console and remote file: $logname"
    Main_Sync_Function 2>&1 | tee >(ssh "$HOST" "cat >> \"$logname\"")
else
    echo "Logging output to local console only."
    Main_Sync_Function
fi

exit 0