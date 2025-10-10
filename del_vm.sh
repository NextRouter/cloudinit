#!/bin/bash

# 削除対象のVMIDリスト
VM_IDS="1000 1001 1003 1004 1005 1002"

# 各VMIDに対してループ処理
for vmid in $VM_IDS
do
    echo "--- Deleting VM ${vmid} ---"

    # VMが実行中であれば停止する
    # qm statusが失敗しても処理を続けるために `|| true` を追加
    if qm status ${vmid} | grep -q "status: running"; then
        echo "Stopping VM ${vmid}..."
        qm stop ${vmid}
    fi

    # VMを削除する
    echo "Destroying VM ${vmid}..."
    qm destroy ${vmid}

    echo "VM ${vmid} has been deleted."
    echo ""
done

echo "All specified VMs have been processed."