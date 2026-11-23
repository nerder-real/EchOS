//go:build darwin

package main

import (
	"flag"
	"log"
	"net"
	"sync"
	"time"
)

// 连接熔断直连兜底（2026-11-22 排查催生，2026-11-22 用户立规后收窄）。
//
// 背景：ZCode 这类客户端对连接建立有 400~1000ms 的内部预算，而 EchOS 隧道对
// CN-CDN 托管的目标（z.ai 等）经 CF Worker 跨境，首字节普遍 0.5~1.2s —— 客户端
// 预算必输，连接被应用自己 RST，表现为「拨通即死」+ 高频重试。同病症还有拨号期
// 就被对端拒绝的目标（如阿里云日志服务拒绝 CF 出站 IP）。
//
// 原则（2026-11-22 用户拍板，零豁免）：全局模式（-default proxy）= 全部流量
// 走隧道，任何直连降级都违背语义 —— 熔断兜底在全局模式下永远不生效。
// 本机制默认关闭（-direct-fallback 默认 false），且仅在「绕过大陆/黑名单」
// （-default direct，直连本来就是合法出口）下允许开启。
//
// 规则（开启后）：同一目标连续 3 次「隧道拨号失败」或「拨通后服务器零字节回包」，
// 先对目标 IP 做 2~5 秒直连探活——探活通过才切直连兜底 5 分钟（到期自动回隧道
// 接受检验，再坏再熔断，自愈闭环）。探活不通过（目标本来就需要隧道，如被墙
// 站点）则保持隧道不动，60 秒后才允许再探。全程日志可见。

var directFallback bool

func init() {
	flag.BoolVar(&directFallback, "direct-fallback", false,
		"同一目标经隧道反复秒断/拨号失败时，探活通过后自动直连兜底 5 分钟（仅 -default direct 的分流模式生效，全局模式永远不生效）")
}

type connBreaker struct {
	mu           sync.Mutex
	streak       map[string]int       // 目标(host:port) → 连续异常次数
	blockedUntil map[string]time.Time // 目标 → 直连兜底截止时刻
	lastIP       map[string]string    // 目标 → 最近一次应用的解析 IP（探活用）
	probeCool    map[string]time.Time // 目标 → 上次探活失败后的冷却截止
}

var connBrk = &connBreaker{
	streak:       make(map[string]int),
	blockedUntil: make(map[string]time.Time),
	lastIP:       make(map[string]string),
	probeCool:    make(map[string]time.Time),
}

const (
	brkThreshold    = 3             // 连续 3 次异常触发
	brkCooldown     = 5 * time.Minute
	brkProbeCool    = 60 * time.Second
)

// allow 报告该目标当前是否处于直连兜底期。
// 全局模式（-default proxy）下永远返回 false：全部流量走隧道是模式的原则，
// 直连降级即使「探活通过」也不允许（2026-11-22 用户立规）。
func (b *connBreaker) allow(host string) bool {
	if !directFallback {
		return false
	}
	if defaultRouteDecision != DecisionDirect {
		return false // 全局/其他模式：原则优先，无直连兜底
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if until, ok := b.blockedUntil[host]; ok {
		if time.Now().Before(until) {
			return true
		}
		// 兜底期满：删标记，让流量回隧道重新接受检验（自愈闭环的另一半）
		delete(b.blockedUntil, host)
		log.Printf("[TUN][熔断] %s 兜底期满，流量回归隧道", host)
	}
	return false
}

// record 记录一次隧道侧结果。
// dialFailed：拨号就被对端拒绝；downBytes：服务器经隧道回包的字节数，
// 0 = 拨通了但服务器什么都没回（拨通即死）。正常回包（>0）清零计数——
// 快而成功的请求（本来 <2s）不会被误判。
func (b *connBreaker) record(host, ipTarget string, dialFailed bool, downBytes int64) {
	if host == "" {
		return
	}
	// 全局模式或未开启兜底：不做任何计数与探活（原则：全局无直连降级）
	if !directFallback || defaultRouteDecision != DecisionDirect {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if ipTarget != "" {
		b.lastIP[host] = ipTarget
	}
	if dialFailed || downBytes == 0 {
		b.streak[host]++
	} else {
		if b.streak[host] > 0 {
			delete(b.streak, host)
		}
		return
	}
	n := b.streak[host]
	if n < brkThreshold {
		return
	}
	// 已在兜底期内（保险，理论上不会走到这里）或探活冷却中：不重复触发
	if until, ok := b.blockedUntil[host]; ok && time.Now().Before(until) {
		return
	}
	if cool, ok := b.probeCool[host]; ok && time.Now().Before(cool) {
		return
	}
	log.Printf("[TUN][熔断] %s 连续 %d 次经隧道异常，后台探活直连…", host, n)
	go b.probe(host)
}

// probe 对目标最近一次使用的 IP 做 TCP 直连探活：通过才切兜底；
// 失败说明该目标本来就需要隧道（如被墙站点），保持现状并冷却 60 秒。
//
// 探活拨号必须临时加主机路由逃逸（内核自己的出站在 TUN+全局下会被 0/1 劫持
// 吸回隧道，IP_BOUND_IF 在 macOS 26 实测无效——见 tun_device_darwin.go
// ensureEdgeRoute 的注释），用完即摘，不留垃圾路由。
func (b *connBreaker) probe(host string) {
	b.mu.Lock()
	ipTarget := b.lastIP[host]
	b.mu.Unlock()
	if ipTarget == "" {
		b.mu.Lock()
		b.probeCool[host] = time.Now().Add(brkProbeCool)
		b.mu.Unlock()
		return
	}
	ipOnly, _, err := net.SplitHostPort(ipTarget)
	if err != nil {
		ipOnly = ipTarget
	}

	// 临时主机路由：经真实网关逃逸 TUN 劫持
	activeTunMu.Lock()
	t := activeTun
	activeTunMu.Unlock()
	if t != nil {
		t.ensureEdgeRoute(ipOnly)
	}
	conn, derr := directDialTCP(ipTarget, physIfaceForProbe())
	// 无论成败，探活路由用完即摘
	if t != nil {
		t.hostRoutesMu.Lock()
		_, _ = runCmd("route", "-n", "delete", "-host", ipOnly)
		delete(t.hostRoutesAdded, ipOnly)
		t.hostRoutesMu.Unlock()
	}

	if derr != nil || conn == nil {
		b.mu.Lock()
		b.probeCool[host] = time.Now().Add(brkProbeCool)
		b.mu.Unlock()
		log.Printf("[TUN][熔断] %s 直连探活失败（该目标确实需要隧道），保持隧道，%d 秒后可再探",
			host, int(brkProbeCool.Seconds()))
		return
	}
	_ = conn.Close()
	b.mu.Lock()
	b.blockedUntil[host] = time.Now().Add(brkCooldown)
	delete(b.streak, host)
	b.mu.Unlock()
	log.Printf("[TUN][熔断] %s 直连探活通过，直连兜底 %d 分钟（到期自动回隧道）",
		host, int(brkCooldown.Minutes()))
}

// physIfaceForProbe 从包级物理网卡索引解析接口对象（WiFi↔有线切换后索引会变，
// 每次探活现查，不缓存）。
func physIfaceForProbe() *net.Interface {
	idx := getPhysIfaceIndex()
	if idx <= 0 {
		return nil
	}
	iface, err := net.InterfaceByIndex(idx)
	if err != nil {
		return nil
	}
	return iface
}
