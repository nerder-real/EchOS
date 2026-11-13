//go:build darwin

package main

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"syscall"
	"time"
)

func findPhysicalInterface() *net.Interface {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for i := range ifaces {
		if ifaces[i].Flags&net.FlagUp == 0 || ifaces[i].Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(ifaces[i].Name)
		if isVirtualInterface(name) {
			continue
		}
		addrs, err := ifaces[i].Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		if strings.Contains(name, "eth") || strings.Contains(name, "enp") ||
			strings.Contains(name, "wlan") || strings.Contains(name, "wi-fi") ||
			strings.Contains(name, "ethernet") ||
			strings.Contains(name, "以太网") || // Chinese: 以太网
			strings.Contains(name, "本地连接") || // Chinese: 本地连接
			strings.Contains(name, "宽带") || // Chinese: 宽带
			strings.Contains(name, "局域网") || // Chinese: 局域网
			strings.Contains(name, "无线") || // Chinese: 无线
			strings.Contains(name, "网络") { // Chinese: 网络 (broad match)
			return &ifaces[i]
		}
	}
	for i := range ifaces {
		if ifaces[i].Flags&net.FlagUp == 0 || ifaces[i].Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(ifaces[i].Name)
		if isVirtualInterface(name) {
			continue
		}
		addrs, err := ifaces[i].Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		return &ifaces[i]
	}
	return nil
}

func isVirtualInterface(name string) bool {
	// utun/awdl/llw 必须在列（2026-11-12 复盘）：darwin 上物理网卡探测的
	// 兜底是"第一个 Up 且有 v4 地址的非虚拟接口"，而 utunN 恰好 Up 且带
	// TUN 网关地址——不排除的话，en0 缓存失效重探时会绑到隧道自己，
	// 数据面表现为流量恒为 0。gif/stf 是 macOS 系统隧道，bridge/vlan
	// 是虚拟桥接，同样不属于物理出口。
	virtual := []string{"xtun", "xray_tun", "xray0", "singbox_tun", "wintun",
		"utun", "awdl", "llw", "gif", "stf", "bridge", "vlan",
		"vethernet", "vswitch", "docker", "bluetooth", "pseudo",
		"vbox", "vmnet", "hyper-v", "loopback", "isatap", "teredo",
		"6to4", "nlas", "npcap", "npcaps", "wsl", "tailscale"}
	for _, v := range virtual {
		if strings.Contains(name, v) {
			return true
		}
	}
	return false
}

// getLocalIPFromInterface returns the first IPv4 or IPv6 address of the given interface.
func getLocalIPFromInterface(iface *net.Interface, wantIPv6 bool) (net.IP, error) {
	if iface == nil {
		return nil, errors.New("nil interface")
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil, err
	}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipNet.IP
		if wantIPv6 {
			if ip.To4() == nil && len(ip) == 16 && !ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast() {
				return ip, nil
			}
		} else {
			if v4 := ip.To4(); v4 != nil {
				return v4, nil
			}
		}
	}
	if wantIPv6 {
		return nil, fmt.Errorf("no global IPv6 on %s", iface.Name)
	}
	return nil, fmt.Errorf("no IPv4 on %s", iface.Name)
}

// setUnicastIF 在 darwin 上对应 IP_BOUND_IF（IPv4）/ IPV6_BOUND_IF（IPv6）：
// 把 socket 的出流量钉在指定物理网卡上，绕开 TUN 的默认路由
// （Windows 版用 IP_UNICAST_IF + 网络字节序接口索引，语义相同）。
func setUnicastIF(fd uintptr, ifaceIdx int, isIPv6 bool) error {
	if isIPv6 {
		return syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, ifaceIdx)
	}
	return syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, ifaceIdx)
}

// directDialTCP dials a TCP connection bound to the physical interface.
// Uses IP_UNICAST_IF/IPV6_UNICAST_IF to force traffic through the physical NIC
// instead of the TUN interface. LocalAddr is intentionally not pinned so the OS
// can choose the current address on that NIC after WiFi↔有线切换.
func directDialTCP(target string, iface *net.Interface) (net.Conn, error) {
	if iface == nil {
		return net.DialTimeout("tcp", target, 10*time.Second)
	}
	host, _, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return net.DialTimeout("tcp", target, 10*time.Second)
	}
	isIPv6 := ip.To4() == nil

	ifaceIdx := iface.Index
	network := "tcp4"
	if isIPv6 {
		network = "tcp6"
	}

	d := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			var sockErr error
			err := c.Control(func(fd uintptr) {
				sockErr = setUnicastIF(fd, ifaceIdx, isIPv6)
			})
			if err != nil {
				return err
			}
			return sockErr
		},
	}
	return d.Dial(network, target)
}

// directDialUDP creates a UDP connection bound to the physical interface.
func directDialUDP(host string, port int, iface *net.Interface) (*net.UDPConn, error) {
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errors.New("invalid IP: " + host)
	}
	isIPv6 := ip.To4() == nil

	network := "udp4"
	if isIPv6 {
		network = "udp6"
	}
	target := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	if iface == nil {
		raddr := &net.UDPAddr{IP: ip, Port: port}
		return net.DialUDP(network, nil, raddr)
	}
	d := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			var sockErr error
			err := c.Control(func(fd uintptr) {
				sockErr = setUnicastIF(fd, iface.Index, isIPv6)
			})
			if err != nil {
				return err
			}
			return sockErr
		},
	}
	conn, err := d.Dial(network, target)
	if err != nil {
		return nil, err
	}
	udpConn, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("unexpected UDP conn type %T", conn)
	}
	return udpConn, nil
}

func directProxyStream(c1, c2 net.Conn) {
	done := make(chan struct{}, 2)
	activity := make(chan struct{}, 1)
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := c1.Read(buf)
			if n > 0 {
				if _, werr := c2.Write(buf[:n]); werr != nil {
					done <- struct{}{}
					return
				}
				select {
				case activity <- struct{}{}:
				default:
				}
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := c2.Read(buf)
			if n > 0 {
				if _, werr := c1.Write(buf[:n]); werr != nil {
					done <- struct{}{}
					return
				}
				select {
				case activity <- struct{}{}:
				default:
				}
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}()
	timer := time.NewTimer(5 * time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-done:
			c1.Close()
			c2.Close()
			<-done
			return
		case <-activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(5 * time.Minute)
		case <-timer.C:
			c1.Close()
			c2.Close()
			<-done
			return
		}
	}
}

func hasGlobal6(iface *net.Interface) bool {
	if iface == nil {
		return false
	}
	a, _ := iface.Addrs()
	for _, ad := range a {
		ip, ok := ad.(*net.IPNet)
		if !ok {
			continue
		}
		v := ip.IP.To16()
		if len(v) == 16 && (v[0]&0xE0) == 0x20 {
			return true
		}
	}
	return false
}

func hasIPv4(iface *net.Interface) bool {
	if iface == nil {
		return false
	}
	a, _ := iface.Addrs()
	for _, ad := range a {
		ip, ok := ad.(*net.IPNet)
		if !ok {
			continue
		}
		if ip.IP.To4() != nil {
			return true
		}
	}
	return false
}

// hasPublicIPv6OnAnyNIC checks whether any non-virtual physical NIC
// has a global-scope IPv6 address (2000::/3).
