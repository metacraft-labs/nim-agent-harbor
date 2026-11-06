## The external HTTP service is a controlled real TCP peer so an SSE body can
## deliberately remain open at consumer stop. No sockets, transport, dispatcher,
## body parser or cancellation are mocked. Read-only dispatcher inspection proves
## the pending-read precondition on POSIX; Windows uses its IOCP implementation.
when not defined(futureLogging):
  {.error: "This lifecycle suite requires -d:futureLogging to observe real reader ownership".}
import std/[net, os, strutils, sequtils, atomics, unittest, asyncdispatch, httpclient, tables]
when not defined(windows): import std/selectors
import nim_everywhere
import nim_agent_harbor/[native, types, client]

type
  PeerState = ref object
    disconnected: Atomic[bool]
    releaseInvalid: Atomic[bool]
  PeerArgs = tuple[listener: Socket, mode: string, state: PeerState]

proc serve(args: PeerArgs) {.thread.} =
  var peer: Socket
  args.listener.accept(peer)
  defer: peer.close()
  var request = ""
  while true:
    let line = peer.recvLine()
    if line.len == 0 or line == "\r\n": break
    request.add(line & "\n")
  doAssert request.startsWith("GET /events HTTP/1.1")
  doAssert request.splitLines.anyIt(it.toLowerAscii.startsWith("authorization:") and
    it.split(':', 1)[1].strip == "Bearer fixture-token")
  if args.mode == "headers-timeout":
    peer.send("HTTP/1.1 200 OK\r\n", flags = {})
    args.state.disconnected.store(peer.recv(1, timeout = 2000).len == 0)
    return
  let first = "id: actual-cursor\ndata: {\"type\":\"status\","
  let second = "\"status\":\"running\",\"padding\":\"" & repeat('x', 8192) & "\"}\n\n"
  if args.mode == "length-stop":
    # AsyncSocket's buffered recv waits for full BufferSize reads. Deliver a
    # complete event plus valid SSE comment in full buffers, then keep the next
    # declared body buffer pending until the subscriber shuts down receive.
    let receivedLength = ((first.len + second.len) div BufferSize + 1) * BufferSize
    let padding = ":" & repeat('x', receivedLength - first.len - second.len - 2) & "\n"
    peer.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: " &
      $(receivedLength + BufferSize) & "\r\n\r\n" & first & second & padding, flags = {})
    args.state.disconnected.store(peer.recv(1, timeout = 2000).len == 0)
    return
  peer.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n", flags = {})
  if args.mode == "invalid":
    peer.send("not-a-chunk\r\n", flags = {})
    return
  for data in [first, second]:
    peer.send(toHex(data.len) & "\r\n" & data & "\r\n", flags = {})
  if args.mode == "invalid-after-event":
    while not args.state.releaseInvalid.load(): sleep(1)
    peer.send("not-a-chunk\r\n", flags = {})
  elif args.mode in ["eof", "stop-eof"]:
    peer.send("0\r\n\r\n", flags = {})
  else:
    args.state.disconnected.store(peer.recv(1, timeout = 2000).len == 0)

proc pendingReads(): int =
  when not defined(windows):
    # The dedicated test dispatcher owns only this stream, and the fixture owns
    # no other asynchronous sockets. Inspect actual registered read callbacks.
    for fd in 0..<1024:
      if getGlobalDispatcher().contains(AsyncFD(fd)):
        let data = getGlobalDispatcher().getIoHandler().getData(fd)
        for name, value in fieldPairs(data):
          when name == "readList": result += value.len

proc pendingBodyReaders(): int =
  for info, count in getFuturesInProgress():
    if info.fromProc == "parseBody": result += count

proc pendingStreamReads(): int =
  for info, count in getFuturesInProgress():
    if info.fromProc == "FutureStream.take": result += count

