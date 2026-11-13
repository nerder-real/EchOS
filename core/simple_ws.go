//go:build !windows

package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// 「简易 WebSocket 代理」协议。
//
// 社区里流传的 Cloudflare Worker 服务端（就是 `WebSocket Proxy Server` 那一版）
// 用的并不是 x-tunnel 的 smux 多路复用协议，而是一套朴素得多的东西：
//
//	客户端 → 服务端   文本  "CONNECT:example.com:443|"   建立到目标的连接
//	服务端 → 客户端   文本  "CONNECTED"                   连上了
//	双向              二进制 原始字节                      之后就是纯透传
//	任意方向          文本  "CLOSE" / "ERROR:xxx"         结束
//
// 关键差别是**一个 WebSocket 只服务一条 TCP 连接**，没有多路复用。
// 客户端如果按 smux 那套发帧，服务端因为没收到过 CONNECT，remoteWriter 是 null，
// 会把所有二进制帧默默丢掉 —— 表现就是"握手成功、认证通过、然后永远没有响应"。
//
// 这里实现这套协议，让 EchOS 能直连这类服务端。

const (
	// 4 秒而不是 8 秒：失败反馈更快，配合拨号级换边缘重试，坏路径的总等待
	// 时间从"8 秒×2 次"压到"4 秒×2 次"（对齐 Win 版实测值）。
	simpleConnectTimeout = 4 * time.Second

	// WebSocket 应用层保活（对齐 Win 版，2026-10 用户在 Win 上验证过收益）。
	//
	// 播放器缓冲满之后，隧道可能几十秒都没有任何数据。实测这类空闲连接会在
	// 约 120 秒时被中间链路（Cloudflare 边缘）回收：内核里没有任何 120 秒
	// 超时，日志里那批"存活时间正好 120 秒"的连接就是这么没的。被回收后再
	// 拖动进度，就得重新走一遍 DNS + TCP + TLS + WS + CONNECT，体感就是
	// "拖动要等好几秒"。TCP 保活（physKeepAlive）只能刷新传输层的空闲
	// 计时器，中间的 WebSocket / HTTP 层不一定认账；应用层 ping 才是中间
	// 设备一定计数的活动。
	//
	// 另一个好处：ping 写不出来基本等价于连接已经死了，这里直接关掉，让
	// 转发循环立刻退出，而不是再挂两分钟才由对端超时暴露出来。
	wsPingInterval = 30 * time.Second
	wsPingTimeout  = 10 * time.Second
)

// simpleWSConn 把一条「已 CONNECTED 的 WebSocket」包装成 net.Conn。
type simpleWSConn struct {
	ws     *websocket.Conn
	reader io.Reader

	readMu  sync.Mutex
	writeMu sync.Mutex

	closed   atomic.Bool
	closeErr error

	stopPing chan struct{}
}

func (c *simpleWSConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if c.reader == nil {
			mt, r, err := c.ws.NextReader()
			if err != nil {
				return 0, err
			}
			if mt == websocket.TextMessage {
				// 控制消息：CLOSE 表示对端结束，ERROR: 带出服务端的失败原因
				msg, _ := io.ReadAll(r)
				text := string(msg)
				switch {
				case text == "CLOSE":
					return 0, io.EOF
				case strings.HasPrefix(text, "ERROR:"):
					return 0, fmt.Errorf("服务端错误: %s", strings.TrimPrefix(text, "ERROR:"))
				default:
					// CONNECTED 之类的多余控制字，忽略继续读
					continue
				}
			}
			if mt != websocket.BinaryMessage {
				continue
			}
			c.reader = r
		}
		n, err := c.reader.Read(p)
		if errors.Is(err, io.EOF) {
			c.reader = nil
			if n > 0 {
				return n, nil
			}
			continue
		}
		return n, err
	}
}

