# ---------------------------------------------------------------------------
# Custom "ubootmod" variants (openwrt-25.12 port, from the 24.10 definitions)
# Keep the vendor unbrickable U-Boot in the fip partition; classic
# kernel/rootfs/rootfs_data UBI layout (no OpenWrt U-Boot / fit volume).
# ---------------------------------------------------------------------------

define Device/qihoo_360t7-ubootmod
  DEVICE_VENDOR := Qihoo
  DEVICE_MODEL := 360T7
  DEVICE_VARIANT := (custom U-Boot layout)
  DEVICE_DTS := mt7981b-qihoo-360t7-ubootmod
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  SUPPORTED_DEVICES += qihoo,360t7-ubootmod qihoo,360-t7-ubootmod
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 65536k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  KERNEL = kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS = kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd
endef
TARGET_DEVICES += qihoo_360t7-ubootmod

# --- end ubootmod overlay (auto-appended by scripts/build.sh) ---
