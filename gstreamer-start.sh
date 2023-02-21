#!/bin/bash

# Setup file
setup_file="/etc/default/gstreamer-setup"

# Log file
logFile=$(grep -i log_file $setup_file | awk -F'"' '{print $2}')
> $logFile

# Commands file
cmdFile=$(grep -i cmd_file $setup_file | awk -F'"' '{print $2}')
> $cmdFile

printf "============= INITIALIZING NEW LOG FILE =============\n" >> $logFile
printf "Initializing camera service...\n" >> $logFile

# Get the current date
# nowDate=$(date +"%b-%d-%y")

# Get the recording destination device parameter
rec_destination_dev=$(grep -i rec_destination_dev $setup_file | awk -F'"' '{print $2}')

# Get a username
usrname=$(getent passwd | awk -F: "{if (\$3 >= $(awk '/^UID_MIN/ {print $2}' /etc/login.defs) && \$3 <= $(awk '/^UID_MAX/ {print $2}' /etc/login.defs)) print \$1}" | head -1)

# Get the storage device - first check for inserted media devices
printf "Detecting storage device...\n" >> $logFile

media_devices_count=$(df --block-size=1K --output='source','avail','target' | grep -c "$rec_destination_dev")
if [ $media_devices_count -eq 1 ]
then
    # Media device detected - initialize the storage device and the recording root directory
    printf "External media device detected!\n" >> $logFile
    media_device_detected=1
    storage_device=$(df --block-size=1K --output='source','avail','target' | grep "$rec_destination_dev" | awk -F' ' {'print $1'})
    rec_root_dir=$(df --block-size=1K --output='source','avail','target' | grep "$rec_destination_dev" | awk -F' ' {'print $3'})
else
    if [ $media_devices_count -gt 1 ]
    then
        printf "Multiple external media devices found which is not supported!\n" >> $logFile
    fi
    media_device_detected=0
fi

if [ $media_device_detected -eq 0 ]
then
    printf "Internal storage will be used for video recording.\n" >> $logFile
    storage_device=$(df --block-size=1K --output='source','avail','target' | grep -w "/" | awk -F' ' {'print $1'})
    rec_root_dir="/home/$usrname"
fi

printf "Storage device initialized to %s\n" $storage_device >> $logFile
printf "Creating recording destination directory...\n" >> $logFile

# Create the Videos directory if it does not exist
mkdir -p $rec_root_dir/Videos
chown $usrname $rec_root_dir/Videos

# Create the xoss directory if it does not exist
mkdir -p $rec_root_dir/Videos/xoss
chown $usrname $rec_root_dir/Videos/xoss

# Create a subdirectory for the current session
sub_dir_name=1
dircontents=$(ls $rec_root_dir/Videos/xoss/)

if [ -z "$dircontents" ]
then
    # Root directory is empty - create a subdirectory for the first session
    recdir="$rec_root_dir/Videos/xoss/$sub_dir_name/"
    mkdir -p $recdir
else
    # Root directory is not empty - get a subdirectory name for the current session
    while true
    do
        dir_exists=$(ls $rec_root_dir/Videos/xoss/ | grep $sub_dir_name)
        if [ -z "$dir_exists" ]
        then
            recdir="$rec_root_dir/Videos/xoss/$sub_dir_name/"
            mkdir -p $recdir
            break
        else
            sub_dir_name=$((sub_dir_name+1))
        fi
    done
fi

chown $usrname $recdir
printf "Recording directory set to $recdir\n" >> $logFile

# Add leading zeros to the subdirectory name
# sub_dir_name=$(printf %03d $sub_dir_name)

# Start the camera
printf "Starting camera service...\n" >> $logFile
/usr/local/bin/gst-start-camera $recdir $setup_file 0<$cmdFile 1>>$logFile 2>>$logFile

if [ $? -eq 0 ]
then
    printf "Camera service stopped successfully!\n" >> $logFile
    exit 0
else
    # Camera service exited with error - remove the created recording directory if it is empty
    dircontents=$(ls $recdir)
    if [ -z "$dircontents" ]
    then
        rm -d $recdir
    fi

    printf "Camera service exited with error! Restarting...\n" >> $logFile
    exit 1
fi

#    if [ $streaming_enabled -eq 1 ]
#    then
#        printf "\t Starting pipeline for streaming, recording and visualization...\n" >> $logFile
#        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
#        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
#        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$rec_qp_range ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
#        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=24 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
#    else
#        printf "\t Streaming is disabled. Starting pipeline for recording and visualization...\n" >> $logFile
#        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
#        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$rec_qp_range ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
#        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=24 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
#    fi
#
#    # The next pipeline specifies the bitrate and the framerate in the recording branch
#    #/usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
#    #! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
#    #t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt, framerate=(fraction)65/1" ! nvv4l2h264enc bitrate=100000000 ! h264parse ! splitmuxsink location=$recdir/$filename.mp4 max-size-bytes=$rec_split_file_size_bytes max-files=$max_files muxer=mp4mux \
#    #t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=24 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
#else
#    if [ $recording_enabled -eq 1 ]
#    then
#        printf "\t Not enough disk space available for recording!\n" >> $logFile
#    else
#        printf "\t Recording is disabled while the vehicle is disarmed!\n" >> $logFile
#    fi
#    
#    if [ $streaming_enabled -eq 1 ]
#    then
#        printf "\t Starting pipeline for streaming and visualization...\n" >> $logFile
#        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t \
#        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false \
#        t. ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=24 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
#    else
#        printf "\t Streaming is disabled. Starting pipeline for visualization...\n" >> $logFile
#        /usr/bin/gst-launch-1.0 -e v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" \
#        ! queue ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=24 overlay-w=$disp_res_width overlay-h=$disp_res_height sync=false
#    fi
#fi

