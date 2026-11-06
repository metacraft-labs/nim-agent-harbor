## Real TCP peers control response timing without replacing the HTTP transport.
## They isolate deadlines and socket cleanup from provider/model behavior. All
## headers, bodies and EOF observations cross actual localhost sockets.
import std/[net, os, times, strutils, sequtils, atomics, unittest]
import nim_everywhere
import nim_agent_harbor/[native, types]

type PeerState = ref object
  disconnected: Atomic[bool]
type PeerArgs = tuple[listener: Socket, mode: string, state: PeerState]
proc sendWire(peer: Socket; data: string) =
  peer.send(data, flags = {}) # Surface disconnect instead of SafeDisconn retry.

proc serve(args: PeerArgs) {.thread.} =
  var peer: Socket
  args.listener.accept(peer)
  defer: peer.close()
  try:
    var wire = ""
    while true:
      let line = peer.recvLine()
      wire.add(line & "\n")
      if line.len == 0 or line == "\r\n": break
    doAssert wire.startsWith("POST / HTTP/1.1")
    doAssert peer.recv(5, timeout = 1000) == "hello"
    if args.mode == "success":
      doAssert wire.splitLines.anyIt(it.toLowerAscii.startsWith("authorization:") and
        it.split(':', 1)[1].strip == "Bearer test-token")
      sendWire(peer, "HTTP/1.1 409 Conflict\r\nX-Proof: preserved\r\nContent-Length: 7\r\nConnection: close\r\n\r\ndenied!")
    elif args.mode in ["headers", "unbounded"]:
      sendWire(peer, "HTTP/1.1 200 OK\r\n")
      for i in 0..<12:
        sendWire(peer, "X-Progress-" & $i & ": yes\r\n")
        sleep(100)
      sendWire(peer, "Content-Length: 2\r\nConnection: close\r\n\r\n{}")
    else:
      sendWire(peer, "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n")
      for i in 0..<12:
        sendWire(peer, "x")
        sleep(100)
  except OSError: args.state.disconnected.store(true)
  if args.mode in ["headers", "body"] and not args.state.disconnected.load():
    args.state.disconnected.store(peer.recv(1, timeout = 1000).len == 0)

suite "native control request total deadlines":
  for mode in ["headers", "body", "success", "unbounded"]:
    test mode:
      let listener = newSocket()
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      defer: listener.close()
      var worker: Thread[PeerArgs]
      let state = PeerState()
      createThread(worker, serve, (listener, mode, state))
      let request = nim_everywhere.HttpRequest(httpMethod: hmPost, body: "hello",
        url: "http://127.0.0.1:" & $listener.getLocalAddr()[1],
        headers: @[header("Authorization", "Bearer test-token")])
      let started = epochTime()
      if mode == "success":
        let response = nativeHarborTransport(500)(request)
        check response.status == 409
        check response.body == "denied!"
        check response.headers.anyIt(it.name.toLowerAscii == "x-proof" and it.value == "preserved")
      elif mode == "unbounded":
        let response = nativeHarborTransport(-1)(request)
        check response.status == 200
        check response.body == "{}"
        check epochTime() - started >= 1.0
      else:
        expect HarborError:
          discard nativeHarborTransport(500)(request)
      if mode != "unbounded": check epochTime() - started < 0.8
      joinThread(worker)
      if mode in ["headers", "body"]:
        check state.disconnected.load()
        # A fresh request must work after timeout on the same thread/dispatcher.
        var nextWorker: Thread[PeerArgs]
        createThread(nextWorker, serve, (listener, "success", PeerState()))
        let nextResponse = nativeHarborTransport(500)(request)
        joinThread(nextWorker)
        check nextResponse.status == 409
        check nextResponse.body == "denied!"
