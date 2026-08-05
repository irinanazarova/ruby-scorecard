// The browser side of AnyCable.
//
// Rails' stock @rails/actioncable client subscribes by naming a Rails CHANNEL CLASS
// ({"channel":"Turbo::StreamsChannel"}). We run AnyCable RPC-less, so there is no Rails process
// for the server to ask about channel classes — it exposes the generic "$pubsub" channel and
// verifies a signed stream name instead. @anycable/turbo-stream is what teaches Turbo that dialect.
//
// The JWT is rendered into a meta tag per request (see the layout). Connection auth is entirely
// client-presented: without a valid token AnyCable drops the socket with "unauthorized" before any
// subscription is attempted.
import { createCable } from "@anycable/web"

const meta = (name) => document.head.querySelector(`meta[name="${name}"]`)?.content

const url = meta("action-cable-url")
const token = meta("anycable-token")

// The EXTENDED Action Cable protocol, not the plain one.
//
// This is the reason to use AnyCable's client rather than @rails/actioncable, beyond the $pubsub
// dialect: it adds session resumption and stream history. An analysis takes 40-110s to complete,
// and if the socket drops midway through — conference wifi, a laptop sleeping, a tunnel — the plain
// protocol reconnects into a *fresh* session and silently loses every step broadcast during the
// gap. The page just sits there with boxes that never fill.
//
// With the extended protocol the client resumes its session and asks for what it missed, so a blip
// costs a second of catch-up instead of the whole run.
const cable =
  url && token
    ? createCable(url, {
        auth: { token },
        websocketAuthStrategy: "sub-protocol",
        protocol: "actioncable-v1-ext-json"
      })
    : null

export default cable
