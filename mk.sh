#!/usr/bin/env bash
# Uso: mk.sh <categoria> <NN-slug>  -> crea esqueleto Foundry con foundry.toml compartiendo ../lib
set -e
d=/workspace/solidity-100/$1/$2
mkdir -p $d/src $d/test
cat > $d/foundry.toml <<T
# Configuración de Foundry para el proyecto $2.
# Las dependencias (forge-std y OpenZeppelin v5.1) se comparten en ../lib
# para no duplicarlas en cada proyecto de la categoría "$1".
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["../lib"]
solc_version = "0.8.24"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
remappings = [
  "forge-std/=../lib/forge-std/src/",
  "@openzeppelin/contracts/=../lib/openzeppelin-contracts/contracts/",
]

[fuzz]
runs = 256
T
cat > $d/.gitignore <<T
out/
cache/
T
