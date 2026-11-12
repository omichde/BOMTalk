//
//  BOMTalkProtocol.swift
//  BOMTalk
//

import Foundation

/// Version of BOMTalk's own wire protocol, separate from the host app's `protocolVersion`.
///
/// Advertised in discovery (`DiscoveryInfo`, `_v` = `"<BOMTalk version>:<app version>"`) and in the
/// invitation context (`InvitationContext`); devices only list and connect to devices with exactly the
/// same BOMTalk *and* app version, so builds of different versions never see each other.
///
/// **Bump it on any wire-incompatible change**: discovery, invitation context, `RelayEnvelope` or
/// `RelayHello` layout, envelope kinds, `Frame` types or fields, or a behaviour change the other side
/// relies on (e.g. flow control acks). Unreleased formats may change without a bump.
///
/// The per-format version bytes (`Frame.version` in Talk frames, `RelayEnvelope.version` in relay
/// envelopes) only let a parser reject a format it does not know; they do not decide compatibility.
/// Since two devices only connect with equal BOMTalk versions, those bytes stay at 1 and change only
/// together with a bump of this version.
///
/// - 1, 2: implicit, v1 (GameKit) and v2 (MultipeerConnectivity, `_v` is the bare app version, no
///   relay). v2 compares `_v` with its app version exactly, so it ignores every later build.
/// - 3: the relay (envelope, hellos, link policy, flow control acks).
enum BOMTalkProtocol {

	static let version = 3
}
