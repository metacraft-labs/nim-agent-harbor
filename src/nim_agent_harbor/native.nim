## Native HTTP and incremental SSE transports. Each operation owns its HTTP
## client so prompt delivery and cancellation can run on separate threads.
import std/[httpclient, httpcore, asyncdispatch, asyncnet, asyncstreams, json, strutils]
import nim_everywhere
import ./[client, types]

proc requestHeaders(req: nim_everywhere.HttpRequest): HttpHeaders =
  result = newHttpHeaders()
  for h in req.headers: result[h.name] = h.value

proc nativeHarborTransport*(timeoutMs = 30_000): HttpTransport =
  result = proc(req: nim_everywhere.HttpRequest): nim_everywhere.HttpResponse =
    proc control(): Future[nim_everywhere.HttpResponse] {.async.} =
      let http = newAsyncHttpClient()
      defer: http.close()
      proc exchange(): Future[nim_everywhere.HttpResponse] {.async.} =
        let resp = await http.request(req.url,
          httpMethod = parseEnum[httpcore.HttpMethod]($req.httpMethod),
          body = req.body, headers = requestHeaders(req))
        result.status = int(resp.code)
        result.body = await resp.body
        for name, value in resp.headers: result.headers.add header(name, value)
      let pending = exchange()
      if timeoutMs < 0: return await pending
      if not (await asyncdispatch.withTimeout(pending, timeoutMs)):
        # Closing the socket cancels pending headers/body reads. Do not leave
        # a timed-out request running on the worker's event dispatcher.
        # Close/unregister the socket explicitly, including a connection
        # which has not yet reached HttpClient.connected. Never await the
        # discarded read future: Nim does not resolve it after unregistering.
        # It has no remaining socket/event source and is local to this call.
        let socket = http.getSocket()
        if socket != nil: socket.close()
        http.close()
        raise newException(HarborError, "Harbor control request deadline exceeded")
      return await pending
    waitFor control()

proc nativeHarborStream*(timeoutMs = 1_800_000): HarborStreamTransport =
  result = proc(req: nim_everywhere.HttpRequest; onEvent: HarborStreamCallback) =
    proc consume() {.async.} =
      let http = newAsyncHttpClient()
      defer: http.close()
      let request = http.request(req.url, headers = requestHeaders(req))
      if not (await asyncdispatch.withTimeout(request, timeoutMs)):
        raise newException(HarborError, "Harbor event stream connection timed out")
      let resp = await request
      if int(resp.code) < 200 or int(resp.code) >= 300:
        raise newException(HarborError, await resp.body)
      var pending = ""
      var data: seq[string] = @[]
      var cursor = ""
      while true:
        let next = resp.bodyStream.read()
        if not (await asyncdispatch.withTimeout(next, timeoutMs)):
          raise newException(HarborError, "Harbor event stream timed out")
        let (available, chunk) = await next
        if not available:
          raise newException(HarborError, "Harbor event stream closed before the turn ended")
        pending.add chunk
        while true:
          let eol = pending.find('\n')
          if eol < 0: break
          let line = pending[0 ..< eol].strip(leading = false, chars = {'\r'})
          pending = pending[eol + 1 .. ^1]
          if line.len == 0:
            if data.len > 0:
              let event = eventFromJson(parseJson(data.join("\n")))
              data.setLen(0)
              if not onEvent(event, cursor): return
              cursor = ""
          elif line.startsWith("data:"):
            data.add line[5 .. ^1].strip(leading = true, trailing = false)
          elif line.startsWith("id:"):
            cursor = line[3 .. ^1].strip()
    waitFor consume()

proc newNativeHarborClient*(baseUrl: string;
    auth = HarborAuth(kind: akNone)): HarborClient =
  result = newHarborClient(baseUrl, nativeHarborTransport(), auth)
  result.streamTransport = nativeHarborStream()
