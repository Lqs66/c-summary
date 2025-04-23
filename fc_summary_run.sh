#!/bin/bash

INFER=$INFER_HOME/bin/infer
GLOBAL_COLLECTOR=$INFER_HOME/src/_build/opt/GlobalCollector.exe
POST_GLOBAL=$INFER_HOME/src/_build/opt/PostGlobal.exe
JAVA_GENERATOR=$INFER_HOME/src/_build/default/JavaGenerator.exe

CAPTURE_FLAG=false
for arg in "$@"; do
  if [ "$arg" = "--capture" ]; then
    CAPTURE_FLAG=true
    break
  fi
done

if [ "$CAPTURE_FLAG" = true ]; then
  echo "Capturing..."
  $INFER_HOME/bin/infer --compilation-database ./fc_compile_commands.json
else
  echo "Skipping capture phase..."
fi

echo "Performing preanalysis for alias relations..."
$INFER analyze -P --pp-only --keep-going

echo "Performing preanalysis for the global environment..."
$INFER analyze -P --ssp-only --keep-going
$GLOBAL_COLLECTOR

echo "Generating semantic summary for $files..."
$INFER analyze -P --ss-only --keep-going

echo "Post-processing for Global variables..."
$POST_GLOBAL

echo "Transforming to Java methods"
$JAVA_GENERATOR