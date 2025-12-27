#!/bin/bash
# TITLE: backup server script
# WARNING: needs source server script setup on source server to work
umask 0000
############# Basic settings ##########################################################
source_server_ip="192.168.4.2" # set to the ip of the source server
forcestart="no"  # default is "no" - set to yes to force process to run even if source server didn't request
checkandstart="no" # default is "no" - set to yes for script to start below containers if main server is NOT running
declare -a container_start=("EmbyServerBeta" "swag") # put each container name in quotes ie container_start_stop=("EmbyServerBeta" "swag")

############# Declared Variables ##########################################################
HOST="root@""$source_server_ip" # dont change
CONFI="/mnt/user/appdata/backupserver/" # dont change

#############  Functions ##############################################################
Check_Source_Server() {
    # Check if source server is reachable (Ping 3 times, quiet output)
    # Using 'if ! ping' is cleaner than checking $?
    if ! ping -c3 -q "$source_server_ip" &>/dev/null; then
        # --- Server is OFF ---
        sourceserverstatus="off"
        echo "Source server is off."

        if [ "$checkandstart" == "yes" ]; then
            echo "I will start selected containers"
            startcontainers_if_main_off
        else
            echo "Exiting"
        fi
        
        # Exit script immediately since server is off
        exit 0
    else
        # --- Server is ON ---
        sourceserverstatus="on"
        
        # Prepare config directory
        mkdir -p "$CONFI"

        # Sync config file. If rsync fails, set start="no"
        if ! rsync -avhsP "$HOST":"$CONFI" "$CONFI"; then
            start="no"
        fi

        # Source the configuration file if it exists
        if [ -f "${CONFI}config.cfg" ]; then
            source "${CONFI}config.cfg"
        else
            echo "Warning: Config file not found at ${CONFI}config.cfg"
        fi

        # Check if the 'start' file exists on the remote source server
        if ssh "$HOST" "[ -f /mnt/user/appdata/backupserver/start ]"; then
            start="yes"
        else
            start="no"
        fi
    fi
}

#######################################################################################

# sync data from source server to backup server
syncmaindata() {
    # Check if main data backup is enabled
    if [ "$copymaindata" == "yes" ]; then
        
        # Loop through numbers 1 to 9
        for i in {1..9}; do
            # Dynamically construct the variable names (e.g., source1, destination1)
            src_var="source$i"
            dest_var="destination$i"

            # Use Bash "indirect expansion" to get the actual value stored in those variables
            src="${!src_var}"
            dest="${!dest_var}"

            # Only run rsync if BOTH source and destination have values
            if [ -n "$src" ] && [ -n "$dest" ]; then
                echo "Syncing Main Data Set $i: $src -> $dest"
                rsync -avhsP --delete "$HOST":"$src" "$dest"
            fi
        done
    fi
}

#######################################################################################

syncappdata() {
    # Check if appdata backup is enabled
    if [ "$copyappdata" == "yes" ]; then
        
        shutdowncontainersbackup
        shutdowncontainerssource 

        # Loop through numbers 1 to 9
        for i in {1..9}; do
            # Dynamically construct the variable names (e.g., appsource1, appdestination1)
            src_var="appsource$i"
            dest_var="appdestination$i"

            # Use Bash "indirect expansion" to get the actual value stored in those variables
            src="${!src_var}"
            dest="${!dest_var}"

            # Only run rsync if BOTH source and destination have values
            if [ -n "$src" ] && [ -n "$dest" ]; then
                echo "Syncing Set $i: $src -> $dest"
                rsync -avhsP --delete "$HOST":"$src" "$dest"
            fi
        done

        startupcontainers
    fi
}

#######################################################################################

# this function cleans up and exits script shutting down server if that has been set
endandshutdown() {
    # 1. CLEANUP FIRST
    # We remove the start flag on the source server *before* potentially powering off.
    # In the original script, if 'poweroff' ran first, the script might die 
    # before reaching the cleanup line.
    ssh "$HOST" 'rm -f /mnt/user/appdata/backupserver/start'

    # 2. HANDLE POWER STATE
    if [ "$poweroff" = "backup" ]; then
        echo "Shutting down backup server"
        poweroff
        
    elif [ "$poweroff" = "source" ]; then
        echo "Shutting down source server"
        # Send poweroff command to source
        ssh "$HOST" 'poweroff'
        echo "Source server will shut off shortly"
        
        # Create local marker file
        touch /mnt/user/appdata/backupserver/i_shutdown_source_server
        
    else
        echo "Neither Source nor Backup server set to turn off"
    fi
}


#######################################################################################

