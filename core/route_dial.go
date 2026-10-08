//go:build !windows

package main

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 本地代理（SOCKS5 / HTTP）的分流出站。
//
// Windows 上 x-tunnel 只提供一个"什么都往隧道里塞"的本地代理，分流是 v2rayN 干的。
// Mac 版没有 v2rayN 这一层，所以分流必须自己做，否则打开百度也要绕一圈 Cloudflare。
//
// 规则引擎直接复用 Windows 版 TUN 模式那套（tun_route.go + geoip/geosite），
// 只是把判定点从 TUN 网卡挪到了本地代理的入站处。

var routeReady atomic.Bool

// initLocalRouting 在非 TUN 模式下初始化分流。全局模式（-default all）不需要
// 加载 geo 数据，省下几百毫秒启动时间和几十 MB 内存。
func initLocalRouting() {
	initRules(routeStr, defaultRouteStr, ruleMode)

	if strings.EqualFold(strings.TrimSpace(defaultRouteStr), "all") {
		log.Printf("[分流] 全局模式：所有流量走代理")
		routeReady.Store(true)
		return
	}
	loadGeoIP()
	loadGeoSite()
	routeReady.Store(true)
	log.Printf("[分流] 规则模式已就绪")
}

// outbound 是一条出站连接：可能是隧道里的 smux 流，也可能是本地直连的 TCP。
type outbound struct {
	rw        io.ReadWriteCloser
	channelID int
	direct    bool
}

var errBlocked = errors.New("规则拦截")

// dialTargetWithRoute 按路由规则决定 target 走隧道还是直连。
// target 形如 "example.com:443" 或 "1.2.3.4:443"。
func dialTargetWithRoute(target string) (*outbound, error) {
	host, _, err := net.SplitHostPort(target)
	if err != nil {
		host = target
	}

	decision := DecisionProxy
	reason := ""
	if routeReady.Load() {
		// 是域名就按域名匹配，是 IP 就按 IP 匹配；routeTCP 内部已处理两种情况。
		if net.ParseIP(host) != nil {
			decision, reason = routeTCP("", host)
		} else {
			decision, reason = routeTCP(host, host)
			// 域名没命中任何规则时，再按它解析出来的 IP 判一次。
			//
			// geosite 名单只有六千多条后缀，覆盖得了主流网站，覆盖不了长尾：
			// 一个没上榜的国内小站会被当成"不认识"直接丢进代理，绕一圈国外
			// 反而更慢。拿解析结果查一次 geoip 就能救回这类站点。
			if decision == defaultRouteDecision && reason == "default" {
				if d, r, ok := routeByResolvedIP(host); ok {
					decision, reason = d, r
				}
			}
		}
	}

	switch decision {
	case DecisionBlock:
		log.Printf("[分流] 拦截 %s (%s)", target, reason)
		return nil, errBlocked

	case DecisionDirect:
		c, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err != nil {
			// 直连失败不代表该走代理：可能就是站点挂了。
			// 但对国内被墙域名误判成 direct 的情况，退回代理能救回来。
			// wpad 是 macOS 的代理自动发现，它本来就查不到，不值得当错误刷屏
			if !strings.HasPrefix(target, "wpad:") {
				log.Printf("[分流] 直连 %s 失败(%v)，改走代理", target, err)
			}
			return dialViaTunnel(target)
		}
		return &outbound{rw: c, direct: true}, nil

	default:
		return dialViaTunnel(target)
	}
}

// 服务端协议：0=未探测 1=x-tunnel(smux) 2=简易 WebSocket 代理
var serverProtocol atomic.Int32

const (
	protoUnknown int32 = 0
	protoSmux    int32 = 1
	protoSimple  int32 = 2
)

