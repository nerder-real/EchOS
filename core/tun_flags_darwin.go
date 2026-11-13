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
	flag.IntVar(&tunMTU, "tun-mtu", 9000, "TUN 接口 MTU")
}
