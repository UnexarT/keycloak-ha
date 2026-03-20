#!/bin/bash
INTERFACE=$1
VIP=$2
ip addr del $VIP/24 dev $INTERFACE 2>/dev/null
logger "UCARP: VIP $VIP removed from $INTERFACE"