# this function plays completion tune when sync finished (will not work without beep speaker)
completiontune() {
    # Check if 'beep' is installed to prevent errors
    if ! command -v beep &> /dev/null; then
        echo "Speaker tool 'beep' not found. Skipping tune."
        return
    fi

    # Play tune (broken into multiple lines for readability)
    beep \
    -l 600 -f 329.628 -n -l 400 -f 493.883 -n -l 200 -f 329.628 -n -l 200 -f 493.883 -n -l 200 -f 659.255 -n \
    -l 600 -f 329.628 -n -l 400 -f 493.883 -n -l 200 -f 329.628 -n -l 200 -f 493.883 -n -l 200 -f 659.255 -n \
    -l 600 -f 329.628 -n -l 360 -f 493.883 -n -l 200 -f 329.628 -n -l 200 -f 493.883 -n -l 640 -f 659.255 -n \
    -l 160 -f 622.254 -n -l 200 -f 329.628 -n -l 200 -f 554.365 -n -l 200 -f 329.628 -n -l 200 -f 622.254 -n \
    -l 200 -f 493.883 -n -l 200 -f 830.609 -n -l 200 -f 415.305 -n -l 80 -f 739.989 -n -l 40 -f 783.991 -n \
    -l 80 -f 739.989 -n -l 200 -f 415.305 -n -l 200 -f 659.255 -n -l 200 -f 622.254 -n -l 400 -f 554.365 -n \
    -l 1320 -f 415.305 -n -l 40 -f 7458.62 -n -l 40 -f 7040.0 -n -l 40 -f 4186.01 -n -l 40 -f 3729.31 -n \
    -l 40 -f 6644.88 -n -l 40 -f 7902.13 -n -l 40 -f 16.35 -n -l 200 -f 830.609 -n -l 200 -f 415.305 -n \
    -l 40 -f 739.989 -n -l 80 -f 783.991 -n -l 80 -f 739.989 -n -l 200 -f 415.305 -n -l 200 -f 659.255 -n \
    -l 200 -f 622.254 -n -l 400 -f 554.365 -n -l 1320 -f 415.305 -n -l 40 -f 4698.64
}


#######################################################################################

startupcontainers() {
    # Check if there are any containers to start (Array length check)
    if [ ${#container_start_stop[@]} -eq 0 ]; then
        echo "No containers specified to start."
        return
    fi

    # Case 1: Switch Server = YES (Start containers HERE on Backup server)
    if [ "$switchserver" == "yes" ]; then
        echo "Starting specified containers on LOCAL (Backup) server..."
        
        for contval in "${container_start_stop[@]}"; do
            echo "Starting: $contval"
            docker start "$contval"
        done

    # Case 2: Switch Server = NO (Start containers THERE on Source server)
    elif [ "$switchserver" == "no" ]; then
        echo "Starting specified containers on REMOTE (Source) server..."
        
        for contval in "${container_start_stop[@]}"; do
            echo "Starting remote: $contval"
            # Note: We escaped the quotes around the container name (\"...\")
            # to handle container names with spaces correctly over SSH.
            ssh "$HOST" "docker start \"$contval\""
        done
    fi
}


#######################################################################################

shutdowncontainerssource() {
    # Check if there are any containers to stop
    if [ ${#container_start_stop[@]} -eq 0 ]; then
        echo "No containers specified to stop on source."
        return
    fi

    echo "Shutting down specified containers on REMOTE (Source) server..."

    for contval in "${container_start_stop[@]}"; do
        echo "Stopping remote: $contval"
        # Escape quotes to handle container names with spaces over SSH
        ssh "$HOST" "docker stop \"$contval\""
    done
    
    # Allow time for containers to gracefully shut down
    echo "Waiting 10 seconds for containers to settle..."
    sleep 10
}

#######################################################################################

shutdowncontainersbackup() {
    # Check if there are any containers to stop
    if [ ${#container_start_stop[@]} -eq 0 ]; then
        echo "No containers specified to stop on backup."
        return
    fi

    echo "Shutting down specified containers on LOCAL (Backup) server before sync..."

    for contval in "${container_start_stop[@]}"; do
        echo "Stopping: $contval"
        docker stop "$contval"
    done
    
    # Allow time for containers to gracefully shut down
    echo "Waiting 10 seconds for containers to settle..."
    sleep 10
}


#######################################################################################

startcontainers_if_main_off() { 
    # Check if there are any containers to start (Failover)
    if [ ${#container_start[@]} -eq 0 ]; then
        echo "No failover containers specified to start."
        return
    fi

    echo "Source server is OFF. Starting failover containers on Backup server..."

    for contval in "${container_start[@]}"; do
       echo "Starting: $contval"
       docker start "$contval"
    done
}

#######################################################################################

Main_Sync_Function() {
    # Combine logic: Run if 'start' flag is present OR 'forcestart' is enabled
    # This removes the need for two duplicate blocks of code
    if [ "$start" == "yes" ] || [ "$forcestart" == "yes" ]; then
        echo "Starting Sync Process..."
        syncmaindata 
        syncappdata 
        completiontune
        endandshutdown 
    else
        # If neither condition is met, exit
        echo "Source server didn't start the backup server, and force start is not enabled."
        echo "Sync job not requested."
        echo "Source server status: $sourceserverstatus"
        exit 0
    fi
}

############# Start process #############################################################
Check_Source_Server
Main_Sync_Function 2>&1 | ssh "$HOST" -T tee -a "$logname"

exit