func (c *simpleWSConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	// 一律走二进制帧：服务端那边 `data instanceof ArrayBuffer` 分支直接透传，
	// 不能用文本 DATA: 前缀 —— 那条路径会经过 TextEncoder，二进制数据会被 UTF-8 改写。
	if err := c.ws.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *simpleWSConn) Close() error {
	if !c.closed.CompareAndSwap(false, true) {
		return c.closeErr
	}
	if c.stopPing != nil {
		close(c.stopPing)
	}
	c.writeMu.Lock()
	_ = c.ws.WriteMessage(websocket.TextMessage, []byte("CLOSE"))
	c.writeMu.Unlock()
	c.closeErr = c.ws.Close()
	return c.closeErr
}

// startKeepAlive 起一个后台协程周期发 ping，直到连接关闭。
func (c *simpleWSConn) startKeepAlive() {
	if c.stopPing == nil {
		return
	}
	go func() {
		t := time.NewTicker(wsPingInterval)
		defer t.Stop()
		for {
			select {
			case <-c.stopPing:
				return
			case <-t.C:
				if c.closed.Load() {
					return
				}
				deadline := time.Now().Add(wsPingTimeout)
				if err := c.ws.WriteControl(websocket.PingMessage, []byte("k"), deadline); err != nil {
					_ = c.Close()
					return
				}
			}
		}
	}()
}

func (c *simpleWSConn) LocalAddr() net.Addr  { return c.ws.LocalAddr() }
func (c *simpleWSConn) RemoteAddr() net.Addr { return c.ws.RemoteAddr() }

func (c *simpleWSConn) SetDeadline(t time.Time) error {
	_ = c.ws.SetReadDeadline(t)
	return c.ws.SetWriteDeadline(t)
}
func (c *simpleWSConn) SetReadDeadline(t time.Time) error  { return c.ws.SetReadDeadline(t) }
func (c *simpleWSConn) SetWriteDeadline(t time.Time) error { return c.ws.SetWriteDeadline(t) }

// pickIP 从可用 IP 列表取一个，没配就返回空串（直接解析服务器域名）。
//
// 列表由后台存活+吞吐筛选给出（见 tun_iprank.go），按质量降序排列。
// 处于拨号失败冷却期（见 markEdgeFail）的 IP 会被跳过；全部都在冷却时
// 退回全量列表 —— 宁可多等一次超时，也不落到"没有 IP 可用"。
//
// 2026-11-13：轮转 → 粘性主选（取首位）。吞吐门槛后存活候选只有 1~3 个，
// 原来的轮转会让视频分段这类大流量连接散到慢边缘上，把实测 20MB/s 稀释成
// 若干个 1~2MB/s；粘住首位（吞吐冠军），主选拨号失败经 markEdgeFail 冷却
// 60 秒后自然由次位接管，恢复后自动回切 —— 保住吞吐的同时有了接管深度。
func (p *ECHPool) pickIP() string {
	p.targetIPsMu.RLock()
	ips := p.targetIPs
	var alive []string
	if len(ips) > 0 {
		now := time.Now()
		for _, ip := range ips {
			if until, bad := p.edgeFailUntil[ip]; !bad || now.After(until) {
				alive = append(alive, ip)
			}
		}
	}
	p.targetIPsMu.RUnlock()
	if len(alive) == 0 {
		alive = ips
	}
	if len(alive) == 0 {
		return ""
	}
	return alive[0]
}

// 边缘 IP 拨号失败后的冷却时长。
const edgeFailCooldown = 60 * time.Second

// markEdgeFail 把一条边缘 IP 冷却一小段时间：这期间 pickIP 会跳过它。
// 只在"传输层到不了边缘"（拨号超时/握手断开）时调用；服务端明确应答
// （ERROR: 拒绝）说明边缘是好的，不能冷却。
func (p *ECHPool) markEdgeFail(ip string) {
	if ip == "" {
		return
	}
	p.targetIPsMu.Lock()
	p.edgeFailUntil[ip] = time.Now().Add(edgeFailCooldown)
	p.targetIPsMu.Unlock()
}

// markEdgeOK 拨号成功时清掉该边缘的冷却记录（如果有），让它在下一轮
// 轮转里立即恢复参与。
func (p *ECHPool) markEdgeOK(ip string) {
	if ip == "" {
		return
	}
	p.targetIPsMu.Lock()
	delete(p.edgeFailUntil, ip)
	p.targetIPsMu.Unlock()
}

