#!/bin/bash

WORKSPACE=$(cd $(dirname $0);pwd)
IMG_DIR=/tmp/upload bash $WORKSPACE/reset_offline.sh
