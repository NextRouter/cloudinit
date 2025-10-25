# NextRouter Cloud-Init Setup

Proxmox で NextRouter の VM 環境を自動構築するためのスクリプト集です。

## 概要

このプロジェクトは、以下の VM を自動的に作成します：

- **wan0** (VMID 1000): NAT Gateway - net0 から net1 へのパススルー
- **wan1** (VMID 1001): NAT Gateway - net0 から net1 へのパススルー
- **router** (VMID 1002): メインルーター (8 CPU, 8GB RAM, 32GB Disk)
- **lan0** (VMID 1003): LAN クライアント
- **lan1** (VMID 1004): LAN クライアント
- **lan2** (VMID 1005): LAN クライアント

### ネットワーク構成

```
[External Network]
       |
       | (vmbr00/vmbr01 - DHCP)
       |
   [wan0/wan1]
       |
       | (vmbr10/vmbr11 - 172.0.10.0/24, 172.0.11.0/24)
       |
    [router]
       |
       | (vmbr12 - 172.0.12.0/24)
       |
  [lan0/lan1/lan2]
```

## 前提条件

- Proxmox VE 7.x 以降
- SSH キーペア（`nextrouter.pub`ファイル）
- 十分なストレージ容量
- インターネット接続

## セットアップ手順

### 1. SSH キーの準備

```bash
# SSHキーが無い場合は生成
ssh-keygen -t rsa -b 4096 -f ~/.ssh/nextrouter -C "nextrouter"

# 公開鍵をスクリプトと同じディレクトリにコピー
cp ~/.ssh/nextrouter.pub ./nextrouter.pub
```

### 2. スクリプトの実行

```bash
# Proxmoxホストにファイルをコピー
scp create_vms.sh nextrouter.pub root@proxmox-host:/root/

# Proxmoxホストにログイン
ssh root@proxmox-host

# スクリプトに実行権限を付与
chmod +x create_vms.sh

# スクリプトを実行
./create_vms.sh
```

スクリプトは以下を実行します：

1. Ubuntu 22.04 Cloud Image をダウンロード
2. Cloud-Init テンプレートを作成
3. NAT 設定用の Cloud-Init スニペットを作成
4. 各 VM を作成・設定
5. （オプション）VM を起動

### 3. VM 起動後の確認

VM が起動したら、`wan0`と`wan1`が自動的に再起動し、NAT 設定が適用されます（初回起動から約 2-3 分）。

## トラブルシューティング

### WAN VM の状態確認

Proxmox ホストで実行：

```bash
chmod +x check_wan_status.sh
./check_wan_status.sh
```

### 手動で NAT 設定を適用

Cloud-Init が正しく動作しない場合、`wan0`または`wan1` VM に SSH でログインして：

```bash
# Proxmoxホストからwan0 VMにファイルをコピー
scp manual_nat_setup.sh user@<wan0-ip>:/home/user/

# wan0 VMにログイン
ssh user@<wan0-ip>

# スクリプトを実行
chmod +x manual_nat_setup.sh
sudo ./manual_nat_setup.sh
```

### よくある問題

#### 1. Cloud-Init が実行されない

```bash
# VM内で確認
sudo cloud-init status
sudo cat /var/log/cloud-init-output.log
```

#### 2. IP フォワーディングが無効

```bash
# VM内で確認・有効化
sudo sysctl net.ipv4.ip_forward
sudo sysctl -w net.ipv4.ip_forward=1
```

#### 3. iptables ルールが無い

```bash
# VM内で確認
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v

# 手動で設定する場合
sudo ./manual_nat_setup.sh
```

#### 4. ネットワークインターフェース名が違う

最新の Ubuntu では`eth0`, `eth1`の代わりに`ens18`, `ens19`などの名前が使われることがあります。

```bash
# インターフェース名を確認
ip link show

# 必要に応じてiptablesルールを調整
```

## 詳細なトラブルシューティング

詳細は [`troubleshooting.md`](./troubleshooting.md) を参照してください。

## ファイル構成

- `create_vms.sh` - メインの VM 作成スクリプト
- `check_wan_status.sh` - WAN VM の状態確認スクリプト（Proxmox ホストで実行）
- `manual_nat_setup.sh` - 手動 NAT 設定スクリプト（WAN VM 内で実行）
- `troubleshooting.md` - 詳細なトラブルシューティングガイド
- `nextrouter.pub` - SSH 公開鍵（要準備）

## NAT 設定の仕組み

`wan0`と`wan1`は、Cloud-Init を使用して以下の設定を自動的に行います：

1. **IP フォワーディングの有効化**

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```

2. **iptables NAT ルールの設定**

   ```bash
   iptables -t nat -A POSTROUTING -o <WAN_IF> -j MASQUERADE
   iptables -A FORWARD -i <LAN_IF> -o <WAN_IF> -j ACCEPT
   iptables -A FORWARD -i <WAN_IF> -o <LAN_IF> -m state --state RELATED,ESTABLISHED -j ACCEPT
   ```

3. **永続化**
   - `netfilter-persistent`で iptables ルールを保存
   - systemd サービスで再起動時も自動適用

## VM へのアクセス

デフォルトの認証情報：

- **ユーザー名**: `user`
- **パスワード**: `user`
- **SSH**: `nextrouter.pub`で認証

```bash
# routerVMにアクセス
ssh -i ~/.ssh/nextrouter user@172.0.10.10

# wan0にアクセス（IPアドレスは要確認）
ssh -i ~/.ssh/nextrouter user@<wan0-ip>
```

## カスタマイズ

`create_vms.sh`の冒頭で以下の設定を変更できます：

```bash
STORAGE_NAME="local-lvm"              # ストレージ名
TEMPLATE_VMID="9000"                  # テンプレートのVMID
COMMON_CORES=2                        # CPUコア数
COMMON_MEMORY=2048                    # メモリ (MB)
COMMON_DISK="16G"                     # ディスクサイズ
```

## ライセンス

MIT

## 参考

- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [Cloud-Init Documentation](https://cloudinit.readthedocs.io/)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
