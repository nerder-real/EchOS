//go:build darwin

package main

// macOS utun 设备层：对应 Windows 版的 WindowsTun（wintun.dll）。
// 创建方式与 wireguard-go 相同：AF_SYSTEM + SOCK_DGRAM 连接
// 「com.apple.net.utun」内核控制，得到一个点对点虚拟网卡。
// 读写走 socket fd，包前有 4 字节协议族前缀（本机字节序 AF_INET=2 / AF_INET6=30）。
//
// 系统侧配置（IP/路由/MTU/DNS）用 ifconfig / route / networksetup 子进程完成：
//   · 路由只接管 0.0.0.0/1 + 128.0.0.0/1（IPv6 同款 ::/1 + 8000::/1），
//     不动默认网关 —— 路由更细、且 Close 时按同目标删除即可精确还原；
//   · DNS 把各网络服务的解析器指到 TUN 网关（172.18.0.1），Close 还原；
//     分流域名的 DNS 劫持由 TUN 网关监听（runDNSListener）承接。

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	// utun 内核控制的注册名。必须带 `_control` 后缀：少了它 CTLIOCGINFO
	// 返回 ENOENT（no such file or directory），看起来像权限或环境问题，
	// 实际只是名字不匹配。
	utunControlName = "com.apple.net.utun_control"
	afSystem        = 32 // AF_SYSTEM
	afSysControl    = 2  // AF_SYS_CONTROL
	ctlIOCGINFO     = 0xC0644E03
	// UTUN_OPT_IFNAME：从已连接的 socket 回读内核给这张网卡起的名字。
	// unit 编号在所有 *_control 之间是全局共享的，同一个 unit 可能被
	// ipsec4 之类的类型占走，只有回读名字才能确认拿到的是 utun。
	sysprotoControl = 2
	utunOptIfname   = 2
)

type ctlInfoIOCTL struct {
	ctlID   uint32
	ctlName [96]byte
}

type sockaddrCtl struct {
	scLen      uint8
	scFamily   uint8
	ssSysaddr  uint16
	scUnit     uint32
	scID       uint32
	scReserved [5]uint32
}

// TunDevice wraps a macOS utun interface with IP/route/DNS configuration.
type TunDevice struct {
	mu       sync.RWMutex
	cfg      *TunConfig
	fd       int
	name     string
	ifIndex  int
	closed   bool
	savedDNS map[string][]string // 网络服务名 → 原 DNS 列表（"未设置"记为空切片）
	gwIP     string
	v6GW     string

	// 边缘主机路由：内核出站逃逸通道（见 ensureEdgeRoute）
	hostRoutesMu    sync.Mutex
	hostRoutesAdded map[string]bool
}

// NewTun creates the utun interface with the given config.
func NewTun(cfg *TunConfig) (*TunDevice, error) {
	if cfg.Name == "" {
		cfg.Name = "xtun"
	}
	if cfg.MTU <= 0 {
		cfg.MTU = 9000
	}

	// 先探一次控制 id（用于填 sockaddr_ctl.sc_id），探测用的 socket 随即丢弃。
	probe, err := syscall.Socket(afSystem, syscall.SOCK_DGRAM, afSysControl)
	if err != nil {
		return nil, fmt.Errorf("socket(AF_SYSTEM): %w", err)
	}
	var info ctlInfoIOCTL
	copy(info.ctlName[:], utunControlName)
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(probe), ctlIOCGINFO,
		uintptr(unsafe.Pointer(&info)))
	syscall.Close(probe)
	if errno != 0 {
		return nil, fmt.Errorf("CTLIOCGINFO: %w", errno)
	}

	// 逐个 unit 尝试，并回读内核分配的网卡名。
	//
	// unit 编号由所有 `com.apple.net.*_control` 共享，不按类型隔离：同一个
	// unit 可能落到 ipsec4 上。早期实现从 ctlID+1 起连、连上就当成功，结果
	// 正好跳过可用的 utun 号建出一张 ipsec 网卡，随后"找不到 utun 接口"
	// 报错 —— 网卡其实建成了，只是类型不对。这里必须按名字过滤。
	fd, name, err := connectUtun(info.ctlID)
	if err != nil {
		return nil, err
	}
	ifIndex, err := interfaceIndex(name)
	if err != nil {
		syscall.Close(fd)
		return nil, err
	}

	return &TunDevice{
		cfg:             cfg,
		fd:              fd,
		name:            name,
		ifIndex:         ifIndex,
		savedDNS:        map[string][]string{},
		hostRoutesAdded: map[string]bool{},
	}, nil
}

