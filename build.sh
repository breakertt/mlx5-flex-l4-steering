#!/bin/bash
# Build the patched mlx5_core out of tree: ./build.sh [kernel build dir]
# The kernel tree must contain drivers/net/ethernet/mellanox/{mlx5,mlxfw}.
set -euo pipefail
K=${1:-/lib/modules/$(uname -r)/build}
D=$(dirname "$(readlink -f "$0")")
B=$PWD/build
[ -e "$B" ] && { echo "$B exists; remove it first" >&2; exit 1; }

mkdir -p "$B/drivers/net/ethernet/mellanox" "$B/include/linux"
cp -r "$K/drivers/net/ethernet/mellanox/mlx5" "$K/drivers/net/ethernet/mellanox/mlxfw" \
	"$B/drivers/net/ethernet/mellanox/"
cp -r "$K/include/linux/mlx5" "$B/include/linux/"
for p in "$D"/patches/000[1-9]-*.patch; do
	patch -s -p1 -d "$B" < "$p"
done

# NOSTDINC_FLAGS comes before the kernel's include path, so the patched
# include/linux/mlx5/mlx5_ifc.h is used.
make -C "$K" M="$B/drivers/net/ethernet/mellanox/mlx5/core" \
	NOSTDINC_FLAGS="-nostdinc -I$B/include" modules -j"$(nproc)"
echo "built $B/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko"
