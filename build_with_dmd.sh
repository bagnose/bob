#!/bin/bash
dmd bob_config.d -O -ofbob-config
dmd process.d bob.d -O -ofbob
