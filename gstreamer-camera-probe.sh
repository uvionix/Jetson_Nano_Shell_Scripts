#!/bin/bash

# Setup file
setup_file="/etc/default/gstreamer-setup"

# Get the capture device parameter
capture_dev=$(grep -i capture_dev $setup_file | awk -F'"' '{print $2}')

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

# Start the probing pipeline
/usr/bin/gst-launch-1.0 v4l2src device=$capture_dev ! "video/x-raw, format=(string)$in_pix_fmt, width=(int)$max_res_width, height=(int)$max_res_height" ! queue \
! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$out_pix_fmt" ! nvoverlaysink overlay-x=0 overlay-y=0 overlay-w=$stream_res_width overlay-h=$stream_res_height sync=false
