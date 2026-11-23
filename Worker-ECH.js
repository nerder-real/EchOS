const WS_READY_STATE_OPEN = 1;
const WS_READY_STATE_CLOSING = 2;
const CF_FALLBACK_IPS = ['ProxyIP.CMLiussss.net'];// cm维护

// 代码写死的兜底 token：环境变量 TOKEN 优先，未设置时用此值。
// 留空 = 要求 App 也必须留空才能连；App 填了任意非空值会被拒绝（401）。
const DEFAULT_TOKEN = '';

// 复用 TextEncoder，避免重复创建
const encoder = new TextEncoder();

import { connect } from 'cloudflare:sockets';

export default {
  async fetch(request, env, ctx) {
    try {
      const token = env.TOKEN || DEFAULT_TOKEN; // 环境变量优先，代码写死兜底
      const upgradeHeader = request.headers.get('Upgrade');
      
      if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
        return new URL(request.url).pathname === '/' 
          ? new Response('WebSocket Proxy Server', { status: 200 })
          : new Response('Expected WebSocket', { status: 426 });
      }

      // 无论 token 是否为空都校验：App 填的必须与服务端生效值完全一致，
      // 不一致（包括服务端为空而 App 填了值）一律 401 拒绝。
      if ((request.headers.get('Sec-WebSocket-Protocol') || '') !== token) {
        return new Response('Unauthorized', { status: 401 });
      }

      const [client, server] = Object.values(new WebSocketPair());
      server.accept();
      
      handleSession(server).catch(() => safeCloseWebSocket(server));

      // 修复 spread 类型错误
      const responseInit = {
        status: 101,
        webSocket: client
      };
      
      if (token) {
        responseInit.headers = { 'Sec-WebSocket-Protocol': token };
      }

      return new Response(null, responseInit);
      
    } catch (err) {
      return new Response(err.toString(), { status: 500 });
    }
  },
};

async function handleSession(webSocket) {
  let remoteSocket, remoteWriter, remoteReader;
  let isClosed = false;
  // ===== 诊断计数（2026-11-22 排查 ZCode 中流断连）：tail 时定位死因用 =====
  let curTarget = '';
  let upBytes = 0;   // 客户端 → 目标（已写入远端 socket 的字节）
  let downBytes = 0; // 目标 → 客户端（已从远端读出的字节）

  const cleanup = () => {
    if (isClosed) return;
    isClosed = true;
    
    try { remoteWriter?.releaseLock(); } catch {}
    try { remoteReader?.releaseLock(); } catch {}
    try { remoteSocket?.close(); } catch {}
    
    remoteWriter = remoteReader = remoteSocket = null;
    safeCloseWebSocket(webSocket);
  };

  const pumpRemoteToWebSocket = async () => {
    try {
      while (!isClosed && remoteReader) {
        const { done, value } = await remoteReader.read();

        if (done) break;
        if (webSocket.readyState !== WS_READY_STATE_OPEN) break;
        if (value?.byteLength > 0) {
          downBytes += value.byteLength;
          webSocket.send(value);
        }
      }
    } catch (err) {
      // 远端读取异常（对端 RST / 网络中断）：此前被静默吞掉，tail 看不到死因
      console.log(`[ECH] REMOTE READ FAIL ${curTarget} up=${upBytes} down=${downBytes} err=${err?.message || err}`);
    }

    if (!isClosed) {
      if (!isClosed && remoteReader) {
        console.log(`[ECH] REMOTE EOF ${curTarget} up=${upBytes} down=${downBytes}`);
      }
      try { webSocket.send('CLOSE'); } catch {}
      cleanup();
    }
  };

  const parseAddress = (addr) => {
    if (addr[0] === '[') {
      const end = addr.indexOf(']');
      return {
        host: addr.substring(1, end),
        port: parseInt(addr.substring(end + 2), 10)
      };
    }
    const sep = addr.lastIndexOf(':');
    return {
      host: addr.substring(0, sep),
      port: parseInt(addr.substring(sep + 1), 10)
    };
  };

  const isCFError = (err) => {
    const msg = err?.message?.toLowerCase() || '';
    return msg.includes('proxy request') || 
           msg.includes('cannot connect') || 
           msg.includes('cloudflare');
  };

  const connectToRemote = async (targetAddr, firstFrameData) => {
    curTarget = targetAddr;
    console.log(`[ECH] CONNECT ${targetAddr} first=${firstFrameData ? firstFrameData.length : 0}B`);
    const { host, port } = parseAddress(targetAddr);
    const attempts = [null, ...CF_FALLBACK_IPS];

    for (let i = 0; i < attempts.length; i++) {
      try {
        remoteSocket = connect({
          hostname: attempts[i] || host,
          port
        });

        if (remoteSocket.opened) await remoteSocket.opened;

        remoteWriter = remoteSocket.writable.getWriter();
        remoteReader = remoteSocket.readable.getReader();
        console.log(`[ECH] CONNECTED ${targetAddr} attempt=${i + 1}/${attempts.length}${attempts[i] ? ' (via ProxyIP)' : ''}`);

        // 发送首帧数据
        if (firstFrameData) {
          await remoteWriter.write(encoder.encode(firstFrameData));
        }

        webSocket.send('CONNECTED');
        pumpRemoteToWebSocket();
        return;

      } catch (err) {
        console.log(`[ECH] CONNECT FAIL ${targetAddr} attempt=${i + 1}/${attempts.length} err=${err?.message || err}`);
        // 清理失败的连接
        try { remoteWriter?.releaseLock(); } catch {}
        try { remoteReader?.releaseLock(); } catch {}
        try { remoteSocket?.close(); } catch {}
        remoteWriter = remoteReader = remoteSocket = null;

        // 如果不是 CF 错误或已是最后尝试，抛出错误
        if (!isCFError(err) || i === attempts.length - 1) {
          throw err;
        }
      }
    }
  };

  webSocket.addEventListener('message', async (event) => {
    if (isClosed) return;

    try {
      const data = event.data;

      if (typeof data === 'string') {
        if (data.startsWith('CONNECT:')) {
          const sep = data.indexOf('|', 8);
          await connectToRemote(
            data.substring(8, sep),
            data.substring(sep + 1)
          );
        }
        else if (data.startsWith('DATA:')) {
          if (remoteWriter) {
            await remoteWriter.write(encoder.encode(data.substring(5)));
          }
        }
        else if (data === 'CLOSE') {
          cleanup();
        }
      }
      else if (data instanceof ArrayBuffer && remoteWriter) {
        upBytes += data.byteLength;
        await remoteWriter.write(new Uint8Array(data));
      }
    } catch (err) {
      // 写远端失败 = Worker↔目标 的 socket 在中流被掐：打印目标、已传字节数
      // 与完整错误，这是「Network connection lost」类断连的唯一观测点
      console.log(`[ECH] WRITE FAIL ${curTarget} up=${upBytes} down=${downBytes} err=${err?.message || err} stack=${err?.stack?.split('\n')[0] || ''}`);
      try { webSocket.send('ERROR:' + err.message); } catch {}
      cleanup();
    }
  });

  webSocket.addEventListener('close', cleanup);
  webSocket.addEventListener('error', cleanup);
}

function safeCloseWebSocket(ws) {
  try {
    if (ws.readyState === WS_READY_STATE_OPEN || 
        ws.readyState === WS_READY_STATE_CLOSING) {
      ws.close(1000, 'Server closed');
    }
  } catch {}
}
