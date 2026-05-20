# 深度反思：ImmortalWrt 18.06 编译项目适配

## 我的根本错误

### 1. 表面理解 vs 深度理解
- **我以为**：改 URL 和路径就完事了
- **实际**：需要完整理解两个基座的生态系统差异

### 2. 没有问关键问题就开始动手

应该问的问题：
- 为什么选 immortalwrt 18.06 而不是 21.02/23.05？
- immortalwrt 和 coolsnowwolf/lede 的 feeds 源有什么不同？
- `package/lean/` 的依赖在 `package/emortal/` 是否全部可用？
- 18.06 内核与这些第三方包（openclash、zerotier）是否兼容？

### 3. 忽视了环境差异
原版设计假设：GitHub Actions 每次全新容器
当前环境：Docker 复用，有权限/残留问题

## 正确的适配思路

### Phase 1: 基座分析（停机调研）
1. 克隆 immortalwrt openwrt-18.06 裸仓库
2. 检查默认 feeds.conf
3. 检查 package/ 目录结构
4. 验证与 lean 包的兼容性

### Phase 2: 配置适配
1. feeds.conf.default（如有必要）
2. diy-part1.sh 路径调整
3. diy-part2.sh 路径调整
4. config.seed 内核/包选项

### Phase 3: Docker 环境修复
1. git 权限问题
2. 跨设备 mv 失败问题
3. 清理策略调整

### Phase 4: 验证测试

## 当前状态评估

| 组件 | 状态 | 问题 |
|------|------|------|
| build.sh | ⚠️ 已改但未验证 | git reset --hard HEAD 对 shallow clone 是否有效？ |
| diy-part1.sh | ✅ 已改 | 依赖 immortalwrt 基座有对应 feeds |
| diy-part2.sh | ✅ 已改 | 同上 |
| config.seed | ✅ 已加 zerotier | 其他包在 18.06 是否兼容？ |
| feeds.conf | ❌ 缺失 | 可能不需要，但需要确认 |

## 下一步行动建议

**选项 A**：彻底调研后重新开始
- 回滚到原始 lede 配置
- 单独创建 immortalwrt 分支
- 完整测试后再合并

**选项 B**：最小改动验证
- 保持当前修改
- 修复权限/路径问题
- 试跑看具体报错

**选项 C**：Boss 直接指导
- 告诉我已知的坑
- 或给出正确配置

---
记录时间：2026-05-14
反思人：Claw
