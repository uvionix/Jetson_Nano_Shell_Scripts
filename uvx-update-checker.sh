#!/bin/bash

# Initialization
updates_repo_cloned=0
patchMapFile="/etc/default/uvx-patch-map"

echo "Stopping the network watchdog service..."
service network-watchdog stop

echo "Stopping the VPN service..."
service openvpn-autostart stop

echo "Stopping MAVProxy..."
service mavproxy-autostart stop

# Get the logged-in username
usr=$(logname)

# Create the download directory
mkdir /home/$usr/Repos
cd /home/$usr/Repos

# Remove previous versions of downloaded repositories
repoexists=$(ls | grep "Jetson_Nano_Patch_Map")
if [ ! -z "$repoexists" ]
then
	rm -d -r Jetson_Nano_Patch_Map
fi

repoexists=$(ls | grep "Jetson_Nano_Updates")
if [ ! -z "$repoexists" ]
then
        rm -d -r Jetson_Nano_Updates
fi

echo "Checking for updates..."
sleep 10

# Clone the patch map
git clone https://github.com/sdarmonski/Jetson_Nano_Patch_Map.git

grep patch /home/$usr/Repos/Jetson_Nano_Patch_Map/uvx-patch-map | while read -r line; do
	patch_applied=$(grep "$line" /etc/default/uvx-patch-map)

	if [ -z $patch_applied ]
	then
		echo "Patch $line missing."

		if [ $updates_repo_cloned -eq 0 ]
		then
			updates_repo_cloned=1
			echo "Cloning the updates repository..."
			git clone https://github.com/sdarmonski/Jetson_Nano_Updates.git
		fi

		echo "Starting UVX updater..."
		python3 /usr/local/bin/uvx-update-gui.py /home/$usr/Repos/Jetson_Nano_Updates/$line.sh $line

		if [ $? -eq 0 ]
		then
			# Update the patch map
			echo "Updating the patch map..."
			printf "%s\n" "$line" >> $patchMapFile
		else
			echo "Applying patch $line failed!"
		fi
	else
		echo "Patch $line has already been applied. Skipping..."
	fi
done

# Clear the downloaded files
echo "Removing downloaded files..."

repoexists=$(ls | grep "Jetson_Nano_Updates")
if [ ! -z "$repoexists" ]
then
        rm -d -r Jetson_Nano_Updates
fi

rm -d -r Jetson_Nano_Patch_Map

echo "Starting the network watchdog service..."
service network-watchdog start
