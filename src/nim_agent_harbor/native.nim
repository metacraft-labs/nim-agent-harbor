## Native HTTP and incremental SSE transports. Each operation owns its HTTP
## client so prompt delivery and cancellation can run on separate threads.
import std/[httpclient, httpcore, asyncdispatch, asyncnet, asyncstreams, json, strutils]
import std/os
when defined(windows):
  import std/winlean
else:
  import std/posix
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
      var pendingRead: Future[(bool, string)]
      proc shutdownReceive() =
        let socket = http.getSocket()
        if socket != nil and not socket.isClosed():
          # SHUT_RD / SD_RECEIVE are both zero. Do not release the descriptor.
          if shutdown(socket.getFd(), 0.cint) != 0:
            when defined(windows):
              raiseOSError(OSErrorCode(WSAGetLastError()))
            else:
              raiseOSError(osLastError())
      proc stopReader(resp: AsyncResponse) {.async.} =
        # Settle the owned background parser before releasing its descriptor.
        shutdownReceive()
        proc drain() {.async.} =
          while true:
            try:
              # FutureStream supports one active reader. Reuse a timed-out
              # read rather than replacing its callback with a second read.
              let next = if pendingRead != nil and not pendingRead.finished:
                pendingRead else: resp.bodyStream.read()
              pendingRead = nil
              let (available, _) = await next
              if not available: return
            except ProtocolError as error:
              # Only the incomplete body caused by our deliberate local EOF is
              # expected. Invalid wire data and unrelated close errors fail.
              let message = error.msg.split("\nAsync traceback:\n", 1)[0]
              var localEof = message in ["Server terminated connection prematurely",
                "Got disconnected while trying to read body."]
              if not localEof:
                # The standard parser reports a partial Content-Length body
                # with exact declared/received counts. Match the complete
                # diagnostic against this response's valid declared length.
                let declared = resp.headers.getOrDefault("Content-Length")
                let parts = message.split(" got: ", 1)
                if declared.len > 0 and declared.allCharsInSet({'0'..'9'}) and
                    parts.len == 2 and parts[1].len > 0 and
                    parts[1].allCharsInSet({'0'..'9'}):
                  try:
                    let wanted = declared.parseInt()
                    let received = parts[1].parseInt()
                    localEof = wanted > 0 and received > 0 and received < wanted and
                      message == "Received length doesn't match expected length. Wanted " &
                        $wanted & " got: " & $received
                  except ValueError:
                    discard # Invalid/overflowing lengths retain ProtocolError.
              if not localEof:
                raise
              return
        let settled = drain()
        if not (await asyncdispatch.withTimeout(settled, 1000)):
          raise newException(HarborError, "Harbor event stream reader did not stop")
        await settled
      let request = http.request(req.url, headers = requestHeaders(req))
      if not (await asyncdispatch.withTimeout(request, timeoutMs)):
        shutdownReceive()
        try:
          if not (await asyncdispatch.withTimeout(request, 1000)):
            raise newException(HarborError, "Harbor event stream reader did not stop")
          let response = await request
          await stopReader(response)
        except ProtocolError as error:
          if error.msg.split("\nAsync traceback:\n", 1)[0] !=
              "Connection was closed before full request has been made":
            raise
        raise newException(HarborError, "Harbor event stream connection timed out")
      let resp = await request
      var pending = ""
      var data: seq[string] = @[]
      var cursor = ""
      try:
        if int(resp.code) < 200 or int(resp.code) >= 300:
          raise newException(HarborError, await resp.body)
        while true:
          let next = resp.bodyStream.read()
          pendingRead = next
          if not (await asyncdispatch.withTimeout(next, timeoutMs)):
            raise newException(HarborError, "Harbor event stream timed out")
          let (available, chunk) = await next
          pendingRead = nil
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
      finally:
        await stopReader(resp)
    waitFor consume()

proc newNativeHarborClient*(baseUrl: string;
    auth = HarborAuth(kind: akNone)): HarborClient =
  result = newHarborClient(baseUrl, nativeHarborTransport(), auth)
  result.streamTransport = nativeHarborStream()
