//go:build darwin

package main

// DNS 解析缓存（domain → IP 列表 / 完整应答报文）。
// 从 Windows 版 tun_geosite.go 的「Domain Cache」段移植 —— Mac 版的
// tun_geosite.go 当初裁掉了这一段（本地代理分流用不到），TUN 模式的
// DNS 劫持（tun_dns.go）依赖它，故在此恢复为独立文件。

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"strings"
	"time"
)

func lookupIPsByDomainFamily(domain string, wantIPv6 bool) []string {
	qtype := dnsTypeA
	if wantIPv6 {
		qtype = dnsTypeAAAA
	}
	key := dnsReplyCacheKey(domain, qtype)
	dcMu.RLock()
	defer dcMu.RUnlock()
	e, ok := dc[key]
	if !ok || time.Now().After(e.expireAt) {
		return nil
	}
	var out []string
	for _, ip := range e.ips {
		ip = ip.Unmap()
		if wantIPv6 {
			if ip.Is6() {
				out = append(out, ip.String())
			}
			continue
		}
		if ip.Is4() {
			out = append(out, ip.String())
		}
	}
	return out
}

func lookupIPv4ByDomain(domain string) string {
	ips := lookupIPsByDomainFamily(domain, false)
	if len(ips) > 0 {
		return ips[0]
	}
	return ""
}

func lookupIPv6ByDomain(domain string) string {
	ips := lookupIPsByDomainFamily(domain, true)
	if len(ips) > 0 {
		return ips[0]
	}
	return ""
}

func dnsReplyCacheKey(domain string, qtype uint16) string {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	return fmt.Sprintf("%s|%d", domain, qtype)
}

// lookupDNSCache returns a cached DNS reply for the given domain+qtype,
// or nil if not cached/expired. The caller must set the transaction ID.
func lookupDNSCache(domain string, q []byte) []byte {
	key := dnsReplyCacheKey(domain, dnsQuestionType(q))
	dcMu.RLock()
	defer dcMu.RUnlock()
	e, ok := dcr[key]
	if !ok || time.Now().After(e.expireAt) || len(e.reply) == 0 {
		return nil
	}
	return append([]byte(nil), e.reply...)
}

func cacheDNSReply(domain string, reply []byte) {
	if domain == "" || len(reply) < 12 {
		return
	}
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	qtype := dnsQuestionType(reply)
	if qtype != dnsTypeA && qtype != dnsTypeAAAA {
		return
	}
	var ips []netip.Addr
	var minTTL uint32 = 60
	_, _, qdcount := unpackDNSHeader(reply)
	pos := 12
	for i := 0; i < int(qdcount); i++ {
		for pos < len(reply) {
			if reply[pos] == 0 {
				pos += 5
				break
			}
			if reply[pos]&0xC0 == 0xC0 {
				pos += 2
				if pos+4 <= len(reply) {
					pos += 4
				}
				break
			}
			pos += int(reply[pos]) + 1
		}
	}
	ancount := int(binary.BigEndian.Uint16(reply[6:8]))
	for i := 0; i < ancount && pos+12 <= len(reply); i++ {
		if reply[pos]&0xC0 == 0xC0 {
			pos += 2
		} else {
			for pos < len(reply) && reply[pos] != 0 {
				pos += int(reply[pos]) + 1
			}
			pos++
		}
		if pos+10 > len(reply) {
			break
		}
		rtype := int(reply[pos])<<8 | int(reply[pos+1])
		ttl := uint32(reply[pos+4])<<24 | uint32(reply[pos+5])<<16 | uint32(reply[pos+6])<<8 | uint32(reply[pos+7])
		rdlen := int(reply[pos+8])<<8 | int(reply[pos+9])
		rs := pos + 10
		if qtype == dnsTypeA && rtype == int(dnsTypeA) && rdlen == 4 && rs+4 <= len(reply) {
			if ip, ok := netip.AddrFromSlice(reply[rs : rs+4]); ok {
				ips = append(ips, ip.Unmap())
			}
		} else if qtype == dnsTypeAAAA && rtype == int(dnsTypeAAAA) && rdlen == 16 && rs+16 <= len(reply) {
			if ip, ok := netip.AddrFromSlice(reply[rs : rs+16]); ok {
				ips = append(ips, ip.Unmap())
			}
		}
		pos += 10 + rdlen
		if ttl > 0 && ttl < minTTL {
			minTTL = ttl
		}
	}
	if len(ips) > 0 {
		key := dnsReplyCacheKey(domain, qtype)
		exp := time.Now().Add(time.Duration(minTTL) * time.Second)
		dcMu.Lock()
		dc[key] = &cacheEntry{append([]netip.Addr(nil), ips...), exp}
		dcr[key] = &dnsReplyCacheEntry{append([]byte(nil), reply...), exp}
		// Periodic cleanup: only run every 64 writes to avoid O(n) on every DNS reply
		if dcCleanups.Add(1) >= 64 {
			dcCleanups.Store(0)
			now := time.Now()
			for d, e := range dc {
				if now.After(e.expireAt) {
					delete(dc, d)
				}
			}
			for k, e := range dcr {
				if now.After(e.expireAt) {
					delete(dcr, k)
				}
			}
		}
		dcMu.Unlock()
	}
}
