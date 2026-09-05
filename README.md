# NixOS-Server-config

NixOS + [numtide/blueprint](https://github.com/numtide/blueprint) によるサーバー `nixserv` の構成管理リポジトリ。

[PVE-podman](https://github.com/rkarsnk/PVE-podman) を使い、Podmanコンテナ上でProxmox VE(PVE)を稼働させています。

## 構成図

ホストOS・コンテナ・Proxmox VE・その先の仮想マシンやLXCコンテナがそれぞれ独立したLAN上のIPを持つ階層構成です
(NATを介さず、ホスト側のLinuxブリッジ `br0` を通じてLANに直接ぶら下がります)。

![nixservの構成図](docs/architecture.svg)

- **ホストOS(nixserv)**: 物理NIC `enp1s0` をLinuxブリッジ `br0` のポートにし(`enp1s0` 自体はIPを持たない)、ホスト自身の固定IP `192.168.24.50/24` は `br0` に割り当てる。
- **コンテナ(Podman)**: `br0` にPodmanの `bridge` ネットワーク(`mode=unmanaged`、`br0` の新規作成・NAT・ポートフォワードはPodman側で行わない)で接続する。コンテナの `eth0`(veth)自体はIPを持たない。PVE本体はこのコンテナの中で動く。
- **Proxmox VE**: コンテナ内の `vmbr0` に `192.168.24.51/24` を割り当ててさらにLANへブリッジし、その配下で動く各VM・LXCコンテナ(例: `192.168.24.99`)もLAN上に個別のIPを持てる。

以前はコンテナの接続にmacvlanを使っていたが、macvlan(既定のbridgeモード)は宛先MACアドレスをmacvlan子インターフェース自身のMACとハッシュ照合するだけで転送するため、コンテナ内 `vmbr0` がさらにブリッジする配下のVM/LXCのMAC宛フレームがLANとの間で正しく転送されない問題があった。本物のLinuxブリッジにはこの制約がないため、`br0` 方式に変更した(詳細は [PVE-podman](https://github.com/rkarsnk/PVE-podman) の `doc/SPEC.md` 13節を参照)。

## ディレクトリ構成

blueprintの規約により、`hosts/<ホスト名>/configuration.nix` が自動的に `nixosConfigurations.<ホスト名>` として公開されます。`flake.nix` 側での手動配線は不要です。

```
.
├── flake.nix                             # inputs 定義 + blueprint 呼び出しのみ
├── Makefile                              # nixos-rebuild のラッパー
└── hosts/
    └── nixserv/
        ├── configuration.nix             # imports のみのエントリーポイント
        ├── os/
        │   ├── hardware-configuration.nix  # nixos-generate-config によるハードウェア検出結果
        │   ├── system.nix                  # ホストOS本体の設定(ブート・ネットワーク・ユーザー等)
        │   └── storage.nix                 # /srvdata (btrfs raid1) のマウント設定
        └── container/
            ├── proxmox.nix                # Podman上でPVEを動かす services.pvePodman の設定
            ├── epgstation.nix             # Mirakurun+EPGStation+MariaDBのpodmanコンテナ設定
            └── commute2invoice.nix        # commute2invoice(交通費精算アプリ)のpodmanコンテナ設定
```

## flake inputs

| input | 用途 |
|---|---|
| `nixpkgs` | `nixos-26.05` チャンネル |
| `blueprint` | ディレクトリ構成から flake outputs を自動生成 |
| `pve-podman` | Podman上でProxmox VEを動かすNixOSモジュール |

## 使い方

```sh
make build   # nixos-rebuild build
make test    # nixos-rebuild test
make switch  # nixos-rebuild switch(本適用)
```

いずれも内部で `sudo nixos-rebuild <action> --flake .#nixserv` を実行します。


## ストレージ構成
### raid1ボリューム
`/srvdata` はバックアップ/NAS用に、2TBのHDD `/dev/sda` と `/dev/sdb` を btrfs raid1(データ・メタデータ共にraid1)でミラーリングしたボリュームです。

**このRAID1ボリュームの作成は意図的にNix化しておらず、事前に手動で構築したものを [storage.nix](hosts/nixserv/os/storage.nix) からUUID指定でマウントしているだけです。** `nixos-rebuild switch` の適用がディスクのフォーマット処理を含んでしまうと、デバイス名(`/dev/sda`/`/dev/sdb`)は再起動間で入れ替わり得ることもあり、既存データを誤って消去するリスクがあります。このホストはSSH専用でロールバック手段がないため、リスクとメリットを比較して手動運用のままとしています。

再構築(ディスク交換など)が必要な場合は、以下を手動で実行してから `storage.nix` の `device` を新しいUUID(`blkid /dev/sda` 等で確認)に更新してください。

```sh
sudo mkfs.btrfs -L srvdata -d raid1 -m raid1 /dev/sda /dev/sdb
```

### 片側HDD障害時の対処

**1. 障害の検知**

```sh
sudo btrfs device stats /srvdata      # read/write/corruption/generation の各エラーカウンタを確認
sudo btrfs filesystem show /srvdata   # missing 表示のデバイスがないか確認
sudo smartctl -a /dev/sdX             # ハードウェア障害の切り分け(SMART情報)
```

**2. 片方のディスクが完全に認識されない場合の緊急マウント**

正常時はUUID指定の通常マウントで問題ないが、片方が脱落した状態で再起動するとマウントに失敗することがあるため、その場合は `degraded` オプションを付けてマウントする。

```sh
sudo mount -o degraded,compress=zstd,noatime /dev/disk/by-uuid/<storage.nixのUUID> /srvdata
```

**3. 故障ディスクの交換**

物理的にHDDを交換した後、生きている側のデバイスから新しいディスクへ直接データを再構築する(`btrfs device add`+`remove`より高速・安全)。

```sh
sudo btrfs filesystem show /srvdata          # missingになっているdevidを確認
sudo btrfs replace start <devid> /dev/sdX /srvdata
sudo btrfs replace status /srvdata           # 進捗確認(完了までは時間がかかる)
sudo btrfs device stats -z /srvdata          # 完了後、エラーカウンタをリセット
```

`btrfs replace` はファイルシステムのUUIDを変更しないため、交換後も `storage.nix` の `device` 指定(UUID)はそのまま変更不要。degradedマウントしていた場合は通常マウントに戻して問題なく起動できることを確認する。

**4. (任意)定期的な整合性チェック**

`sudo btrfs scrub start /srvdata` を定期実行しておくと、静かなデータ破損(silent corruption)を早期発見できる。進捗は `sudo btrfs scrub status /srvdata` で確認。

