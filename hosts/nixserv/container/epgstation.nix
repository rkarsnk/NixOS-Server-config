# Mirakurun + EPGStation + MariaDB を podman コンテナとしてデプロイする。
#
# 元ネタ: https://github.com/l3tnun/docker-mirakurun-epgstation (v2)
#
# 設定ファイル(mirakurun-conf/, config/)はこのリポジトリ配下(blueprint管理下)に置いている。
# 実体は下記confDirを指す通常のホストパス文字列であり、Nixストアにはコピーされない
# (mirakurunはチャンネルスキャン結果をchannels.ymlへ書き戻すため、書き込み可能な
#  通常ディレクトリである必要がある)。よって編集は都度 `nixos-rebuild switch` しなくても
# 即座にコンテナへ反映される(次回コンテナ再作成時に読み直される)。
#
# 録画データ・サムネイル・DB・ログ等の実行時データはRAID1の/srvdata配下に置く
# (単一ディスク障害でのデータ消失を避けるため。詳細はREADME.mdのストレージ構成を参照)。
#
# epgstation イメージは upstream の debian.Dockerfile を podman でビルドする。
# ffmpeg はこのDockerfileから /usr/local/bin/ffmpeg と
# /usr/local/bin/ffprobe に導入される。apt-get等のネットワーク取得を伴うため、
# Nixビルドではなく起動前のsystemd oneshotサービスでビルドする。
#
# 初回デプロイ前に手動で用意すること:
#   - mirakurun-conf/channels.yml をチューナー環境に合わせて編集
#   - config/config.yml の mariadb接続パスワードをデフォルト("epgstation")から変更
#   - SCR3310等のB-CASカードリーダーにカードを挿しておくこと(arib25用)

{ config, ... }:

let
  confDir = "/opt/etc/nixos-config/hosts/nixserv/container/epgstation";
  srcDir = "/opt/etc/nixos-config/GitHub/docker-mirakurun-epgstation/epgstation";
  imageName = "localhost/epgstation:ffmpeg";
in
{
  # コンテナ名(mirakurun/mariadb-epg/epgstation)でお互いを名前解決できるようにする。
  # PVE-podman が br0 用に作る専用networkとは別物(既定の"podman"network)なので競合しない。
  virtualisation.podman.defaultNetwork.settings.dns_enabled = true;

  systemd.tmpfiles.rules = [
    "d /srvdata/epgstation 0755 root root -"
    "d /srvdata/epgstation/recorded 0755 root root -"
    "d /srvdata/epgstation/thumbnail 0755 root root -"
    "d /srvdata/epgstation/mirakurun-data 0755 root root -"
    "d /srvdata/epgstation/data 0755 root root -"
    "d /srvdata/epgstation/logs 0755 root root -"

    # mirakurunはチャンネルスキャン結果をchannels.ymlへ書き戻すため、
    # コンテナ内プロセスのUID(root/非rootかはイメージ依存で不明)によらず
    # 書き込めるようgit checkout後の権限を上書きする(activation/switch毎に再適用される)。
    # ディレクトリとyamlファイルでルールを分け、yamlファイルに不要な実行ビットが
    # 付かないようにする(Zは再帰的に適用されるためファイルにも0777が付いてしまう)。
    # 所有者は親ディレクトリ(git checkout時にrkarsnk:usersになる)と揃える。
    # root:rootのままだとsystemd-tmpfilesが"unsafe path transition"とみなし、
    # globパターンを使うzルールでの適用がサイレントにスキップされてしまう
    # (モードが0777/0666で全ユーザーに読み書き権限があるため所有者自体は無関係)。
    "d ${confDir}/mirakurun-conf 0777 rkarsnk users -"
    "z ${confDir}/mirakurun-conf/*.yml 0666 rkarsnk users -"
  ];

  systemd.services.epgstation-build-image = {
    description = "ffmpeg入り EPGStation podmanイメージをビルドする";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Delegate = true;
      ExecStart = "${config.virtualisation.podman.package}/bin/podman build -f ${srcDir}/debian.Dockerfile -t ${imageName} ${srcDir}";
    };
  };

  # oci-containersが生成するpodman-epgstation.serviceより先にローカルイメージを作成する。
  systemd.services."podman-epgstation" = {
    after = [ "epgstation-build-image.service" ];
    requires = [ "epgstation-build-image.service" ];
  };

  virtualisation.oci-containers.containers = {
    mirakurun = {
      image = "chinachu/mirakurun";
      autoStart = true;
      capabilities = {
        SYS_ADMIN = true;
        SYS_NICE = true;
      };
      # /dev/dvb: PT3チューナー本体
      # /dev/bus/usb: B-CASカードリーダー(SCR3310等)へのCCID/PC-SCアクセス用。
      # arib25でのスクランブル解除にはコンテナ内蔵のpcscdがこのリーダーを掴む必要がある。
      devices = [ "/dev/dvb:/dev/dvb" "/dev/bus/usb:/dev/bus/usb" ];
      ports = [ "40772:40772" "9229:9229" ];
      volumes = [
        "${confDir}/mirakurun-conf:/app-config"
        "/srvdata/epgstation/mirakurun-data:/app-data"
      ];
      environment.TZ = "Asia/Tokyo";
    };

    mariadb-epg = {
      image = "mariadb:10.5";
      autoStart = true;
      volumes = [ "epgstation-mysql-db:/var/lib/mysql" ];
      environment = {
        MYSQL_USER = "epgstation";
        MYSQL_PASSWORD = "epgstation";
        MYSQL_ROOT_PASSWORD = "epgstation";
        MYSQL_DATABASE = "epgstation";
        TZ = "Asia/Tokyo";
      };
      cmd = [
        "--character-set-server=utf8mb4"
        "--collation-server=utf8mb4_unicode_ci"
        "--performance-schema=false"
        "--expire_logs_days=1"
      ];
    };

    epgstation = {
      image = imageName;
      pull = "never";
      autoStart = true;
      dependsOn = [ "mirakurun" "mariadb-epg" ];
      ports = [ "8888:8888" "8889:8889" ];
      volumes = [
        "${confDir}/config:/app/config"
        "/srvdata/epgstation/data:/app/data"
        "/srvdata/epgstation/logs:/app/logs"
        "/srvdata/epgstation/thumbnail:/app/thumbnail"
        "/srvdata/epgstation/recorded:/app/recorded"
      ];
      environment.TZ = "Asia/Tokyo";
    };
  };
}