// clearEdgeFails 存活探测跑完一轮后调用：探测结果比几十秒前的失败记录
// 更可信，全部解冻。
func (p *ECHPool) clearEdgeFails() {
	p.targetIPsMu.Lock()
	p.edgeFailUntil = make(map[string]time.Time)
	p.targetIPsMu.Unlock()
}

// errEdgeUnreachable 标记"传输层到不了边缘"（拨号/握手失败），
// 与"服务端明确拒绝"区分开 —— 前者要换边缘重试，后者不该重试。
var errEdgeUnreachable = errors.New("边缘不可达")

// ======================== 空闲「裸 WebSocket」预热池 ========================
//
// 每条 TCP 连接要新建一条 WebSocket：TCP+TLS 到边缘 ~0.3s、WS 升级 ~0.2s、
// 等 CONNECTED ~0.2s，单条新连接的固定开销 ~0.7s。浏览器打开一个网页要并发
// 建几条连接（YouTube 分段、每 8 秒轮询一次的后台应用……），这些钱就一笔笔
// 重复交。池里存"还没发 CONNECT 的裸 WS"，借出时现场发 CONNECT——CONNECT
// 这一步省不掉，但前面三步全省。
//
// 上一版预热池被移除的教训是"发出已被服务端悄悄关掉的死连接"。这次的约束：
//   - 只存裸 WS，借出现场 CONNECT，失败立刻回退全新拨号，绝不会把死连接
//     当成可用链路交付；
//   - 借出后等 CONNECTED 只给 2s（全新拨号是 8s），死连接快速暴露；
//   - TTL 20s：远小于 CF 对空闲 WS 的清理周期，过期直接丢弃；
//   - 后台补货单飞，池上限 3 条，不会形成建连风暴。
const (
	wsPoolCap            = 6
	wsPoolTTL            = 20 * time.Second
	wsPoolConnectTimeout = 2 * time.Second
)

type pooledWS struct {
	ws   *websocket.Conn
	born time.Time
}

// wsPoolTake 从池里取一条未过期的裸 WS；没有则返回 nil。
func (p *ECHPool) wsPoolTake() *websocket.Conn {
	p.wsPoolMu.Lock()
	defer p.wsPoolMu.Unlock()
	now := time.Now()
	for len(p.wsPoolIdle) > 0 {
		c := p.wsPoolIdle[len(p.wsPoolIdle)-1]
		p.wsPoolIdle = p.wsPoolIdle[:len(p.wsPoolIdle)-1]
		if now.Sub(c.born) <= wsPoolTTL {
			return c.ws
		}
		_ = c.ws.Close()
	}
	return nil
}

// wsPoolPut 把一条裸 WS 放回池；池满则直接关掉。
func (p *ECHPool) wsPoolPut(ws *websocket.Conn) {
	if ws == nil {
		return
	}
	p.wsPoolMu.Lock()
	if len(p.wsPoolIdle) < wsPoolCap {
		p.wsPoolIdle = append(p.wsPoolIdle, pooledWS{ws: ws, born: time.Now()})
		p.wsPoolMu.Unlock()
		return
	}
	p.wsPoolMu.Unlock()
	_ = ws.Close()
}

// wsPoolKick 后台补货：把池填到容量上限。
//
// 2026-11-13：原来是「单飞 + 串行补满」——同一时刻只许一条拨号在跑，池里缺 6 条
// 就依次拨 6 次，每次都是一整个跨洋往返（TCP+TLS(ECH)+WS 升级，实测 0.7~1.4s）。
// 抽干之后补货期间进来的请求全都得自己承担完整握手，网页就是几十条请求同时
// 撞在这个窗口上，于是"视频不卡、网页很慢"。这里没有资源预算的问题，缺的只是
// 愿意同时多拨几条的那点并发。
//
// 现在：缺 k 条就并发发 k 条（上限 wsPoolBurst 条），池满即止。拨号目标轮转、
// 边缘冷却表、拨号本身都已是并发安全的（pickIP 走 RLock + 原子计数，
// markEdge* 各自加锁，dialWebSocketWithECH 只读池状态）。
const (
	// 单轮最多并发补几条。池上限 6，故 6 足够一次填满；不取更大值，
	// 避免少数极端场景（大量连接瞬间关闭）把 CF 边缘打出瞬时并发。
	wsPoolBurst = 6
)

