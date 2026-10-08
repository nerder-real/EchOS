//go:build !windows

package main

// detectPhysIfaceIndexAPI 在非 Windows 平台返回 -1，由上层退回 net.Interfaces 启发式。
func detectPhysIfaceIndexAPI() int { return -1 }
