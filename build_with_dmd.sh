#!/bin/bash
dmd bob_config.d -O -of${HOME}/bin/bob-config
dmd process.d bob.d -O -of${HOME}/bin/bob
