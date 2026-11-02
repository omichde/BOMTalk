# BOMTalk

Talk to nearby devices running the same app: discovery, auto-connecting and sending typed
`Codable` messages over MultipeerConnectivity – compressed, chunked and reassembled for you.

BOMTalk v2 is a Swift rewrite of the original Objective-C / GameKit version. v1 stays available
at tag [`v1.0`](https://github.com/omichde/BOMTalk/tree/v1.0).

## Features

- Auto-connecting mesh of nearby devices running the same app (same app id and protocol version)
- Typed messages: any `Codable` type conforming to `TalkMessage`
- Send to one peer or broadcast to all connected peers, `async throws`
- Demand driven: a message is only transferred if the receiver listens to its kind
- Large payloads: compressed, chunked and interleaved, with observable progress on both sides (`Transfer.fractionCompleted`)
- Observation for state (`peers`, `transfers`, `isRunning`, `issue`), Combine for messages
- Live custom info per device (`talk.info`), visible as `peer.info` on the others
- No dependencies, no UI, no delegates, no singletons

## Requirements

- iOS 17 / macOS 14
- Swift 6.2 (Xcode 26 or later)

## Installation

Swift Package Manager:

```swift
dependencies: [
	.package(url: "https://github.com/omichde/BOMTalk", from: "2.0.0"),
],
```

or in Xcode: File › Add Package Dependencies… › `https://github.com/omichde/BOMTalk`.

### Info.plist

Local network access needs a usage description and the Bonjour services of your service type
(here `myapp`). If `NSBonjourServices` misses them, `talk.issue` becomes
`TalkError.misconfigured`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to nearby devices running this app.</string>
<key>NSBonjourServices</key>
<array>
	<string>_myapp._tcp</string>
	<string>_myapp._udp</string>
</array>
```

### macOS sandbox

Sandboxed macOS apps need both network entitlements:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

## Quick start

Define a message. `kind` identifies it on the wire and must stay stable across app versions:

```swift
import BOMTalk

struct Chat: TalkMessage {
	static let kind = "chat"
	var text: String
}
```

Create and start a `Talk` (the host app owns it, it is `@MainActor`):

```swift
let talk = Talk(serviceType: "myapp", appID: "com.example.myapp", displayName: "Lobby iPad")
talk.info["role"] = "screen"	// optional, live custom info for other devices, set before start()
talk.start()
```

Subscribe to a message kind. The stream never fails; per-message problems arrive as `.failure`:

```swift
var bag = Set<AnyCancellable>()

talk.messages(Chat.self)
	.sink { result in
		switch result {
		case .success(let received):
			print("\(received.peer.name): \(received.message.text)")
		case .failure(let error):
			print("receive failed: \(error)")
		}
	}
	.store(in: &bag)
```

Send to one peer, or broadcast to all connected peers (encoded once):

```swift
try await talk.send(Chat(text: "Hi"), to: peer)

let results = await talk.send(Chat(text: "Hi all"))	// [Peer.ID: Result<Void, TalkError>]
```

Observe state, e.g. in SwiftUI:

```swift
ForEach(talk.peers) { peer in
	Text("\(peer.name) – \(peer.state)")
}
ForEach(talk.transfers) { transfer in	// Transfer is @Observable
	ProgressView(value: transfer.fractionCompleted)
}
if let issue = talk.issue {
	Text("\(String(describing: issue))")
}
```

## Demand-driven offers

Before any payload is sent, the sender offers the message (kind and size) to the receiver.
The receiver accepts only while at least one subscriber for that kind exists, i.e. a
`talk.messages(Kind.self)` publisher is subscribed. Otherwise the offer is rejected, nothing is
transferred and the sender gets `TalkError.notWanted`. Cancel the subscription and the device
stops accepting that kind. Several subscribers share one decoded value.

## Behaviour notes

- Peers only connect if app id, protocol version and BOMTalk's own protocol version match; others
  are never listed. This release speaks BOMTalk protocol 3 (relay); v2 devices and this one never
  see each other, so update all devices of an installation together.
- At most 8 peers including this device (7 remote), further peers are ignored until a slot frees up.
- Always encrypted, always reliable.
- Payloads are binary property lists, lzfse compressed, sent in chunks of up to 64 KB;
  concurrent transfers are interleaved.
- Flow control: the receiver acknowledges every 256 KB, the sender keeps at most 512 KB per
  transfer and 1 MB per peer (all its transfers together) unacknowledged, so transfers never
  pile up in a link's queue.
  `send` returns once the receiver acknowledged everything (it may still fail to decode the
  message; its `messages` stream reports that).
- 30 s timeouts for unanswered offers and stalled transfers (incoming: no chunk, outgoing: no
  acknowledgement). A chunk lost on the way is not resent; both ends fail with `.timeout`.
- A disconnect during a transfer fails it cleanly (`.peerDisconnected`).
- Progress: incoming counts received bytes; outgoing counts bytes the receiver acknowledged, so
  both sides progress together (the sender in 256 KB steps). Finished or failed transfers are
  removed from `transfers`.
- `start()` / `stop()` are idempotent; `stop()` disconnects and clears `peers`.
- `info` budget: about 300 bytes for your keys and values (after internal keys). Larger info
  still reaches connected peers but is not advertised during discovery. Set it before `start()`.
- Local network: a denial is not always reported by MultipeerConnectivity
  (`.localNetworkDenied`), nearby peers may simply never appear.
- iOS backgrounding: MultipeerConnectivity drops sessions in the background. Call `stop()` when
  the scene goes to `.background` and `start()` again when `.active` (see the sample app).
- Identity: each device keeps a stable peer identity in the Keychain (device-only, not in
  backups), so restored or cloned devices get a new identity. The MultipeerConnectivity peer id
  is new on every `start()` (other devices may still hold a session with the old one).

- Logging: only problems the API cannot report otherwise (e.g. malformed frames, invalid
  discovery info, keychain failure) via `os.Logger`, subsystem `de.werk01.BOMTalk`.

## Known limitations

- No cancel or resume of transfers.
- Swift task cancellation is not honoured yet, a cancelled `send` runs to completion.
- A late accept after the sender's 30 s offer timeout can make the receiver time out waiting
  for data.

## Sample app

`Sample/BOMTalkSample.xcodeproj` is a SwiftUI app for iOS and macOS showing peers with live
info, a broadcast chat and large blob transfers with progress, including `.notWanted` when the
receiver does not accept blobs. Run it on two devices in the same network. The project is
generated from `Sample/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

For scripted multi-device runs the Sample has launch arguments (`-autostart`, `-controlPort`,
`-linkCap`, `-soak`, …) and an HTTP control layer; `Sample/Rig/` drives several simulators with it
(see its README). The package side is `@_spi(Debug)`: `Talk.debugSnapshot()`, a debug init with a
link cap and ephemeral identity, a block list. It is not part of the public API.

## Tests

`swift test` runs a small set of behaviour tests over an in-memory loopback transport, no devices
or network needed.

## Migrating from v1

v2 is a new API, not source compatible:

| v1 | v2 |
|---|---|
| GameKit `GKSession` | MultipeerConnectivity |
| delegate, blocks, `NSNotification` | Observation state + Combine publishers |
| singleton | host creates and owns `Talk` |
| integer message ids | `TalkMessage.kind` strings |
| `NSCoding` payloads | `Codable` message types |
| manual connect | auto-connecting mesh |
| global progress | observable `Transfer` per peer and direction |

## License

MIT, see [LICENSE](LICENSE).
