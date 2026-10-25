#!/usr/bin/env bash
# Crea el esqueleto de un proyecto Foundry (uso: ./new.sh <dir_categoria> NN-slug)
# Las dependencias (forge-std y OpenZeppelin 5.1) se comparten en <categoria>/lib
# para no duplicarlas en cada proyecto; cada proyecto sigue siendo independiente
# (tiene su propio foundry.toml, src/, test/ y README.md).
set -e
d="$1/$2"; mkdir -p "$d/src" "$d/test"
cat > "$d/foundry.toml" <<'T'
# Configuración de Foundry para este proyecto.
# Las dependencias (forge-std y OpenZeppelin 5.1) se comparten en ../lib.
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
printf 'out/\ncache/\nbroadcast/\n' > "$d/.gitignore"