// connectUtun 依次尝试控制 unit，直到连上一个名字以 utun 开头的接口。
// connect 一旦失败或连到别的控制类型，这个 socket 就不能再用（会返回
// EISCONN/socket is already connected），所以每个 unit 都用全新 socket；
// 成功时把该 socket 交给调用方持有。
func connectUtun(ctlID uint32) (int, string, error) {
	var lastErr error
	for unit := uint32(1); unit <= 64; unit++ {
		fd, err := syscall.Socket(afSystem, syscall.SOCK_DGRAM, afSysControl)
		if err != nil {
			return -1, "", fmt.Errorf("socket(AF_SYSTEM): %w", err)
		}
		addr := sockaddrCtl{
			scLen:     32,
			scFamily:  afSystem,
			ssSysaddr: afSysControl,
			scUnit:    unit,
			scID:      ctlID,
		}
		_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd),
			uintptr(unsafe.Pointer(&addr)), 32)
		if errno != 0 {
			lastErr = errno
			syscall.Close(fd)
			continue
		}
		name, err := utunName(fd)
		if err != nil {
			lastErr = err
			syscall.Close(fd)
			continue
		}
		if !strings.HasPrefix(name, "utun") {
			// 这个 unit 被别的控制类型拿走了（实测会落到 ipsec4），换下一个号。
			lastErr = fmt.Errorf("unit %d 被占用为 %s", unit, name)
			syscall.Close(fd)
			continue
		}
		return fd, name, nil
	}
	if lastErr == nil {
		lastErr = errors.New("没有可用的 utun 控制单元")
	}
	return -1, "", fmt.Errorf("connect(utun control): %w", lastErr)
}

// utunName 用 UTUN_OPT_IFNAME 回读内核分配的接口名。
func utunName(fd int) (string, error) {
	buf := make([]byte, 128)
	l := uint32(len(buf))
	_, _, errno := syscall.Syscall6(syscall.SYS_GETSOCKOPT, uintptr(fd),
		sysprotoControl, utunOptIfname,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&l)), 0)
	if errno != 0 {
		return "", errno
	}
	if l == 0 {
		return "", errors.New("UTUN_OPT_IFNAME 返回空名字")
	}
	return strings.TrimRight(string(buf[:l]), "\x00"), nil
}

// interfaceIndex 按名字取接口索引。
func interfaceIndex(name string) (int, error) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0, fmt.Errorf("查询网卡 %s 失败: %w", name, err)
	}
	return iface.Index, nil
}