suite "native SSE reader ownership":
  for mode in ["stop", "length-stop", "stop-eof", "eof", "invalid", "invalid-after-event",
      "callback-error", "body-timeout", "headers-timeout"]:
    test mode:
      let listener = newSocket()
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      defer: listener.close()
      let state = PeerState()
      var worker: Thread[PeerArgs]
      createThread(worker, serve, (listener, mode, state))
      var events = 0
      var ownershipObserved = false
      let callback: HarborStreamCallback = proc(event: HarborEvent; cursor: string): bool =
        inc events
        check cursor == "actual-cursor"
        when not defined(windows):
          if mode in ["stop", "length-stop", "callback-error"]:
            check pendingReads() == 1
            check pendingBodyReaders() == 1
            var streamFd = AsyncFD(-1)
            for fd in 0..<1024:
              if getGlobalDispatcher().contains(AsyncFD(fd)): streamFd = AsyncFD(fd)
            check int(streamFd) >= 0
            # Observe the real body future before its queued continuation runs.
            # A reader may not retain a pending operation on a released FD.
            callSoon(proc() {.gcsafe.} =
              check pendingBodyReaders() == 1
              check getGlobalDispatcher().contains(streamFd)
              ownershipObserved = true
              if mode == "length-stop":
                checkpoint("Real finite-length SSE event and pending reader ownership observed"))
        if mode == "invalid-after-event":
          state.releaseInvalid.store(true)
          # Let the real malformed next chunk reach the body parser before
          # requested stop. Its ProtocolError must remain visible during drain.
          waitFor sleepAsync(10)
        if mode == "callback-error":
          raise newException(ValueError, "actual subscriber failure")
        mode in ["eof", "body-timeout"]
      let request = nim_everywhere.HttpRequest(httpMethod: hmGet,
        url: "http://127.0.0.1:" & $listener.getLocalAddr()[1] & "/events",
        headers: @[header("Authorization", "Bearer fixture-token")])
      try:
        if mode in ["stop", "length-stop", "stop-eof"]:
          nativeHarborStream(1000)(request, callback)
        elif mode == "eof":
          expect HarborError:
            nativeHarborStream(1000)(request, callback)
        elif mode in ["invalid", "invalid-after-event"]:
          expect ProtocolError:
            nativeHarborStream(1000)(request, callback)
        elif mode == "callback-error":
          try:
            nativeHarborStream(1000)(request, callback)
            check false
          except ValueError as error:
            check error.msg.split("\nAsync traceback:\n", 1)[0] == "actual subscriber failure"
        else:
          try:
            nativeHarborStream(100)(request, callback)
            check false
          except HarborError as error:
            check error.msg.split("\nAsync traceback:\n", 1)[0] ==
              (if mode == "headers-timeout": "Harbor event stream connection timed out"
               else: "Harbor event stream timed out")
      finally:
        joinThread(worker)
      check events == (if mode in ["invalid", "headers-timeout"]: 0 else: 1)
      if mode in ["stop", "length-stop", "callback-error", "body-timeout", "headers-timeout"]:
        check state.disconnected.load()
      when not defined(windows):
        if mode in ["stop", "length-stop", "callback-error"]: check ownershipObserved
      check pendingBodyReaders() == 0
      check pendingStreamReads() == 0
      when not defined(windows): check pendingReads() == 0
      # Reuse the same dispatcher with a real second TCP request, not only a
      # timer. The next stop must retain its original event/cursor and disconnect.
      let nextState = PeerState()
      createThread(worker, serve, (listener, "stop", nextState))
      var nextEvents = 0
      let nextCallback: HarborStreamCallback = proc(event: HarborEvent; cursor: string): bool =
        inc nextEvents
        check cursor == "actual-cursor"
        false
      try:
        nativeHarborStream(1000)(request, nextCallback)
      finally:
        joinThread(worker)
      check nextEvents == 1
      check nextState.disconnected.load()
      check pendingBodyReaders() == 0
      check pendingStreamReads() == 0
      when not defined(windows): check pendingReads() == 0
