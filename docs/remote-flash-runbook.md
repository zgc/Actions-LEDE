# 远程刷机安全规程与事故记录

## 适用范围（所有设备统一执行）

- 整盘镜像刷写设备：NUC8（nvme0n1）、ZBOX（sda）、X35G（sda）、MEMINI（mmcblk0）。
- B70 为 NAND/sysupgrade 设备：只能走 LuCI sysupgrade，禁止 raw dd 整盘刷写。
- 所有设备在写盘、读回校验、重启完成前，一律禁止中断 SSH 或终止远端进程。

## 事故记录（2026-08-26，X35G）

现象：远程执行 `timeout 300 ssh ... 'sh /tmp/reset_offline.sh 2>&1 | tail'`，
X35G 的 USB 启动介质写盘未在 300 秒内完成，本地 `timeout` 杀掉 SSH 客户端，
远端 `dd` 被连带中断，设备重启后无法引导，LAN 与 ZeroTier 均失联。

根因：写盘期间中断 SSH/进程是禁止操作。`reset_offline.sh` 自身的双 MD5 校验和
读回校验都正确，但远程执行方式破坏了它的保护流程。

后续 MEMINI 使用 `nohup` 后台写盘，2.3GB 镜像写盘 + 全盘读回校验通过后自动重启，
未出现异常。

## 强制流程

1. 刷写前必须在仓库与实机两侧校验 RELEASE_NAME.img.gz 的 .img.gz.md5。
2. 必须核对实机 /etc/openwrt-device.conf 的 DISK 与 RELEASE_NAME，确认目标盘正确。
3. 上传固件、md5 和 reset_offline.sh 到设备 /tmp 后，远端用如下方式启动，SSH 立即退出：

   ssh root@IP 'rm -f /tmp/flash.log; nohup sh /tmp/reset_offline.sh > /tmp/flash.log 2>&1 & echo $!'

4. 只通过轮询 /tmp/flash.log 和 ping/SSH 观察状态，等待“写入成功，重启”。
5. 重启后核对 head -3 /etc/openwrt_release、关键软件包、接口状态和 uptime。
6. 无人值守设备没有远程电源控制时不执行整盘刷写；若必须执行，先确认有断电恢复方案。

## 禁止清单

- 禁止对刷写 SSH 会话使用会杀客户的本地 timeout，尤其是在慢介质上。
- 禁止在写盘/读回校验期间关闭连接、终止远端进程或删除 /tmp 镜像。
- 禁止跳过实机 MD5 校验或多重确认目标盘。
- 禁止把失败后的无人值守设备重复盲刷。

## 推荐命令

在设备仓库根目录执行：./scripts/remote_flash.sh 192.168.x.1

该脚本会自动上传、远端 nohup 启动、轮询日志并在重启后给出核对信息。