// EnsureEdgeHostRoutes 为服务器边缘 IP 加"经物理网卡网关"的主机路由。
//
// TUN 接管 0/1 路由后，内核自己 → 服务器的出站连接必须逃逸。IP_BOUND_IF
// 绑定在这台 macOS（26）上实测从未生效（接管后零成功流量，回退链也因错误
// 形态匹配不上而未启动）——不再依赖任何绑定语义，直接在主表上为边缘 IP
// 加主机路由：比 0/1 更精确，天然胜出，连接必然走物理网关出去。
//
// 写法必须是 `route add -host IP <网关IP>`（经网关，路由器转发）。
// 上一版用 `-interface en0` 是 on-link 语义：把公网 IP 当同网段直连主机，
// 内核对它发 ARP、无应答、拉黑——errno 从 ENETUNREACH 翻转成 EHOSTUNREACH
// 就是这么来的。
func (t *TunDevice) ensureEdgeRoute(ipStr string) int {
	ip := net.ParseIP(ipStr)
	if ip == nil || ip.To4() == nil {
		return 0
	}
	t.hostRoutesMu.Lock()
	defer t.hostRoutesMu.Unlock()
	if t.hostRoutesAdded[ipStr] {
		return 0
	}
	gw, err := defaultGatewayOfPhys()
	if err != nil || gw == "" {
		return 0
	}
	if _, err := runCmd("route", "-n", "add", "-host", ipStr, gw); err == nil {
		t.hostRoutesAdded[ipStr] = true
		return 1
	}
	return 0
}

// darwin 侧把主机路由能力注入优选层（tun_iprank.go 的 ensureEdgeRoutes 钩子）：
// TUN 模式下优选探测前给全部候选补路由，防止探测包被 0/1 劫持吸进 TUN 黑洞。
func init() { ensureEdgeRoutes = EnsureEdgeHostRoutes }

// EnsureEdgeHostRoutes 包一层：供优选层与 TUN 启动序调用。
func EnsureEdgeHostRoutes(ips []string) {
	activeTunMu.Lock()
	t := activeTun
	activeTunMu.Unlock()
	if t == nil {
		return
	}
	added := 0
	for _, ipStr := range ips {
		added += t.ensureEdgeRoute(ipStr)
	}
	if added > 0 {
		gw, _ := defaultGatewayOfPhys()
		log.Printf("[TUN] 边缘主机路由: 新增 %d 条（经网关 %s）", added, gw)
	}
}

// removeEdgeRoutes 在 TUN 关闭时摘除全部主机路由。
func (t *TunDevice) removeEdgeRoutes() {
	t.hostRoutesMu.Lock()
	defer t.hostRoutesMu.Unlock()
	for ipStr := range t.hostRoutesAdded {
		_, _ = runCmd("route", "-n", "delete", "-host", ipStr)
	}
	t.hostRoutesAdded = make(map[string]bool)
}

// defaultGatewayOfPhys 从路由表读物理网卡的默认网关（如 192.168.1.1）。
func defaultGatewayOfPhys() (string, error) {
	out, err := runCmd("route", "-n", "get", "default")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(out, "\n") {
		if i := strings.Index(line, "gateway:"); i >= 0 {
			gw := strings.TrimSpace(line[i+len("gateway:"):])
			if gw != "" {
				return gw, nil
			}
		}
	}
	return "", errors.New("读不到默认网关")
}