func (p *ECHPool) wsPoolKick() {
	if echPool == nil || !p.wsPoolRefilling.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer p.wsPoolRefilling.Store(false)

		p.wsPoolMu.Lock()
		need := wsPoolCap - len(p.wsPoolIdle)
		p.wsPoolMu.Unlock()
		if need <= 0 {
			return
		}
		// 已有在飞的补货（上一次 Kick 还在拨）就按剩余缺口来，别叠加爆池。
		if inFlight := int(p.wsPoolInflight.Load()); inFlight > 0 {
			need -= inFlight
			if need <= 0 {
				return
			}
		}
		if need > wsPoolBurst {
			need = wsPoolBurst
		}
		p.wsPoolInflight.Add(int32(need))

		var wg sync.WaitGroup
		for i := 0; i < need; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				// 自己也占一个在飞名额：拨完（不论成败）立刻归还，
				// 让紧随其后的 Kick 看到的缺口是真实的。
				defer p.wsPoolInflight.Add(-1)
				ip := p.pickIP()
				ws, err := p.dialWebSocketWithECH(p.wsServerAddr, 1, ip, "", 0)
				if err != nil {
					// 冷却该边缘，但**不中止其他在飞的补货**：
					// 一条边缘坏不代表另一条也坏（原实现 return 掉整轮）。
					p.markEdgeFail(ip)
					return
				}
				p.markEdgeOK(ip)
				p.wsPoolPut(ws)
			}()
		}
		wg.Wait()
	}()
}

// dialSimpleWS 为一个目标地址开一条新的 WebSocket 并完成 CONNECT 握手。
func dialSimpleWS(target string) (net.Conn, error) {
	// 直连模式：每次新建 WebSocket（与 ech-wk 客户端行为一致）。
	// 预热池（含 dialGate 并发闸门）在 CF 简易服务端下既可能发出
	// "已被服务端悄悄关掉的死连接"，又会把并发握手限死在 6 条 ——
	// YouTube 这种多连接大流量一上来就被卡在并发闸门上，吞吐上不去。
	return dialSimpleWSTimeout(target, simpleConnectTimeout)
}

func dialSimpleWSTimeout(target string, timeout time.Duration) (net.Conn, error) {
	if echPool == nil {
		return nil, errors.New("连接池未初始化")
	}

	// 先看预热池：有现成的裸 WS 就直接在上面 CONNECT。等待 CONNECTED 的
	// 截止收窄到 2s——预热连接超过 20s 就会被丢弃，若真遇上一条半死的，
	// 也只损失 2s 就回退全新拨号，绝不会拿死连接交付。
	if ws := echPool.wsPoolTake(); ws != nil {
		if conn, ferr := simpleWSHandshake(ws, target, min(wsPoolConnectTimeout, timeout)); ferr == nil {
			echPool.wsPoolKick()
			return conn, nil
		}
		_ = ws.Close()
	}
	echPool.wsPoolKick()

	// 边缘 IP 会在分钟级时间内"变死"（拨号 i/o timeout，实测同一 IP 几分钟
	// 内从可用翻到全超时），而存活探测 5 分钟才跑一轮，跟不上这个节奏。
	// 所以应对就放在拨号路径上：失败立刻换下一个 IP 再试一次，并把刚失败
	// 的边缘冷却 60 秒。
	const attempts = 2
	var lastErr error
	for i := 0; i < attempts; i++ {
		ip := echPool.pickIP()
		ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, ip, "", 0)
		if err != nil {
			echPool.markEdgeFail(ip)
			lastErr = err
			continue
		}
		conn, ferr := simpleWSHandshake(ws, target, timeout)
		if ferr == nil {
			echPool.markEdgeOK(ip)
			echPool.wsPoolKick()
			return conn, nil
		}
		_ = ws.Close()
		if errors.Is(ferr, errEdgeUnreachable) {
			echPool.markEdgeFail(ip)
			lastErr = ferr
			continue
		}
		// 服务端明确应答（拒绝/关闭）：边缘是好的，问题出在目标本身。
		return nil, ferr
	}
	return nil, lastErr
}

