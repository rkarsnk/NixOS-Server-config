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
        │   └── system.nix                  # ホストOS本体の設定(ブート・ネットワーク・ユーザー等)
        └── container/
            └── proxmox.nix                # Podman上でPVEを動かす services.pvePodman の設定
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