// Start brings the TUN interface up: assigns IP, adds takeover routes, points DNS at the gateway.
func (t *TunDevice) Start() error {
	// 劫持前抓运营商 DNS（resolv.conf 此时还是真实上游）。
	snapshotCarrierDNS()
	var v4gw, v6gw string
	for _, g := range t.cfg.Gateway {
		p, err := netip.ParsePrefix(g)
		if err != nil {
			continue
		}
		if p.Addr().Is4() {
			v4gw = p.Addr().String()
		} else {
			v6gw = p.Addr().String()
		}
	}
	if v4gw == "" {
		return errors.New("TUN 配置缺少 IPv4 网关")
	}
	t.gwIP = v4gw
	t.v6GW = v6gw

	// 本地地址：/30 的网关地址；对端取 /30 内的另一个可用地址
	peer := nextHostIn30(v4gw)
	if _, err := runCmd("ifconfig", t.name, "inet", v4gw, peer, "mtu",
		fmt.Sprint(t.cfg.MTU), "up"); err != nil {
		return fmt.Errorf("ifconfig inet: %w", err)
	}
	if v6gw != "" {
		// 单地址 + prefixlen。utun 是点对点设备，套用 IPv4 那种
		// 「本地 对端」双地址写法会让 SIOCAIFADDR 返回 EINVAL。
		if _, err := runCmd("ifconfig", t.name, "inet6", v6gw,
			"prefixlen", "126", "up"); err != nil {
			return fmt.Errorf("ifconfig inet6: %w", err)
		}
	}

	// 接管路由：/1 拆分避免动默认网关；Close 按同目标删除精确还原。
	// 2026-11-13 TUN 实录：上一会话崩溃会把 0/1 残留在死掉的旧 utun 上，
	// 新会话的 route add 撞「already in table」被静默吞掉 → 全部流量黑洞。
	// hijackRoute 幂等处理：先加，「已在表中」则删除残留再补，失败落日志。
	for _, r := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		hijackRoute("", r, t.name)
	}
	if v6gw != "" {
		// 2026-11-13 TUN 实录：::/1 + 8000::/1 两条 IPv6 路由在 macOS 26 上
		// 静默失败（netstat -f inet6 里不存在），IPv6 全部从 en0 直连绕过
		// 隧道——浏览器优先 AAAA，Google 全家 IPv6 被墙 →「TUN 开了网页
		// 打不开」。改用 2000::/3（全球单播，公网 IPv6 全在此段；TUN 自身的
		// fdfe::/8 ULA 与链路本地不在其中，不会被劫持）。
		hijackRoute("-inet6", "2000::/3", t.name)
	}

	// 记录网关地址，供 bindSocketToPhysNIC 豁免"发往 TUN 自身网段"的连接
	// （内核自己的 DNS 查询要打到 172.18.0.1 这个监听上，绑去物理网卡必死）。
	SetTunGateway(v4gw, v6gw)

	// 诊断快照：路由接管后的真实路由表 + 对一个公网 IP 的主表路由判定。
	// 首次 TUN 排障用：出站拨号 network is unreachable 时，这三段直接指出
	// 是"路由没接管成功"还是"scoped 查询缺默认路由"还是"绑定目标错误"。
	// 2026-11-13 补 IPv6 表：IPv6 劫持静默失败过一次，只有 dump 出来才看得见。
	if out, err := runCmd("netstat", "-rn", "-f", "inet"); err == nil {
		log.Printf("[TUN][诊断] 路由表:\n%s", headLines(out, 20))
	}
	if out, err := runCmd("netstat", "-rn", "-f", "inet6"); err == nil {
		log.Printf("[TUN][诊断] IPv6 路由表:\n%s", headLines(out, 14))
	}
	if out, err := runCmd("route", "-n", "get", "104.18.41.45"); err == nil {
		log.Printf("[TUN][诊断] route get 104.18.41.45:\n%s", out)
	}
	if out, err := runCmd("route", "-n", "get", "-inet6", "2001:4860:4860::8888"); err == nil {
		log.Printf("[TUN][诊断] route get -inet6 2001:4860:4860::8888:\n%s", out)
	}
	if out, err := runCmd("ifconfig", "en0"); err == nil {
		log.Printf("[TUN][诊断] en0:\n%s", headLines(out, 10))
	}

	return nil
}

func headLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

// carrierDNS 劫持前的运营商 DNS 快照。TUN 劫持后系统解析器指向 TUN 网关
// 自身，DNS 处理链的直连上游若退回 Go 默认解析器就形成自引用（查询又被
// 送回 TUN 网关）——2026-11-13 实录：国内域名全部秒级 SERVFAIL。必须用
// 劫持前抓到的这份快照。
var (
	carrierDNSMu   sync.RWMutex
	carrierDNSList []string
)

