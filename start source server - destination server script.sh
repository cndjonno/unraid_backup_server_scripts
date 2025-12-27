#!/bin/bash
# Description: Starts Source Server, Syncs Data BACK to Source, and Shuts Down Backup Server.
# Author: cndjonno (Refactored by Gemini)

# Set secure permissions for created files
umask 0022

############# variables ##############################################
CONFI="/mnt/user/appdata/backupserver/config.cfg"
LOCK_FILE="/mnt/user/appdata/backupserver/i_shutdown_source_server"

############# functions ##############################

readconfig() { 
    if [ ! -f "$CONFI" ]; then
        echo "ERROR: Config file not found at $CONFI"
        exit 1
    fi
    source "$CONFI"
    
    # Validate critical variables
    if [ -z "$source_server_ip" ]; then
        echo "ERROR: source_server_ip is not set in config."
        exit 1
    fi

    HOST="root@$source_server_ip" 
    mkdir -p "$loglocation"
    logname="${loglocation}$(date +'%Y-%m-%d--%H:%M')--destination_to_source.txt"
    touch "$logname"
}

check_connection() {
    # Check if we can actually SSH to the host before trying to run commands
    ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" exit
    if [ $? -ne 0 ]; then
        echo "ERROR: Cannot SSH to $HOST. Check keys and IP."
        exit 1
    fi
}

shallicontinue() {
    if [ -f "$LOCK_FILE" ]; then
        rm "$LOCK_FILE"
        checksourceserver

        if [ "$sourceserverstatus" == "on" ]; then
            echo "Source server is already running."
            echo "Shutting down backup server..."
            # poweroff # Uncomment this when fully tested
            exit 0
        else
            echo "Source server is off... attempting to start it."
        fi
    else
        echo "Lock file ($LOCK_FILE) not found. I did not shut down the source, so I will not start it. Exiting."
        exit 0
    fi
}

# Combined local and remote container management to avoid code duplication
manage_containers() {
    local action=$1 # stop or start
    local location=$2 # local or remote

    echo "Running docker $action on $location containers..."
    
    for contval in "${container_start_stop[@]}"; do
        if [ "$location" == "remote" ]; then
            ssh "$HOST" docker "$action" "$contval"
        else
            docker "$action" "$contval"
        fi
    done
    sleep 5
}

run_rsync_loop() {
    local type=$1 # 'app' or 'main'
    
    for i in {1..9}; do
        # Dynamically construct variable names
        if [ "$type" == "app" ]; then
            local src_var="appdestination$i" # Local path (Backup)
            local dest_var="appsource$i"     # Remote path (Source)
        else
            local src_var="destination$i"    # Local path (Backup)
            local dest_var="source$i"        # Remote path (Source)
        fi

        # Use indirect expansion to get values
        local src_path="${!src_var}"
        local dest_path="${!dest_var}"

        # Check if both paths are defined
        if [ -n "$src_path" ] && [ -n "$dest_path" ]; then
            echo "Syncing $type #$i: $src_path -> $HOST:$dest_path"
            
            # SAFETY CHECK: Ensure local directory exists and is not empty before running --delete
            if [ -d "$src_path" ]; then
                # Check if directory is empty
                if [ -z "$(ls -A "$src_path")" ]; then
                     echo "WARNING: Local path $src_path is EMPTY. Skipping sync to prevent wiping remote server."
                else
                     rsync -avhsP --delete "$src_path" "$HOST":"$dest_path"
                fi
            else
                echo "ERROR: Local path $src_path does not exist. Skipping."
            fi
        fi
    done
}

syncappdata() {
    if [ "$sync_appdata_both_ways" == "yes" ]; then
        echo "-------------------------------------"
        echo "Starting Appdata Sync to Source..."
        manage_containers "stop" "remote"
        run_rsync_loop "app"
        manage_containers "start" "remote"
        echo "-------------------------------------"
    fi
}

syncmaindata() {
    if [ "$sync_maindata_both_ways" == "yes" ]; then
        echo "-------------------------------------"
        echo "Starting Main Data Sync to Source..."
        run_rsync_loop "main"
        echo "-------------------------------------"
    fi
}

checkarraystarted() {
    local max_retries=30
    local count=0
    
    echo "Checking if remote array is online..."
    # We check if the remote path /mnt/user exists. 
    # SSH returns 0 if command succeeds (dir exists), 1 if fails.
    while ! ssh "$HOST" "[ -d /mnt/user/appdata/ ]"; do
        if [ "$count" -ge "$max_retries" ]; then
            echo "Timeout waiting for remote array. Exiting."
            exit 1
        fi
        echo "Waiting for source server array... (Attempt $count/$max_retries)"
        sleep 10
        ((count++))
    done
    
    echo "Source server array is started."
    echo "Waiting 30 seconds for Docker service stabilization..."
    sleep 30
}

checksourceserver() {
    if ping -c 1 -W 2 "$source_server_ip" > /dev/null 2>&1; then
        sourceserverstatus="on"
    else
        sourceserverstatus="off"
    fi
}

wait_for_source_boot() {
    local max_retries=20
    local count=0
    
    while [ "$sourceserverstatus" == "off" ]; do
        if [ "$count" -ge "$max_retries" ]; then
            echo "Source server failed to boot after significant wait. Exiting."
            exit 1
        fi
        
        checksourceserver
        if [ "$sourceserverstatus" == "off" ]; then
            echo "Source server not up yet. Waiting 30s... (Attempt $count/$max_retries)"
            sleep 30
            ((count++))
        fi
    done
    echo "Source server is ONLINE."
}

# Power Management Functions
wakeonlan_cmd() { [ "$startsource" == "etherwake" ] && etherwake -b "$backupmacaddress"; }
smartplugoff() { [ "$startsource" == "smartplug" ] && curl -s "$source_smartplug_ip/cm?cmnd=Power%20off" > /dev/null; }
smartplugon() { [ "$startsource" == "smartplug" ] && curl -s "$source_smartplug_ip/cm?cmnd=Power%20On" > /dev/null; }
ipmi_on() { 
    if [ "$startsource" == "ipmi" ]; then
        ipmitool -I lan -H "$source_server_ip" -U "$source_ipmiadminuser" -P "$source_ipmiadminpassword" chassis power on
    fi
}

################# start process ################################################

# Trap interrupts to ensure we don't leave mess behind
trap "echo 'Script interrupted'; exit" INT TERM

readconfig

# Start logging everything to file AND console
exec > >(tee -a "$logname") 2>&1

shallicontinue

# Shutdown local containers to free up resources/prevent conflicts
manage_containers "stop" "local"

# Start Source Server
wakeonlan_cmd
ipmi_on
smartplugoff
sleep 5
smartplugon

wait_for_source_boot
check_connection # Verify SSH works before proceeding
checkarraystarted 

# Perform Syncs
syncmaindata
syncappdata 

# Restart local containers (Optional, but good practice if poweroff fails)
manage_containers "start" "local"

# Send Log to remote
echo "Sync complete. Uploading log."
rsync -avhsP "$logname" "$HOST":"$logname" >/dev/null

# Clean up local log
rm "$logname"

echo "Operation successful. Shutting down."
poweroff
exit 0