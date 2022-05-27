#!/bin/bash

##########################
# The script monitors network connectivity and stops/restarts the VPN and MAVProxy services
# when the connectivity is lost and regained. When the connectivity is lost the vehicle mode is switched to LOITER.
# If the network connectivity is not regained after a defined period of time the vehicle mode is switched to RTL.
##########################

# SCRIPT FUNCTIONS

# Initialize script variables
init_variables()
{
	lteDeviceName=""
	mobileConnectionName=""
	mobileInterfaceName=""
	networkStatus=$Reconnecting
	vpn_con_count=0
	net_con_count=0
	ip_address_wait_count=0
	pref_wifi_con_count=0
	wifiNetworkSelected=0
	lteNetworkSelected=0
	switch_to_RTL_mode_service_started=0
	hmiDetected=0
	camConnected=0
}

# Check if a keyboard is connected
check_keyboard_connected()
{
	hmiDetected=0

	for dev in /sys/bus/usb/devices/*-*:*
	do
		if [ -f $dev/bInterfaceClass ]
		then
			if [[ "$(cat $dev/bInterfaceClass)" == "03" && "$(cat $dev/bInterfaceProtocol)" == "01" ]]
			then
				echo "Keyboard detected: $dev"
				printf "Keyboard detected. WIFI connection type is selected.\n" >> $logFile
				hmiDetected=1
				return
			fi
		fi
	done

	echo "Keyboard not detected. LTE connection type is selected."
	printf "Keyboard not detected. LTE connection type is selected.\n" >> $logFile
	sleep 20
}

# Check if a camera is connected
check_camera_connected()
{
	camDetected=$(ls /dev/* | grep /dev/video0)

	if [ -z "$camDetected" ]
	then
		# Cammera is not connected
		if [ $camConnected -eq 1 ]
		then
			nowTime=$(date +"%T")
			service gstreamer-autostart stop
			echo "Camera disconnected. GStreamer stopped."
			printf "%s Camera disconnected. GStreamer stopped.\n" $nowTime >> $logFile
		fi

		camConnected=0
	else
		# Camera is connected
		if [ $camConnected -eq 0 ]
		then
			nowTime=$(date +"%T")
			echo "Camera connected."
			printf "%s Camera connected.\n" $nowTime >> $logFile
			
			if [ $networkStatus -eq $Connected ]
			then
				service gstreamer-autostart start
				nowTime=$(date +"%T")
				echo "GStreamer started."
				printf "%s Gstreamer started.\n" $nowTime >> $logFile

			fi
		fi

		camConnected=1
	fi
}

# Choose connection type (LTE or WIFI) and initialize the connection name and interface
choose_connection_type()
{
	while true
	do
		if [ $hmiDetected -eq 0 ] && [ $lteNetworkSelected -eq 0 ];
		then
			# Select LTE connection type
			lteNetworkSelected=1
			pref_wifi_con_count=$max_pref_wifi_con_count
			wifiConnectionFound=""
			echo "Check if the LTE module is connected..."
			printf "Check if the LTE module is connected...\n" >> $logFile
		fi

		if [ $lteNetworkSelected -eq 0 ]
		then
			# WIFI connection type is selected -> check if a preffered WIFI connection is available
			echo "Check if a preffered WIFI connection is available..."
			printf "Check if a preffered WIFI connection is available...\n" >> $logFile
			# wifiConnectionName=$(nmcli connection | grep -m1 "wifi" | awk -F' ' '{print $1}')
			wifiConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 wifi | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
			len=`expr length "$wifiConnectionName"`

			if [ $len -gt $((min_wifi_con_name_length-1)) ]
			then
				wifiConnectionFound=$(nmcli device wifi list | grep "$wifiConnectionName")
			else
				echo "Invalid WIFI connection name" "$wifiConnectionName" "obtained. Connection name must be at least" "$min_wifi_con_name_length" "characters long!"
				printf "Invalid WIFI connection name %s obtained. Connection name must be at least %d characters long!\n" "$wifiConnectionName" $min_wifi_con_name_length >> $logFile
				sleep $samplingPeriodSec
				continue
			fi
		fi

		if [ -z "$wifiConnectionFound" ] || [ $lteNetworkSelected -eq 1 ];
		then
			# The mobile connection is selected here after a defined number of attemts
			pref_wifi_con_count=$((pref_wifi_con_count+1))

			if [ $pref_wifi_con_count -gt $max_pref_wifi_con_count ]
			then
				# Check if the LTE module is available
				if [ $lteNetworkSelected -eq 0 ]
				then
					echo "Preffered WIFI connection is not available. Check if the LTE module is connected..."
					printf "Preffered WIFI connection is not available. Check if the LTE module is connected...\n" >> $logFile
				fi

				lteNetworkSelected=1
				lteConnected=$(lsusb | grep -i "$lteManufacturerName")

				if [ ! -z "$lteConnected" ]
				then
					# LTE module is connected - get the associated device name
					lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
					echo "LTE module" "$lteManufacturerName" "connected. Getting device name..."
					printf "LTE module %s connected. Getting device name...\n" "$lteManufacturerName" >> $logFile

					if [ -z "$lteDeviceName" ]
					then
						if [ $pref_wifi_con_count -gt $((max_pref_wifi_con_count+5)) ]
						then
							echo "Failed initializing LTE device name. Process restarting..."
							printf "Failed initializing LTE device name. Process restarting...\n" >> $logFile
							pref_wifi_con_count=0
							lteNetworkSelected=0
						fi

						sleep $samplingPeriodSec
						continue
					fi

					echo "LTE module" "$lteManufacturerName" "connected. Device name:" "$lteDeviceName"
					printf "LTE module %s connected. Device name: %s.\n" "$lteManufacturerName" "$lteDeviceName" >> $logFile
					
					lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

					if [ ! -z "$lteDeviceUnavailable" ]
					then
						echo "LTE device is not available. Check the SIM card!"
						printf "LTE device is not available. Check the SIM card!\n" >> $logFile
						echo "Scanning for a preffered WIFI connection..."
						printf "Scanning for a preffered WIFI connection...\n" >> $logFile
						pref_wifi_con_count=0
						lteNetworkSelected=0
						hmiDetected=1
					else
						# LTE device is available - get the mobile connection name
						mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')

						echo "LTE interface name is set to" "$lteInterfaceName"
						printf "LTE interface name is set to %s.\n" "$lteInterfaceName" >> $logFile

						mobileInterfaceName=$lteInterfaceName
						wifiNetworkSelected=0
						lteNetworkSelected=1
						echo "Preffered mobile connection" "$mobileConnectionName" "found!"
						printf "Preffered mobile connection %s found!\n" "$mobileConnectionName" >> $logFile
						break
					fi
				else
					# LTE module is not connected
					if [ "$hmiDetected" -eq 1 ]
					then
						echo "LTE module is not connected. Scanning for a preffered WIFI connection..."
						printf "LTE module is not connected. Scanning for a preffered WIFI connection...\n" >> $logFile
					else
						echo "LTE module is not connected. Process restarting..."
						printf "LTE module is not connected. Process restarting...\n" >> $logFile
					fi

					pref_wifi_con_count=0
					lteNetworkSelected=0
				fi
			else
				echo "Preffered WIFI connection is not available."
				printf "Preffered WIFI connection is not available.\n" >> $logFile
			fi
		else
			# WIFI connection type is selected
			echo "Preffered WIFI connection" "$wifiConnectionName" "found!"
			printf "Preffered WIFI connection %s found!\n" "$wifiConnectionName" >> $logFile
			mobileConnectionName="$wifiConnectionName"
			mobileInterfaceName=$wifiInterfaceName
			wifiNetworkSelected=1
			lteNetworkSelected=0
			break
		fi

		sleep $samplingPeriodSec
	done
}

# Connect to a network via the chosen connection type and start the VPN service
network_connect()
{
	while true
	do
		echo "Attempting connection to" "$mobileConnectionName" "..."
		printf "Attempting connection to %s...\n" "$mobileConnectionName" >> $logFile
		connectionFound=$(nmcli connection | grep -i -o "$mobileConnectionName")

		if [ ! -z "$connectionFound" ]
		then
			nmcli connection up "$mobileConnectionName"

			if [ $? -eq 0 ]
			then
				printf "Connection successful! Synchronizing date and time...\n" >> $logFile
				echo "Connection successful! Synchronizing date and time..."
				timedatectl set-ntp off
				timedatectl set-ntp on
				sleep 10

				nowTime=$(date +"%T")
				nowDate=$(date +"%D")
				echo "Date and time set to " "$nowDate" "$nowTime"
				printf "Date and time set to %s %s\n" $nowDate $nowTime >> $logFile
				printf "============= %s %s STARTING LOG FILE =============\n" $nowDate $nowTime >> $logFile

				echo "Starting the VPN service..."
				printf "%s Starting the VPN service...\n" $nowTime >> $logFile
				service openvpn-autostart start
				break
			else
				echo "Connection failed! Retrying..."
				printf "Connection failed! Retrying...\n" >> $logFile
				nmcli connection down "$mobileConnectionName"
			fi
		fi

		sleep $samplingPeriodSec
	done
}

### MAIN SCRIPT STARTS HERE ###

# SCRIPT PARAMETERS
Disconnected=0
Reconnecting=1
Connected=2
lteManufacturerName="U-Blox"
wifiInterfaceName="wlan0"
lteInterfaceName="usb1"
lteInterfaceNameAlt="usb0"
vpnInterfaceName="tun0"
logFile="/home/network-watchdog.log"
max_net_con_count=15 # Final value of the mobile network connection counter after which a new connection attempt will be made if the mobile network is available
max_vpn_con_count=15 # Final value of the VPN network connection counter after which the VPN service is restarted
max_ip_address_wait_count=10 # Final value of the wait for IP address counter after which the network is disconnected
max_pref_wifi_con_count=10 # Final value of the preffered wifi connection scan counter after which the mobile network is selected
min_wifi_con_name_length=3 # Minimum number of characters in the WIFI connection name
samplingPeriodSec=2 # Time interval in which the network status is re-evaluated, [sec]
lteDeviceName=""
mobileConnectionName=""
mobileInterfaceName=""
networkStatus=0
vpn_con_count=0
net_con_count=0
ip_address_wait_count=0
pref_wifi_con_count=0
wifiNetworkSelected=0
lteNetworkSelected=0
switch_to_RTL_mode_service_started=0
hmiDetected=0
camConnected=0

> $logFile # Clear the log file
printf "============= INITIALIZING NEW LOG FILE =============\n" >> $logFile
printf "Initializing...\n" >> $logFile
echo "Initializing..."

# Initialize script variables
init_variables

# Check if a keyboard is connected
check_keyboard_connected

# Choose connection type (LTE or WIFI) and initialize the connection name and interface
choose_connection_type

# Connect to a network via the chosen connection type and start the VPN service
network_connect

# Main watchdog loop
while true
do
	# Check if a camera is connected
	check_camera_connected

	# Check if the mobile connection state is DOWN
	if [ $wifiNetworkSelected -eq 1 ]
	then
		mobileConnectionState=$(ip address show dev "$mobileInterfaceName" | grep -i -o "state down")
	else
		mobileConnectionState=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "discon")
	fi

	if [ ! -z "$mobileConnectionState" ]
	then
		# Mobile network is disconnected
		nowTime=$(date +"%T")
		echo "Network disconnected!"

		if [ $networkStatus -ne $Disconnected ]
		then
			ip_address_wait_count=0
			printf "%s Network disconnected!\n" $nowTime >> $logFile

			# Stop the openvpn and MAVProxy services
			networkStatus=$Disconnected
			echo "Stopping the VPN service..."
			printf "%s Stopping the VPN service...\n" $nowTime >> $logFile
			service openvpn-autostart stop

			nowTime=$(date +"%T")
			echo "Stopping MAVProxy..."
			printf "%s Stopping MAVProxy...\n" $nowTime >> $logFile
			service mavproxy-autostart stop
			sleep 2
			nowTime=$(date +"%T")
			echo "Switching to LOITER mode..."
			printf "%s Switching to LOITER mode...\n" $nowTime >> $logFile
			/usr/local/bin/chmod_offline.py loiter >> $logFile
			
			nowTime=$(date +"%T")
			echo "Starting switch to RTL service..."
			printf "%s Starting switch to RTL service...\n" $nowTime >> $logFile
			service switch-to-rtl start
			switch_to_RTL_mode_service_started=1

			if [ $camConnected -eq 1 ]
			then
				nowTime=$(date +"%T")
				service gstreamer-autostart stop
				echo "GStreamer stopped."
				printf "%s GStreamer stopped.\n" $nowTime >> $logFile
			fi

			net_con_count=0

			if [ $wifiNetworkSelected -eq 1 ]
			then
				echo "Attempting to switch to LTE connection mode..."
				printf "\tAttempting to switch to LTE connection mode...\n" >> $logFile
			fi
		fi

		# Check if a mobile network is available and connect to it
		net_con_count=$((net_con_count+1))
		if [ $net_con_count -gt $max_net_con_count ]
		then
			nowTime=$(date +"%T")
			echo "Scanning for connection" "$mobileConnectionName" "..."
			printf "%s Scanning for connection %s...\n" $nowTime "$mobileConnectionName" >> $logFile
			connectionFound=$(nmcli connection | grep -i -o "$mobileConnectionName")

			if [ ! -z "$connectionFound" ]
			then
				nowTime=$(date +"%T")
				echo "Connetion" "$mobileConnectionName" "found. Attempting connection..."
				printf "%s Connection %s found. Attempting connection...\n" $nowTime "$mobileConnectionName" >> $logFile
				nmcli connection up "$mobileConnectionName"
				net_con_count=0
				sleep $samplingPeriodSec
				continue
			else
				nowTime=$(date +"%T")
				echo "Connetion" "$mobileConnectionName" "not found. Retrying..."
				printf "%s Connection %s not found. Retrying...\n" $nowTime "$mobileConnectionName" >> $logFile
			fi

			net_con_count=0
		fi

		# If a wifi connection was selected then switch to LTE connection ------------------
		if [ $wifiNetworkSelected -eq 1 ]
		then
			lteConnected=$(lsusb | grep -i "$lteManufacturerName")

			if [ ! -z "$lteConnected" ]
			then
				# LTE module is connected - get the associated device name
				lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
				echo "LTE module" "$lteManufacturerName" "connected. Getting device name..."
				printf "\tLTE module %s connected. Getting device name...\n" "$lteManufacturerName" >> $logFile

				if [ -z "$lteDeviceName" ]
				then
					echo "Failed initializing LTE device name. Process restarting..."
					printf "\tFailed initializing LTE device name. Process restarting...\n" >> $logFile
					sleep $samplingPeriodSec
					continue
				fi

				echo "LTE module" "$lteManufacturerName" "connected. Device name:" "$lteDeviceName"
				printf "\tLTE module %s connected. Device name: %s.\n" "$lteManufacturerName" "$lteDeviceName" >> $logFile

				lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

				if [ ! -z "$lteDeviceUnavailable" ]
				then
					echo "LTE device is not available. Check the SIM card!"
					printf "\tLTE device is not available. Check the SIM card!\n" >> $logFile
				else
					# LTE device is available - get the mobile connection name
					mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
					echo "LTE interface name is set to" "$lteInterfaceName"
					printf "\tLTE interface name is set to %s.\n" "$lteInterfaceName" >> $logFile
					mobileInterfaceName=$lteInterfaceName
					wifiNetworkSelected=0
					lteNetworkSelected=1
					echo "Preffered mobile connection" "$mobileConnectionName" "found!"
					printf "\tPreffered mobile connection %s found!\n" "$mobileConnectionName" >> $logFile
					net_con_count=$max_net_con_count
				fi
			fi
		fi
		# ----------------------------------------------------------------------------------
	else
		# Mobile network is connected - get the IP address
		net_con_count=0
		mobileIpAddress=$(ip address show | grep -A2 $mobileInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

		if [ -z "$mobileIpAddress" ]
		then
			if [ $lteNetworkSelected -eq 1 ]
			then
				# Check the alternative LTE interface name
				mobileIpAddress=$(ip address show | grep -A2 $lteInterfaceNameAlt | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

				if [ -z "$mobileIpAddress" ]
				then
					echo "Waiting for IP address..."
					printf "Waiting for IP address...\n" >> $logFile
					ip_address_wait_count=$((ip_address_wait_count+1))

					if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
					then
						echo "Waiting for IP address timeout. Disconnecting from network..."
						printf "Waiting for IP address timeout. Disconnecting from network..." >> $logFile
						nmcli connection down "$mobileConnectionName"
					fi

					sleep $samplingPeriodSec
					continue
				else
					# Switch the LTE interface name
					mobileInterfaceName=$lteInterfaceNameAlt
					echo "LTE interface name switched from" "$lteInterfaceName" "to" "$lteInterfaceNameAlt"
					printf "\tLTE interface name switched from %s to %s.\n" "$lteInterfaceName" "$lteInterfaceNameAlt" >> $logFile

					# Swap the main and alternative LTE interfaces 
					lteInterfaceNameAlt=$lteInterfaceName
					lteInterfaceName=$mobileInterfaceName
				fi
			else
				echo "Waiting for IP address..."
				printf "Waiting for IP address...\n" >> $logFile
				ip_address_wait_count=$((ip_address_wait_count+1))

				if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
				then
					echo "Waiting for IP address timeout. Disconnecting from network..."
					printf "Waiting for IP address timeout. Disconnecting from network..." >> $logFile
					nmcli connection down "$mobileConnectionName"
				fi

				sleep $samplingPeriodSec
				continue
			fi
		fi

		if [ $networkStatus -eq $Disconnected ]
		then
			nowTime=$(date +"%T")
			echo "Network is now connected!" "Mobile IP:" "$mobileIpAddress"
			echo "Starting the VPN service..."
			printf "%s Network is now connected! Mobile IP: %s\n" $nowTime $mobileIpAddress >> $logFile
			printf "%s Starting the VPN service...\n" $nowTime >> $logFile

			service openvpn-autostart start
			networkStatus=$Reconnecting
			vpn_con_count=0
		fi

		# Get the IP address associated with the VPN network interface
		vpnIpAddress=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

		if [ -z "$vpnIpAddress" ]
		then
			# No VPN IP address found - VPN is still connecting
			if [ $networkStatus -ne $Reconnecting ]
			then
				nowTime=$(date +"%T")

				# The VPN service is restarted when VPN connection is lost without losing mobile network connectivity
				networkStatus=$Reconnecting
				echo "VPN connection lost."
				echo "Stopping MAVProxy..."
				printf "%s VPN connection lost. Stopping MAVProxy...\n" $nowTime >> $logFile

				service mavproxy-autostart stop
				sleep 2
				nowTime=$(date +"%T")
				echo "Switching to LOITER mode..."
				printf "%s Switching to LOITER mode...\n" $nowTime >> $logFile
				/usr/local/bin/chmod_offline.py loiter >> $logFile

				nowTime=$(date +"%T")
				echo "Starting switch to RTL service..."
				printf "%s Starting switch to RTL service...\n" $nowTime >> $logFile
				service switch-to-rtl start
				switch_to_RTL_mode_service_started=1

				if [ $camConnected -eq 1 ]
				then
					nowTime=$(date +"%T")
					service gstreamer-autostart stop
					echo "GStreamer stopped."
					printf "%s GStreamer stopped.\n" $nowTime >> $logFile
				fi

				nowTime=$(date +"%T")
				echo "Restarting the VPN service..."
				printf "%s Restarting the VPN service...\n" $nowTime >> $logFile
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi

			echo "Connecting to VPN..."

			vpn_con_count=$((vpn_con_count+1))
			if [ $vpn_con_count -gt $max_vpn_con_count ]
			then
				nowTime=$(date +"%T")
				echo "Restarting the VPN service..."
				printf "%s Connection timeout. Restarting the VPN service...\n" $nowTime >> $logFile
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi
		else
			# VPN IP address found - get the first two octets and check the values
			oct1=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $1}')
			oct2=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $2}')

			if [ "$oct1" -eq "192" ] && [ "$oct2" -eq "168" ];
			then
				echo "VPN connected!" "VPN IP:" "$vpnIpAddress" "Mobile IP:" "$mobileIpAddress"

				if [ $networkStatus -ne $Connected ]
				then
					nowTime=$(date +"%T")
					printf "%s VPN connected! VPN IP: %s Mobile IP: %s\n" $nowTime $vpnIpAddress $mobileIpAddress >> $logFile
					networkStatus=$Connected
					echo "Starting MAVProxy..."
					printf "%s Starting MAVProxy...\n" $nowTime >> $logFile
					service mavproxy-autostart start

					if [ $? -eq 0 ]
					then
						nowTime=$(date +"%T")
						echo "MAVProxy started."
						printf "%s MAVProxy started.\n" $nowTime >> $logFile

						if [ $switch_to_RTL_mode_service_started -eq 1 ]
						then
							nowTime=$(date +"%T")
							echo "Stopping switch to RTL service."
							printf "%s Stopping switch to RTL service.\n" $nowTime >> $logFile
							service switch-to-rtl stop
							switch_to_RTL_mode_service_started=0
						fi
					else
						nowTime=$(date +"%T")
						echo "MAVProxy starting failed. Restarting..."
						printf "%s MAVProxy starting failed. Restarting...\n" $nowTime >> $logFile
						service mavproxy-autostart stop
						networkStatus=$Reconnecting
					fi
					
					if [ $camConnected -eq 1 ]
					then
						service gstreamer-autostart start
						nowTime=$(date +"%T")
						echo "GStreamer started."
						printf "%s GStreamer started.\n" $nowTime >> $logFile
					fi
				fi
			else
				nowTime=$(date +"%T")
				echo "Error! VPN connected but IP address invalid. Restarting the VPN service..."
				printf "%s Error! VPN connected but IP address invalid. Restarting the VPN service...\n" $nowTime >> $logFile

				# Restart the VPN service
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi
		fi
	fi

	sleep $samplingPeriodSec
done
