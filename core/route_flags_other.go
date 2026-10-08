//go:build !windows

package main

import "flag"

// Windows 版这些参数定义在 tun_flags.go（只在 TUN 模式下用）。
// Mac 版没有 TUN，但本地 SOCKS5/HTTP 代理同样需要分流能力
// —— Windows 上那部分是交给 v2rayN 做的，这边没有 v2rayN，只能自己做。
// 所以把同名参数在非 Windows 平台重新定义一遍，含义保持一致。

const defaultRouteRules = "proxy,geosite:google;proxy,geosite:geolocation-!cn;direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn"

var (
	defaultRouteStr string
	ruleMode        string
	routeStr        string

	geoipFile   string
	geositeFile string
)

func init() {
	flag.StringVar(&routeStr, "route", defaultRouteRules,
		"有序路由规则，用分号分隔多条。格式: behavior,condition;behavior,condition...\n行为: direct / proxy / block\n条件: geosite:xx / geoip:xx / domain:xx / cidr")
	flag.StringVar(&defaultRouteStr, "default", "proxy",
		"规则未命中时的默认路由：proxy、direct 或 all（全局代理，跳过规则解析）")
	flag.StringVar(&ruleMode, "rule", "all",
		"规则生效的协议：tcp（仅TCP走规则，UDP直连）、udp（仅UDP走规则，TCP直连）、all（都走规则）")

	flag.BoolVar(&verboseDNS, "vdns", false, "输出 DNS 解析诊断日志（很吵，仅排查用）")
	flag.StringVar(&geoipFile, "geoip", "geoip.dat", "GeoIP 数据文件路径")
	flag.StringVar(&geositeFile, "geosite", "geosite.dat", "GeoSite 数据文件路径")
}
