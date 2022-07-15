#!/bin/bash

# Setup file
setup_file="/etc/default/gstreamer-setup"

# Get the capture device parameter
capture_dev=$(grep -i dev $setup_file | awk -F'"' '{print $2}')

# Get the input pixel format
in_pix_fmt=$(grep -i in_pix_fmt $setup_file | awk -F'"' '{print $2}')

# Get the output pixel format
out_pix_fmt=$(grep -i out_pix_fmt $setup_file | awk -F'"' '{print $2}')

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
rec_split_duration=$(grep -i rec_split_dur $setup_file | awk -F'"' '{print $2}')

# Get the host IP address
host_ip=$(grep -i host_ip $setup_file | awk -F'"' '{print $2}')

# Get the host port
host_port=$(grep -i host_port $setup_file | awk -F'"' '{print $2}')

# Get the max resolution parameters
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
usr=$(getent passwd | awk -F: "{if (\$3 >= $(awk '/^UID_MIN/ {print $2}' /etc/login.defs) && \$3 <= $(awk '/^UID_MAX/ {print $2}' /etc/login.defs)) print \$1}" | head -1)

# Get the current date
nowDate=$(date +"%b-%d-%y")

# Create the Videos directory if it does not exist
mkdir /home/$usr/Videos
chown $usr /home/$usr/Videos

# Create the xoss directory if it does not exist
mkdir /home/$usr/Videos/xoss
chown $usr /home/$usr/Videos/xoss

# Create a directory for the current date if it does not exist
mkdir /home/$usr/Videos/xoss/$nowDate
chown $usr /home/$usr/Videos/xoss/$nowDate

# Create a subdirectory for the current session
sub_dir_name=1
dircontents=$(ls /home/$usr/Videos/xoss/$nowDate/)

if [ -z "$dircontents" ]
then
    # Root date directory is empty - create a subdirectory for the first session
    recdir="/home/$usr/Videos/xoss/$nowDate/$sub_dir_name"
    mkdir $recdir
else
    # Root date directory is not empty - get a subdirectory name for the current session
    while true
    do
        dir_exists=$(ls /home/$usr/Videos/xoss/$nowDate/ | grep $sub_dir_name)

        if [ -z "$dir_exists" ]
        then
            recdir="/home/$usr/Videos/xoss/$nowDate/$sub_dir_name"
            mkdir $recdir
            break
        else
            sub_dir_name=$((sub_dir_name+1))
        fi
    done
fi

chown $usr $recdir

# Construct a filename for the video recording
filename="S$sub_dir_name-V%d"

# Start the gstreamer pipeline
/usr/bin/gst-launch-1.0 v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! tee name=t ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvv4l2h264enc qp-range=$stream_qp_range ! rtph264pay mtu=$stream_mtu config-interval=-1 ! udpsink clients=$host_ip:$host_port sync=false t. ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$rec_res_width, height=(int)$rec_res_height, format=(string)$out_pix_fmt" ! queue ! nvv4l2h264enc qp-range=$rec_qp_range ! h264parse ! splitmuxsink location=$recdir/$filename.mkv max-size-time=$rec_split_duration muxer=matroskamux t. ! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$disp_res_width, height=(int)$disp_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink sync=false
