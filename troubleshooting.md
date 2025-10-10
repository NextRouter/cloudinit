# WAN VM トラブルシューティングガイド

## 問題: wan0/wan1 の NAT 設定が機能しない

### 1. VM に SSH でログインして状態確認

```bash
# wan0 VMにログイン (Proxmoxのコンソールから、またはSSH)
ssh user@<wan0のIPアドレス>
```

### 2. Cloud-Init の実行状態を確認

```bash
# Cloud-Initの状態確認
sudo cloud-init status

# Cloud-Initのログ確認
sudo cat /var/log/cloud-init.log
sudo cat /var/log/cloud-init-output.log

# エラーがあるか確認
sudo journalctl -u cloud-init
```

### 3. IP フォワーディングの確認

```bash
# IPフォワーディングが有効か確認
sudo sysctl net.ipv4.ip_forward
# 出力: net.ipv4.ip_forward = 1 であるべき

# すべてのフォワーディング設定を確認
sudo sysctl -a | grep forward
```

### 4. iptables ルールの確認

```bash
# NATテーブルの確認
sudo iptables -t nat -L -n -v

# FORWARDチェーンの確認
sudo iptables -L FORWARD -n -v

# すべてのルールを確認
sudo iptables-save
```

### 5. ネットワークインターフェースの確認

```bash
# インターフェース一覧
ip addr show

# ルーティングテーブル
ip route show

# インターフェース名とIPアドレスを確認
# eth0: WAN側（DHCPで取得したIP）
# eth1: LAN側（172.0.10.1 または 172.0.11.1）
```

### 6. 手動での設定適用（一時的な修正）

Cloud-Init がうまく動作していない場合、手動で設定：

```bash
# IPフォワーディングを有効化
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf

# iptablesルールを追加
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT

# ルールを保存
sudo apt-get update
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save

# 再起動後も有効にする
sudo systemctl enable netfilter-persistent
```

### 7. 接続テスト（router VM から）

router VM にログインして、wan0/wan1 経由でインターネットに接続できるか確認：

```bash
# router VMにログイン
ssh user@172.0.10.10  # または 172.0.11.10

# wan0経由でpingテスト
ping -I eth0 8.8.8.8

# wan1経由でpingテスト
ping -I eth1 8.8.8.8

# ルーティングテーブル確認
ip route show
```

### 8. Proxmox 側の確認

```bash
# Proxmoxホストで、Cloud-Initスニペットが正しく作成されているか確認
cat /var/lib/vz/snippets/wan-passthrough.yaml

# VMの設定確認
qm config 1000
qm config 1001

# cicustomが正しく設定されているか確認
# 出力に以下が含まれているはず:
# cicustom: user=local:snippets/wan-passthrough.yaml
```

## よくある問題と解決策

### 問題 1: Cloud-Init スニペットが読み込まれない

**解決策**:

```bash
# Proxmoxホストで実行
# VMを停止して再起動
qm stop 1000
qm start 1000

# または、Cloud-Init設定を再生成
qm set 1000 --delete cicustom
qm set 1000 --cicustom "user=local:snippets/wan-passthrough.yaml"
qm stop 1000
qm start 1000
```

### 問題 2: ネットワークインターフェース名が異なる

最新の Ubuntu では`eth0`, `eth1`ではなく`ens18`, `ens19`などの名前になっている場合があります。

**確認**:

```bash
ip link show
```

**解決策**: インターフェース名に応じて iptables ルールを調整

### 問題 3: パッケージのインストールが失敗

**解決策**:

```bash
# 手動でパッケージをインストール
sudo apt-get update
sudo apt-get install -y iptables iptables-persistent netfilter-persistent
```