func snapshotCarrierDNS() {
	seen := map[string]bool{}
	var out []string
	add := func(ip string) {
		ip = strings.TrimSpace(ip)
		if ip == "" || seen[ip] {
			return
		}
		parsed := net.ParseIP(ip)
		if parsed == nil || parsed.IsLoopback() || parsed.IsLinkLocalUnicast() {
			return
		}
		seen[ip] = true
		out = append(out, ip)
	}
	// /etc/resolv.conf 反映劫持前的系统解析器（首个网络服务的 DNS）。
	if data, err := os.ReadFile("/etc/resolv.conf"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "nameserver ") {
				add(strings.TrimPrefix(line, "nameserver "))
			}
		}
	}
	carrierDNSMu.Lock()
	carrierDNSList = out
	carrierDNSMu.Unlock()
	if len(out) > 0 {
		log.Printf("[TUN] 运营商 DNS 快照: %v", out)
	}
}

func getCarrierDNSServers() []string {
	carrierDNSMu.RLock()
	defer carrierDNSMu.RUnlock()
	return append([]string(nil), carrierDNSList...)
}

// pointDNSToGateway 把所有网络服务的 DNS 指到 TUN 网关，并记录原值供还原。
func (t *TunDevice) pointDNSToGateway() {
	out, err := runCmd("networksetup", "-listallnetworkservices")
	if err != nil {
		return
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		// 首行是说明文字；带 * 的是被禁用的服务
		if line == "" || strings.HasPrefix(line, "An asterisk") || strings.HasPrefix(line, "*") {
			continue
		}
		cur, _ := runCmd("networksetup", "-getdnsservers", line)
		if strings.Contains(cur, "There aren't any DNS Servers set") {
			t.savedDNS[line] = []string{}
		} else {
			t.savedDNS[line] = strings.Fields(cur)
		}
		// 存档清洗：当前值里若已含本 TUN 网关，那是上一次内核硬杀
		//（崩溃/断电/SIGKILL，来不及还原）留下的劫持态，不是用户配置。
		// 不清洗的话本次退出会"还原"回劫持态，之后每次启动都把它当
		// 原值接力下去——2026-11-12 实录：Wi-Fi DNS 卡死在 172.18.0.1。
		// 记为 Empty，退出时回到 DHCP 下发的 DNS，历史污染随之自愈。
		for _, s := range t.savedDNS[line] {
			if s == t.gwIP {
				log.Printf("[TUN] %s 的 DNS 已是 TUN 网关 %s（上次异常退出的遗留），退出时还原为自动获取", line, t.gwIP)
				t.savedDNS[line] = []string{}
				break
			}
		}
		args := append([]string{"-setdnsservers", line}, t.gwIP)
		_, _ = runCmd("networksetup", args...)
	}
	if len(t.savedDNS) > 0 {
		log.Printf("[TUN] DNS 已指向 TUN 网关（%d 个网络服务，退出时还原）\n", len(t.savedDNS))
	}
	// 把各服务记录到的原始 DNS 合并进运营商快照（过滤 TUN 网关自身与
	// 环回/链路本地地址）——Wi-Fi 是静态 DNS、Ethernet 是 DHCP 之类的
	// 组合下，单靠 resolv.conf 会漏。
	carrierDNSMu.Lock()
	existing := map[string]bool{}
	for _, s := range carrierDNSList {
		existing[s] = true
	}
	for _, servers := range t.savedDNS {
		for _, s := range servers {
			parsed := net.ParseIP(s)
			if s == t.gwIP || parsed == nil || parsed.IsLoopback() || parsed.IsLinkLocalUnicast() || existing[s] {
				continue
			}
			existing[s] = true
			carrierDNSList = append(carrierDNSList, s)
		}
	}
	carrierDNSMu.Unlock()
}

// restoreDNS 把网络服务的 DNS 还原到接管前的状态。
func (t *TunDevice) restoreDNS() {
	for svc, servers := range t.savedDNS {
		args := []string{"-setdnsservers", svc}
		if len(servers) == 0 {
			args = append(args, "Empty")
		} else {
			args = append(args, servers...)
		}
		// 还原失败必须留痕：静默吞掉的话用户网就"莫名坏了"，无从查起。
		if _, err := runCmd("networksetup", args...); err != nil {
			log.Printf("[TUN] DNS 还原失败 %s: %v", svc, err)
		}
	}
	t.savedDNS = map[string][]string{}
}