// simpleWSHandshake 在已建立的 WebSocket 上完成 CONNECT 握手并包装成 net.Conn。
// 传输层失败统一包 errEdgeUnreachable 返回；服务端明确应答原样返回。
func simpleWSHandshake(ws *websocket.Conn, target string, timeout time.Duration) (net.Conn, error) {
	start := time.Now()
	// 首帧留空：那个字段在服务端会过 TextEncoder，塞二进制进去必然被改写。
	// 真正的数据等 CONNECTED 之后用二进制帧发。
	_ = ws.SetWriteDeadline(time.Now().Add(timeout))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:"+target+"|")); err != nil {
		return nil, fmt.Errorf("%w: 发送 CONNECT 失败: %v", errEdgeUnreachable, err)
	}

	_ = ws.SetReadDeadline(time.Now().Add(timeout))
	for {
		mt, data, err := ws.ReadMessage()
		if err != nil {
			return nil, fmt.Errorf("%w: 等待 CONNECTED 失败: %v", errEdgeUnreachable, err)
		}
		if mt != websocket.TextMessage {
			// 理论上不该在 CONNECTED 之前收到二进制，收到就当它是数据，继续等
			continue
		}
		text := string(data)
		switch {
		case text == "CONNECTED":
			// 建连耗时 = TCP + TLS(ECH) + WS 升级 + CONNECT 四个往返。
			// 正常几十毫秒，几百毫秒以上说明入口或链路有问题（Win 版实测：
			// 慢握手连接的传输中位只有正常连接的 1/15）—— 打日志供排查。
			if el := time.Since(start); el >= 600*time.Millisecond {
				log.Printf("[建连] %s 慢握手 %dms", target, el.Milliseconds())
			}
			_ = ws.SetReadDeadline(time.Time{})
			_ = ws.SetWriteDeadline(time.Time{})
			c := &simpleWSConn{ws: ws, stopPing: make(chan struct{})}
			c.startKeepAlive()
			return c, nil
		case strings.HasPrefix(text, "ERROR:"):
			return nil, fmt.Errorf("服务端拒绝: %s", strings.TrimPrefix(text, "ERROR:"))
		case text == "CLOSE":
			return nil, errors.New("服务端主动关闭")
		}
	}
}

// probeSimpleProtocol 探测服务端是不是这种「简易 WebSocket 代理」。
// 拿一个必然存在的目标试一次 CONNECT，能收到 CONNECTED 就说明是。
func probeSimpleProtocol() bool {
	if echPool == nil {
		return false
	}
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, echPool.pickIP(), "", 0)
	if err != nil {
		return false
	}
	defer ws.Close()

	// 探测目标特意避开 Cloudflare 自家网段：Worker 的 connect() 不允许连回 CF，
	// 拿 1.1.1.1 去探会稳定收到 ERROR，白白误导判断。
	// 超时给足 10s：ECH 查询 + TLS 握手 + WS 升级可能就要好几秒，
	// 之前 4s 在 DoH 刚恢复/链路慢时不够，探测误判成 smux → simple 服务端黑洞。
	_ = ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:8.8.8.8:53|")); err != nil {
		return false
	}

	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	mt, data, err := ws.ReadMessage()
	if err != nil {
		// 没有任何回应 —— x-tunnel 服务端就是这个反应，它在等 smux 帧
		return false
	}
	if mt != websocket.TextMessage {
		return false
	}
	text := string(data)
	// CONNECTED 固然是肯定答复，ERROR: 同样说明服务端读懂了 CONNECT 指令，
	// 只是那个目标它连不上而已 —— 两者都足以判定这是简易 WebSocket 代理。
	return text == "CONNECTED" || strings.HasPrefix(text, "ERROR:")
}
