package main

// TunConfig holds TUN mode configuration.
// Matches Xray's Config struct (proxy/tun/config.proto) but without protobuf dependency.
type TunConfig struct {
	// Name of the TUN interface (e.g. "xray_tun")
	Name string

	// MTU for the TUN interface (default 9000)
	MTU int

	// Gateway IP addresses to assign to the TUN interface (e.g. "172.18.0.1/30")
	// 同时也是内核 DNS 监听地址的来源（runDNSListener 遍历 Gateway，见 tun_dns.go）。
	Gateway []string
}
