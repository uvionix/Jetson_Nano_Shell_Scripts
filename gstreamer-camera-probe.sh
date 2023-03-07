#!/bin/bash

# Get the stream resolution parameters
stream_res_width=$STREAM_RES_W
stream_res_height=$STREAM_RES_H

# Get the display resolution parameters
disp_res_width=$OVERLAY_RES_W
disp_res_height=$OVERLAY_RES_H

# Get the record resolution parameters
rec_res_width=$REC_RES_W
rec_res_height=$REC_RES_H

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

# Start the probing pipeline
/usr/bin/gst-launch-1.0 v4l2src device=$CAPTURE_DEV ! "video/x-raw, format=(string)$IN_PIX_FMT, width=(int)$max_res_width, height=(int)$max_res_height" ! queue \
! nvvidconv ! "video/x-raw(memory:NVMM), width=(int)$stream_res_width, height=(int)$stream_res_height, format=(string)$OUT_PIX_FMT" ! nvoverlaysink overlay-x=$OVERLAY_POS_X overlay-y=$OVERLAY_POS_Y overlay-w=$stream_res_width overlay-h=$stream_res_height sync=false
