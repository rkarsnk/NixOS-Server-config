# commute2invoice(交通費精算Webアプリ)をpodmanコンテナとしてデプロイする。
#
# https://github.com/rkarsnk/commute2invoice を GitHub/commute2invoice に
# クローンしたもの(独立したgitリポジトリであり、nixos-config管理下には置かない。
# 更新は `git -C GitHub/commute2invoice pull` で行う)。
#
# 公開イメージが存在しないため、epgstation.nixのl3tnun/epgstationのようにレジストリから
# pullすることができない。Dockerfileはapt-get/go mod downloadでネットワーク取得するため
# Nixのビルドサンドボックス内(pkgs.dockerTools等)では再現性がなく実行できない
# (epgstation.nixのコメント参照)。よってsystemdのoneshotサービスで通常の
# `podman build` を実行し、ローカルにイメージを作る。
#
# ソース更新後にイメージを再ビルドする場合は手動で以下を実行すること
# (nixos-rebuild switchだけではソースの変更を検知できないため):
#   git -C /opt/etc/nixos-config/GitHub/commute2invoice pull
#   sudo systemctl restart commute2invoice-build-image.service
#   sudo systemctl restart podman-commute2invoice.service
#
# DBファイル(SQLite)はRAID1の/srvdata配下に永続化する
# (単一ディスク障害でのデータ消失を避けるため)。

{ config, ... }:

let
  srcDir = "/opt/etc/nixos-config/GitHub/commute2invoice";
  imageName = "commute2invoice:local";
in
{
  systemd.tmpfiles.rules = [
    "d /srvdata/commute2invoice 0755 root root -"
  ];

  systemd.services.commute2invoice-build-image = {
    description = "commute2invoice のpodmanイメージをソースからビルドする";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.virtualisation.podman.package}/bin/podman build -t ${imageName} ${srcDir}";
    };
  };

  # oci-containersが生成するpodman-commute2invoice.serviceより先にイメージビルドを終わらせる。
  systemd.services."podman-commute2invoice" = {
    after = [ "commute2invoice-build-image.service" ];
    requires = [ "commute2invoice-build-image.service" ];
  };

  virtualisation.oci-containers.containers.commute2invoice = {
    image = imageName;
    autoStart = true;
    ports = [ "8080:8080" ];
    volumes = [ "/srvdata/commute2invoice:/data" ];
    environment = {
      GIN_MODE = "release";
      PORT = "8080";
      SERVER_HOST = "0.0.0.0";
      DB_PATH = "/data/commute2invoice.db";
      LOG_LEVEL = "info";
      TZ = "Asia/Tokyo";
    };
  };
}
