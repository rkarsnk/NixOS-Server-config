# sda/sdb (2TB HDD x2) を btrfs raid1 でミラーリングし、
# バックアップ/NAS用ストレージとしてマウントする。
#
# 事前に手動で以下を実行してミラーを作成し、
# `sudo blkid /dev/sda` で得られたUUIDを device に設定すること。
#
#   sudo mkfs.btrfs -L srvdata -d raid1 -m raid1 /dev/sda /dev/sdb

{ ... }:

{
  fileSystems."/srvdata" = {
    device = "/dev/disk/by-uuid/0e462ec0-7e1b-4d08-83f8-be3e12bc6568";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" ];
  };
}
