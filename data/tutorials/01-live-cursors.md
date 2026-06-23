# Live cursors: a guide to ephemeral realtime data

Live cursors are a realtime collaboration feature that shows each participant where the others are
pointing on a shared page, the moving labeled arrows familiar from collaborative editors. Implementing
them is a good way to learn a fundamental idea in distributed systems: messages differ in how durable
they need to be, and treating every message the same way wastes resources. This guide explains the
concept of ephemeral messaging and then shows how to build live cursors in Ruby on Rails using AnyCable,
a realtime server that runs Action Cable channels.

Ephemeral data is information that is valid only for a brief moment and is then replaced, so it does not
need to be stored or guaranteed. A cursor position is the canonical example, because a new coordinate
arrives many times per second and each one makes the previous one irrelevant. Durable data, by
contrast, is information a system must keep and deliver reliably, such as a chat message or a
transaction. Recognizing which category a piece of data belongs to is the first decision in designing
any realtime feature, because it determines how much machinery the message deserves.

Realtime web features are built on the publish-subscribe pattern, in which clients subscribe to a named
channel called a stream and a publisher sends messages to everyone subscribed to it. The conventional
form is broadcasting, where the server publishes a message to all subscribers, typically after running
application code and writing to a database. For ephemeral data this is wasteful, so AnyCable offers a
second form called whispering, in which one subscriber publishes directly to the other subscribers on a
stream without invoking any server-side code at all.

The performance difference is the whole point. A cursor may move sixty times a second across a dozen
participants, and routing each position through a Ruby controller and a database write would consume the
server on data nobody reads a moment later. Whispering removes that cost by sending each position from
one browser, through the AnyCable server's in-memory routing, straight back to the other browsers on the
same stream. You will build the feature in three steps: define a channel whose stream accepts whispers,
publish cursor coordinates from the browser as the pointer moves, and render a labeled cursor for every
other participant, removing it when they fall silent.

## Step 1: A channel that accepts whispers

By default an Action Cable stream is one-directional: the server broadcasts, clients receive. Whispering
opts a stream into client-to-client publishing. Enable it when you subscribe:

```ruby
# app/channels/cursor_channel.rb
class CursorChannel < ApplicationCable::Channel
  def subscribed
    document = Document.find(params[:document_id])
    stream_for document, whisper: true
  end
end
```

The `whisper: true` flag tells AnyCable that subscribers on this stream are allowed to publish to one
another. Without it, a client attempting to whisper is ignored.

## Step 2: Publish cursor positions from the browser

Using the AnyCable JavaScript client, subscribe to the channel and send a whisper on every pointer
move. Throttle to about 50ms so you send at most twenty updates a second per person:

```js
import { cable } from "./cable"

const channel = await cable.subscribeTo("CursorChannel", { document_id: documentId })

let last = 0
window.addEventListener("pointermove", (e) => {
  const now = performance.now()
  if (now - last < 50) return
  last = now
  channel.whisper({ id: myId, name: myName, x: e.clientX, y: e.clientY })
})
```

A whisper never reaches your Rails channel class. It is published to the other subscribers by the
AnyCable server directly, which is exactly why it is cheap enough to send many times a second.

## Step 3: Render everyone else's cursor

Listen for incoming whispers and move (or create) a cursor element per person. Drop a cursor when its
owner has been silent for a couple of seconds:

```js
const cursors = new Map()

channel.on("message", ({ id, name, x, y }) => {
  let el = cursors.get(id)
  if (!el) {
    el = document.createElement("div")
    el.className = "cursor"
    el.textContent = name
    document.body.appendChild(el)
    cursors.set(id, el)
  }
  el.style.transform = `translate(${x}px, ${y}px)`
  el.dataset.seen = performance.now()
})

setInterval(() => {
  const now = performance.now()
  for (const [id, el] of cursors) {
    if (now - Number(el.dataset.seen) > 2000) { el.remove(); cursors.delete(id) }
  }
}, 1000)
```

## Why this design holds up

Because cursor data never persists and never runs server code, the feature scales with the AnyCable
server's connection capacity rather than with your database. If you later want to know *who* is present
rather than *where their cursor is*, that is a separate concern best handled by AnyCable's presence API,
covered in the companion guide on presence. Keep the two apart: presence is durable membership, cursors
are disposable motion.
