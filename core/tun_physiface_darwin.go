//go:build darwin

package main

// darwin 的物理网卡辅助：从原 tun_stub_other.go 迁移。
// detectPhysIfaceIndexAPI 返回 -1 表示「无 API 级探测」，
// x-tunnel.go 的 ensurePhysIfaceIndex 会自动退回 net.Interfaces 启发式。

import ()

// detectPhysIfaceIndexAPI 是 Windows 版 GetAdaptersAddresses 硬探测的对应物。
// darwin 上返回 -1：ensurePhysIfaceIndex 收到 -1 后走 net.Interfaces 启发式。
func detectPhysIfaceIndexAPI() int { return -1 }