// Close shuts down the TUN interface: restore DNS and takeover routes, then close the fd.
func (t *TunDevice) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil
	}
	t.closed = true
	t.removeEdgeRoutes()
	t.restoreDNS()
	for _, r := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		_, _ = runCmd("route", "-n", "delete", "-net", r, "-interface", t.name)
	}
	// 与接管侧对称：2000::/3（见 hijackRoute 注释）。旧版加的 ::/1、8000::/1
	// 从未成功安装过，无需清理；这里多删一次属无害兜底。
	_, _ = runCmd("route", "-n", "delete", "-inet6", "-net", "2000::/3", "-interface", t.name)
	return syscall.Close(t.fd)
}

// readAnomalies 采样记录"读到但被丢弃"的包头部，供数据面诊断。
var readAnomalies atomic.Int64

// ReadPacket reads one IP packet from the TUN device (blocking).
// darwin utun 的包带 4 字节协议族前缀，为网络字节序（大端）——2026-11-13
// 实录：按小端解读会拿到 0x02000000 之类，family 校验全拒，TUN 数据面
// 表现为"Opkts 涨、零处理、Ipkts 恒 0"（整机没网）。wireguard-go 同样按
// 大端处理 darwin utun。
func (t *TunDevice) ReadPacket() ([]byte, error) {
	t.mu.RLock()
	fd := t.fd
	closed := t.closed
	t.mu.RUnlock()
	if closed {
		return nil, net.ErrClosed
	}
	buf := make([]byte, 65535)
	n, err := syscall.Read(fd, buf)
	if err != nil {
		return nil, err
	}
	if n < 5 {
		if k := readAnomalies.Add(1); k <= 5 {
			log.Printf("[TUN][栈] 丢弃读包#%d：n=%d (<5)", k, n)
		}
		return nil, nil
	}
	family := binary.BigEndian.Uint32(buf[:4])
	if family != 2 /*AF_INET*/ && family != 30 /*AF_INET6*/ {
		if k := readAnomalies.Add(1); k <= 5 {
			log.Printf("[TUN][栈] 丢弃读包#%d：family=%d n=%d 头部=% x", k, family, n, buf[:8])
		}
		return nil, nil
	}
	out := make([]byte, n-4)
	copy(out, buf[4:n])
	return out, nil
}

// WritePacket writes one IP packet to the TUN device (prepends the family prefix).
func (t *TunDevice) WritePacket(data []byte) error {
	t.mu.RLock()
	fd := t.fd
	closed := t.closed
	t.mu.RUnlock()
	if closed {
		return net.ErrClosed
	}
	if len(data) < 1 {
		return nil
	}
	family := uint32(30) // AF_INET6
	if data[0]>>4 == 4 {
		family = 2 // AF_INET
	}
	pkt := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(pkt[:4], family)
	copy(pkt[4:], data)
	_, err := syscall.Write(fd, pkt)
	return err
}

// Index returns the network interface index.
func (t *TunDevice) Index() (int, error) {
	iface, err := net.InterfaceByName(t.name)
	if err != nil {
		return 0, err
	}
	return iface.Index, nil
}

// Name returns the utun interface name.
func (t *TunDevice) Name() string { return t.name }

// EnsureTunReady checks the process can create and configure a utun interface.
// 对应 Windows 版的 EnsureWintunLoaded：提前给出人话报错，而不是让内核
// 在深处理失败。
func EnsureTunReady() error {
	if os.Geteuid() != 0 {
		return errors.New("TUN 模式需要管理员权限：内核须以 root 运行（创建 utun 网卡、修改路由表与 DNS）")
	}
	if _, err := exec.LookPath("ifconfig"); err != nil {
		return errors.New("找不到 ifconfig，系统环境异常")
	}
	if _, err := exec.LookPath("networksetup"); err != nil {
		return errors.New("找不到 networksetup，系统环境异常")
	}
	return nil
}

