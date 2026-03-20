#!/bin/bash
INTERFACE=$1
VIP=$2
ip addr add $VIP/24 dev $INTERFACE
logger "UCARP: VIP $VIP added on $INTERFACE"
