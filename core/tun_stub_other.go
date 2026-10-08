//go:build !windows

package main

// macOS / Linux 下不提供 TUN 模式，本文件只补齐 Windows 版里
// 由 tun_*.go 提供、而 x-tunnel.go 又直接引用到的符号，
// 让客户端（socks5 / http 本地监听 + wss+ECH 出站）能在非 Windows 平台编译运行。
//
// 之所以保留这些空实现而不是去改 x-tunnel.go，是为了让核心代码
// 与 Windows 版源码保持逐字一致，后续上游更新可以直接替换文件。

import (
	"errors"
	"net"
	"strings"
)

// tunMode 恒为 false：非 Windows 平台不支持 TUN，全部走本地监听模式。
var (
	tunMode bool = false
	tunName      = "xtun"
	tunMTU       = 9000
)

// setUnicastIF 对应 Windows 的 IP_UNICAST_IF 绑定，非 Windows 平台无需绑定。
func setUnicastIF(fd uintptr, ifaceIdx int, isIPv6 bool) error { return nil }

func chooseTunIPv4Config() (gatewayCIDR string, dnsIP string) {
	return "172.18.0.1/30", "172.18.0.2"
}

func StartTun(cfg *TunConfig) error {
	return errors.New("当前平台不支持 TUN 模式")
}

// isVirtualInterface 按 macOS/Linux 的命名习惯识别虚拟网卡，
// 用于挑选真正的物理出口网卡（en0 有线/无线等）。
func isVirtualInterface(name string) bool {
	virtual := []string{"utun", "tun", "tap", "awdl", "llw", "bridge",
		"vmnet", "vboxnet", "gif", "stf", "ipsec", "ppp", "docker",
		"veth", "tailscale", "anpi", "ap1", "xhc"}
	for _, v := range virtual {
		if strings.Contains(name, v) {
			return true
		}
	}
	return false
}

// getSystemDNSServers 在 Windows 版里是读网卡上配置的 DNS。
// macOS 下没有等价的按网卡查询接口，返回空表示"用系统默认解析器"，
// 上层 dialPhysDNS 会自动退回到 Go 默认的 DNS 解析路径。
func getSystemDNSServers(iface *net.Interface) []string { return nil }
