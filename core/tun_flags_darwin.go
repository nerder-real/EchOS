//go:build darwin

package main

import "flag"

// TUN 专用参数（-route/-default/-rule/-geoip/-geosite 定义在 route_flags_other.go，
// 本地代理分流与 TUN 分流共用同一套，不在此重复定义）。

var (
	tunMode bool
	tunName string
	tunMTU  int
)

func init() {
	flag.BoolVar(&tunMode, "tun", false, "启用 TUN 模式（接管全量路由，需管理员权限）")
	flag.StringVar(&tunName, "tun-name", "xtun", "TUN 网卡名称")
	// MTU 9000 是 v1.3.0 起的吞吐设计（大包 = 少 6 倍的系统调用与 gVisor
	// 每包开销，实测 40MB/s）。2026-11-22 曾降到 1400 做大包分离实验：
	// 握手取消风暴确实消失（501→1），但吞吐大幅回退——两次实测对比后确认
	// ZCode 断联与 MTU 无关（v1.3.0 的 TUN 同样断联，根因是隧道首字节延迟
	// 对上客户端 0.4~1s 预算，见 tun_breaker.go 头注释），撤销该实验。
	// 注意：若未来要再查大包病，用 -tun-mtu 1400 临时参数，不动默认值。
	flag.IntVar(&tunMTU, "tun-mtu", 9000, "TUN 接口 MTU")
}
