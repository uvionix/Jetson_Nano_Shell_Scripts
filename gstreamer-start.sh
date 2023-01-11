#!/bin/bash

# Setup file
setup_file="/etc/default/gstreamer-setup"

# Log file
logFile=$(grep -i "LOG_FILE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')

# Get the vehicle armed/disarmed status
armedDisarmedStatusFile=$(grep -i "VEHICLE_ARMED_DISARMED_STATUS_FILE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')

read_file_wait_cnt=0
while true
do
    vehicle_armed=$(grep -i "armed" $armedDisarmedStatusFile)

    if [ ! -z "$vehicle_armed" ]
    then
        break
    fi

    # If here the file $armedDisarmedStatusFile is currently being written to
    sleep 1
    read_file_wait_cnt=$((read_file_wait_cnt+1))
    if [ $read_file_wait_cnt -gt 5 ]
    then
        printf "\t Wait timeout occured while trying to read the vehicle armed/disarmed status file in gstreamer start service! Assuming ARMED!\n" >> $logFile
        vehicle_armed="ARMED"
        break
    fi
done

if [ ! "$vehicle_armed" != "DISARMED" ]
then
    # Vehicle is disarmed - recording is disabled
    recording_enabled=0
else
    # Vehicle is armed - recording is enabled
    recording_enabled=1
fi

# Get the capture device parameter
capture_dev=$(grep -i capture_dev $setup_file | awk -F'"' '{print $2}')

# Get the input pixel format
in_pix_fmt=$(grep -i in_pix_fmt $setup_file | awk -F'"' '{print $2}')

# Get the output pixel format
out_pix_fmt=$(grep -i out_pix_fmt $setup_file | awk -F'"' '{print $2}')

# Get the streaming enabled flag
streaming_enabled=$(grep -i streaming_enabled $setup_file | awk -F'"' '{print $2}')

# Get the streaming qp range
stream_qp_range=$(grep -i stream_qp_range $setup_file | awk -F'"' '{print $2}')

# Get the stream MTU
stream_mtu=$(grep -i stream_mtu $setup_file | awk -F'"' '{print $2}')

# Get the recording qp range
rec_qp_range=$(grep -i rec_qp_range $setup_file | awk -F'"' '{print $2}')

# Get the stream resolution parameters
stream_res_width=$(grep -i stream_res_w $setup_file | awk -F'"' '{print $2}')
stream_res_height=$(grep -i stream_res_h $setup_file | awk -F'"' '{print $2}')

# Get the display resolution parameters
disp_res_width=$(grep -i disp_res_w $setup_file | awk -F'"' '{print $2}')
disp_res_height=$(grep -i disp_res_h $setup_file | awk -F'"' '{print $2}')

# Get the record resolution parameters
rec_res_width=$(grep -i rec_res_w $setup_file | awk -F'"' '{print $2}')
rec_res_height=$(grep -i rec_res_h $setup_file | awk -F'"' '{print $2}')

# Get the split file duration parameter
rec_split_duration=$(grep -i rec_split_dur_ns $setup_file | awk -F'"' '{print $2}')

# Get the split file size parameter
rec_split_file_size_bytes=$(grep -i rec_file_size_bytes $setup_file | awk -F'"' '{print $2}')

# Get the reserve storage space parameter
free_space_reserve_bytes=$(grep -i free_space_rsrv_bytes $setup_file | awk -F'"' '{print $2}')

# Get the host IP address
host_ip=$(grep -i host_ip $setup_file | awk -F'"' '{print $2}')

# Get the host port
host_port=$(grep -i host_port $setup_file | awk -F'"' '{print $2}')

# Calculate the max resolution parameters
if [ $disp_res_height -gt $rec_res_height ]
then
	max_res_width=$disp_res_width
	max_res_height=$disp_res_height
else
	max_res_width=$rec_res_width
	max_res_height=$rec_res_height
fi

# Stream resolution cannot be greater than the max resolution
if [ $stream_res_height -gt $max_res_height ]
then
    stream_res_width=$max_res_width
    stream_res_height=$max_res_height
fi

# Get a username
usrname=$(getent passwd | awk -F: "{if (\$3 >= $(awk '/^UID_MIN/ {print $2}' /etc/login.defs) && \$3 <= $(awk '/^UID_MAX/ {print $2}' /etc/login.defs)) print \$1}" | head -1)

if [ $recording_enabled -eq 1 ]
then
    # Get the storage device - first check for inserted media devices
    media_devices_count=$(df --block-size=1K --output='source','avail','target' | grep -c "/dev/sd")
    if [ $media_devices_count -eq 1 ]
    then
        # Media device detected - initialize the storage device and the recording root directory
        media_device_detected=1
        storage_device=$(df --block-size=1K --output='source','avail','target' | grep "/dev/sd" | awk -F' ' {'print $1'})
        rec_root_dir=$(df --block-size=1K --output='source','avail','target' | grep "/dev/sd" | awk -F' ' {'print $3'})
    else
        if [ $media_devices_count -gt 1 ]
        then
            printf "\t Multiple media devices found which is not supported!\n" >> $logFile
        fi
        media_device_detected=0
    fi

    if [ $media_device_detected -eq 0 ]
    then
        printf "\t Internal storage will be used for video recording.\n" >> $logFile
        storage_device=$(df --block-size=1K --output='source','avail','target' | grep -w "/" | awk -F' ' {'print $1'})
        rec_root_dir="/home/$usrname"
    fi

    printf "\t Storage device initialized to %s\n" $storage_device >> $logFile

    # Get the available disk space in kilobytes and recalculate it in bytes
    free_space_kB=$(df --block-size=1K --output='source','avail' | grep $storage_device | awk -F' ' {'print $2'})
    free_space_bytes=$((free_space_kB*1024-$free_space_reserve_bytes))

    # Calculate the max number of files that can be recorded
    if [ $free_space_bytes -le 0 ]
    then
        max_files=0
    else
        printf "\t Free space available for video recording = %d bytes\n" $free_space_bytes >> $logFile
        max_files=$((free_space_bytes/$rec_split_file_size_bytes))
    fi
else
    max_files=0
fi

if [ $recording_enabled -eq 1 ] && [ $max_files -gt 1 ];
then
    printf "\t Maximum number of files that can be recorded = %d\n" $max_files >> $logFile

    # Get the current date
    nowDate=$(date +"%b-%d-%y")

    # Create the Videos directory if it does not exist
    mkdir -p $rec_root_dir/Videos
    chown $usrname $rec_root_dir/Videos

    # Create the xoss directory if it does not exist
    mkdir -p $rec_root_dir/Videos/xoss
    chown $usrname $rec_root_dir/Videos/xoss

    # Create a directory for the current date if it does not exist
    mkdir -p $rec_root_dir/Videos/xoss/$nowDate
    chown $usrname $rec_root_dir/Videos/xoss/$nowDate

    # Create a subdirectory for the current session
    sub_dir_name=1
    dircontents=$(ls $rec_root_dir/Videos/xoss/$nowDate/)

    if [ -z "$dircontents" ]
    then
        # Root date directory is empty - create a subdirectory for the first session
        recdir="$rec_root_dir/Videos/xoss/$nowDate/$sub_dir_name"
        mkdir -p $recdir
    else
        # Root date directory is not empty - get a subdirectory name for the current session
        while true
        do
            dir_exists=$(ls $rec_root_dir/Videos/xoss/$nowDate/ | grep $sub_dir_name)

            if [ -z "$dir_exists" ]
            then
                recdir="$rec_root_dir/Videos/xoss/$nowDate/$sub_dir_name"
                mkdir -p $recdir
                break
            else
                sub_dir_name=$((sub_dir_name+1))
            fi
        done
    fi

    chown $usrname $recdir

    # Construct a filename for the video recording
    filename="S$sub_dir_name-V%d"

    # Start the gstreamer pipeline
    if [ $streaming_enabled -eq 1 ]
    then
        printf "\t Starting pipeline for streaming, recording and visualization...\n" >> $logFile
        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$rec_qp_range ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
    else
        printf "\t Streaming is disabled. Starting pipeline for recording and visualization...\n" >> $logFile
        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$rec_qp_range ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
    fi

    # The next pipeline specifies the bitrate and the framerate in the recording branch
    #/usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
    #! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
    #t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt, framerate=(fraction)65/1" ! nvv4l2h264enc bitrate=100000000 ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
    #t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
else
    if [ $recording_enabled -eq 1 ]
    then
        printf "\t Not enough disk space available for recording!\n" >> $logFile
    else
        printf "\t Recording is disabled while the vehicle is disarmed!\n" >> $logFile
    fi
    
    if [ $streaming_enabled -eq 1 ]
    then
        printf "\t Starting pipeline for streaming and visualization...\n" >> $logFile
        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
    else
        printf "\t Streaming is disabled. Starting pipeline for visualization...\n" >> $logFile
        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" \
        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
    fi
fi
