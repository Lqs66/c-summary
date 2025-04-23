#!/bin/bash

INFER=$INFER_HOME/bin/infer
GLOBAL_COLLECTOR=$INFER_HOME/src/_build/opt/GlobalCollector.exe
POST_GLOBAL=$INFER_HOME/src/_build/opt/PostGlobal.exe
JAVA_GENERATOR=$INFER_HOME/src/_build/default/JavaGenerator.exe

echo "Capturing..."
$INFER_HOME/bin/infer --compilation-database ./fc_compile_commands.json

echo "Performing preanalysis for alias relations..."
$INFER analyze -P --pp-only

echo "Performing preanalysis for the global environment..."
$INFER analyze -P --ssp-only
$GLOBAL_COLLECTOR

echo "Generating semantic summary for $files..."
$INFER analyze -P --ss-only

echo "Post-processing for Global variables..."
$POST_GLOBAL

echo "Transforming to Java methods"
$JAVA_GENERATOR