// nextHostIn30 返回 /30 网段内的对端地址（网关 +1）。
func nextHostIn30(gw string) string {
	ip := net.ParseIP(gw)
	if ip == nil {
		return gw
	}
	ip = ip.To4()
	return fmt.Sprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]+1)
}

// tunNetConn 把出站端的 io.ReadWriteCloser（smux 流 / 简易 WS / 直连）
// 适配成 tls.Client 要求的 net.Conn：补上 Local/RemoteAddr（dummy）与
// 截止时间透传（底层支持就透传，不支持就忽略）。
type tunNetConn struct{ rw io.ReadWriteCloser }

type dummyAddr struct{}

func (dummyAddr) Network() string { return "tun" }
func (dummyAddr) String() string  { return "tun" }

func (c tunNetConn) Read(p []byte) (int, error)  { return c.rw.Read(p) }
func (c tunNetConn) Write(p []byte) (int, error) { return c.rw.Write(p) }
func (c tunNetConn) Close() error                { return c.rw.Close() }
func (c tunNetConn) LocalAddr() net.Addr         { return dummyAddr{} }
func (c tunNetConn) RemoteAddr() net.Addr        { return dummyAddr{} }

func (c tunNetConn) SetDeadline(t time.Time) error {
	type deadliner interface{ SetDeadline(time.Time) error }
	if d, ok := c.rw.(deadliner); ok {
		return d.SetDeadline(t)
	}
	return nil
}
func (c tunNetConn) SetReadDeadline(t time.Time) error {
	type deadliner interface{ SetReadDeadline(time.Time) error }
	if d, ok := c.rw.(deadliner); ok {
		return d.SetReadDeadline(t)
	}
	return nil
}
func (c tunNetConn) SetWriteDeadline(t time.Time) error {
	type deadliner interface{ SetWriteDeadline(time.Time) error }
	if d, ok := c.rw.(deadliner); ok {
		return d.SetWriteDeadline(t)
	}
	return nil
}

// asNetConn 把 io.ReadWriteCloser 适配成 net.Conn。
func asNetConn(rw io.ReadWriteCloser) net.Conn { return tunNetConn{rw: rw} }

// runCmd 执行系统命令并返回 stdout（错误一并返回，调用方自行取舍）。
func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// hijackRoute 幂等地把一条网段劫持到 TUN 接口。
//
// 先加；「已在表中」（上一会话崩溃残留、可能指着死掉的旧 utun）则删除残留
// 后重补。任何失败都落日志——路由劫持是 TUN 的生命线，静默失败 = 整机黑洞
// （2026-11-13 实录：IPv6 两条路由静默失败，浏览器优先 AAAA 全部绕行）。
func hijackRoute(family string, dest string, iface string) {
	addArgs := []string{"-n", "add"}
	if family != "" {
		addArgs = append(addArgs, family)
	}
	addArgs = append(addArgs, "-net", dest, "-interface", iface)
	out, err := runCmd("route", addArgs...)
	if err == nil {
		return
	}
	if !strings.Contains(out, "already in table") && !strings.Contains(out, "File exists") {
		log.Printf("[TUN] 路由劫持 %s %s 失败: %v | %s", family, dest, err, out)
		return
	}
	if dOut, derr := runCmd("route", "-n", "delete", family, "-net", dest); derr != nil {
		log.Printf("[TUN] 路由劫持 %s %s：残留路由删除失败: %v | %s", family, dest, derr, dOut)
		return
	}
	if out2, err2 := runCmd("route", addArgs...); err2 != nil {
		log.Printf("[TUN] 路由劫持 %s %s 重补失败: %v | %s", family, dest, err2, out2)
	} else {
		log.Printf("[TUN] 路由劫持 %s %s：已接管上一会话残留路由", family, dest)
	}
}
