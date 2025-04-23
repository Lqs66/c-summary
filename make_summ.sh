#!/bin/bash

make
cd infer/src
eval $(opam env)
dune build GlobalCollector.exe
dune build PostGlobal.exe
dune build JavaGenerator.exe
cd -
