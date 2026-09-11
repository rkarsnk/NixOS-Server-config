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
#
# commute2invoice自体はデバイスアクセス等の特権を必要としないアプリ(Go+SQLite+PDF生成)
# なので、mirakurun/PVEのような他コンテナと違いrootful podmanで動かす理由がない。
# 専用の非rootシステムユーザー(commute2invoice)を作り、rootless podmanで動かす。
# rootless podmanはイメージストアがユーザーごとに独立するため、ビルドサービスも
# 同じユーザーで実行する必要がある(rootでbuildしてもrootlessコンテナからは見えない)。

{ config, ... }:

let
  srcDir = "/opt/etc/nixos-config/GitHub/commute2invoice";
  imageName = "commute2invoice:local";
  runUser = "commute2invoice";
in
{
  users.groups.${runUser} = { };
  users.users.${runUser} = {
    isSystemUser = true;
    group = runUser;
    uid = 400;
    # isSystemUser=trueだとデフォルトでhomeが/var/empty(書き込み不可)になり、
    # rootless podmanのストレージ($HOME/.local/share/containers)を置けない。
    home = "/var/lib/${runUser}";
    createHome = true;
    # lingerがないとログインセッションなしにuser@<uid>.service(rootless podmanが依存する
    # systemdユーザーマネージャ)が起動せず、コンテナがブート時に自動起動しない。
    linger = true;
    # rootless podmanのユーザー名前空間マッピングに必要なsubuid/subgidを自動割り当てする
    # (isSystemUser=trueの場合はデフォルトで割り当てられないため明示的に有効化)。
    autoSubUidGidRange = true;
  };

  systemd.tmpfiles.rules = [
    # 既存データ(以前rootfulで動かしていた際にroot所有で作られたDBファイル含む)も
    # 所有者を書き換えるため再帰的な Z を使う。
    "Z /srvdata/commute2invoice 0755 ${runUser} ${runUser} -"
  ];

  systemd.services.commute2invoice-build-image = {
    description = "commute2invoice のpodmanイメージをソースからビルドする(${runUser}ユーザーのrootless podman)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.HOME = config.users.users.${runUser}.home;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = runUser;
      # podman build中のRUNステップ(apt-get等)がcrunでコンテナを作る際、systemdの
      # cgroupドライバー経由でtransient scopeの作成をsd-bus越しに要求する。
      # このサービス自体にcgroup委譲(Delegate)がないと"sd-bus call: Permission denied"で
      # 失敗する。oci-containersが生成するpodman-commute2invoice.serviceには
      # モジュールが自動でDelegate=trueを付けているが、このoneshotサービスは
      # 手書きのため明示的に必要。
      Delegate = true;
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
    podman.user = runUser;
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
