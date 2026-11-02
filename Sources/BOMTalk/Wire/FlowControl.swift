//
//  FlowControl.swift
//  BOMTalk
//

import Foundation

/// End-to-end flow control of transfers: the receiver acknowledges the contiguous prefix it received
/// (`Frame.ack`), the sender keeps at most `window` unacknowledged bytes per transfer in flight
/// (`Scheduler`).
///
/// Without it the sender handed every chunk to the transport at once and MultipeerConnectivity
/// buffered it all: tens of seconds of data in one link's queue, with relay hellos waiting behind it
/// until map entries on the far side expired. The window bounds each transfer's share of every link
/// queue on its path, relays included.
enum FlowControl {

	/// Unacknowledged bytes per outgoing transfer: 8 chunks.
	static let window = 8 * Frame.maxChunkPayload
	/// The receiver acknowledges every this many received bytes (4 chunks) and at completion, so
	/// a full window always has acknowledgements on the way.
	static let ackInterval = 4 * Frame.maxChunkPayload
	/// A receiver that got no chunk for this long repeats its ack, so a lost ack (route change) does
	/// not leave the sender waiting with a full window. Checked at this interval, so the repeat
	/// follows after one to two intervals of silence.
	static let ackRepeat: Duration = .seconds(2)
	/// A sender that handed off every chunk but got no final ack for this long sends the last chunk
	/// again; the receiver answers with the final ack if it completed the transfer meanwhile (the ack
	/// was lost), or takes the chunk if that was lost. Repeated at this interval until the timeout.
	static let finalAckProbe: Duration = .seconds(10)
}