// detectServerProtocol 在首批通道就绪后判定服务端类型。
//
// 两种服务端在 WebSocket 握手层完全一样（都认 Sec-WebSocket-Protocol 里的 token），
// 差别要到发第一帧数据才暴露出来，所以只能主动探。
func detectServerProtocol() {
	if echPool == nil {
		return
	}
	// 先试简易协议：它有明确的 CONNECTED 应答，判定是确定性的。
	// 反过来用 smux 判定不可靠 —— 通道"建立"根本不需要服务端参与，
	// HasHealthyChannel 为真也可能只是本地建了个没人搭理的会话。
	if probeSimpleProtocol() {
		serverProtocol.Store(protoSimple)
		log.Printf("[协议] 服务端类型: 简易 WebSocket 代理（每连接一条 WebSocket）")
		return
	}
	// 探测没判出来（超时/链路慢）时按 simple 处理：本项目服务端（Worker-ECH.js）
	// 就是简易协议，simple 池对它是天然正确的；反观 smux 池对 simple 服务端
	// 会因服务端不认 smux 帧而黑洞。探测失败默认 smux 只会把可用链路拖死。
	serverProtocol.Store(protoSimple)
	log.Printf("[协议] 服务端类型探测未果，按简易 WebSocket 代理处理（并发池走 simple）")
}

func dialViaTunnel(target string) (*outbound, error) {
	if echPool == nil {
		return nil, errors.New("隧道尚未就绪")
	}

	if serverProtocol.Load() == protoSimple {
		c, err := dialSimpleWS(target)
		if err == nil {
			return &outbound{rw: c}, nil
		}
		// 严格遵循分流模式：该站点按规则走隧道，隧道失败就如实失败，
		// 绝不自动改走直连（否则"绕过大陆"下会悄悄直连国外站、暴露真实 IP，
		// 也会破坏用户对流量的预期）。
		log.Printf("[分流] %s 经隧道失败(%v)，按分流模式如实返回错误", target, err)
		return nil, err
	}

	s, chID, _, err := echPool.openTCPStream(target)
	if err != nil {
		return nil, err
	}
	return &outbound{rw: s, channelID: chID}, nil
}

// relayOutbound 在客户端连接和出站连接之间双向转发，语义与 proxyConnStream 一致，
// 区别只是出站端放宽成了 io.ReadWriteCloser，好让直连的 net.Conn 也能走这里。
func relayOutbound(c net.Conn, ob *outbound) {
	done := make(chan struct{}, 2)
	// 转发缓冲放大到 256KB：io.Copy 默认 32KB，大流量下系统调用太频繁，
	// 放大后一次搬更多字节，吞吐更稳（与 WS 读写缓冲 256KB 对齐）。
	go func() {
		_, _ = io.CopyBuffer(ob.rw, c, make([]byte, 256*1024))
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.CopyBuffer(c, ob.rw, make([]byte, 256*1024))
		done <- struct{}{}
	}()
	<-done
	_ = ob.rw.Close()
	_ = c.Close()
	<-done
}

// logRouteEvent 打一条能看出走了哪条路的日志
func logRouteEvent(c net.Conn, reqType, target string, ob *outbound, opened bool) {
	arrow := "关闭"
	if opened {
		arrow = "打开"
	}
	if ob.direct {
		log.Printf("[客户端] %s %s %s %s 直连", clientSourceAddr(c), reqType, arrow, target)
		return
	}
	log.Printf("[客户端] %s %s %s %s 通道 %d", clientSourceAddr(c), reqType, arrow, target, ob.channelID)
}


// resolvedRouteCache 缓存"域名 → 路由判定"，避免每条连接都去解析一次 DNS。
var resolvedRouteCache sync.Map

type resolvedRoute struct {
	decision RouteDecision
	reason   string
	at       time.Time
}

const resolvedRouteTTL = 10 * time.Minute

// routeByResolvedIP 把域名解析成 IP，再按 geoip 规则判一次。
// 第三个返回值表示"是否得到了有效判定"——解析失败或规则没命中都返回 false，
// 让调用方保持原来的默认决策。
func routeByResolvedIP(host string) (RouteDecision, string, bool) {
	if v, ok := resolvedRouteCache.Load(host); ok {
		if rr, _ := v.(resolvedRoute); time.Since(rr.at) < resolvedRouteTTL {
			return rr.decision, rr.reason, true
		}
		resolvedRouteCache.Delete(host)
	}

	// 解析要有超时：DNS 卡住的话，每条连接都会跟着卡。
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil || len(addrs) == 0 {
		return DecisionNone, "", false
	}

	for _, a := range addrs {
		ipStr := a.IP.String()
		if d, rule := routeIPStr(ipStr); d != DecisionNone {
			reason := "ip:" + rule + "(解析自域名)"
			resolvedRouteCache.Store(host, resolvedRoute{decision: d, reason: reason, at: time.Now()})
			return d, reason, true
		}
	}
	return DecisionNone, "", false
}
