# Presence: tracking who is online in a realtime application

Presence is the part of a realtime system that answers a deceptively simple question: who is here right
now? It is the feature behind the row of avatars on a shared document, the green dot beside an online
contact, and the "three people are viewing this" label on a listing. Building presence correctly
teaches an important lesson about distributed state, because the answer has to stay accurate as people
open and close connections, refresh pages, and join from several devices at once. This guide explains
what presence means, why it is harder than it first appears, and how to implement it in Ruby on Rails
using AnyCable, a realtime server that runs Action Cable channels.

Presence is fundamentally a problem of membership in a set. Each stream, meaning a named channel that
clients subscribe to, has a set of members who are currently connected, and the system must add a member
when they arrive and remove them when they leave. The difficulty is that a single person is not the same
as a single connection. One user may have the page open in three browser tabs, and each tab holds its
own WebSocket connection, yet the interface should show that user once, not three times. A correct
presence system therefore deduplicates connections by user identity, reporting a person as present while
any of their connections survive and as absent only when the last one closes.

The second difficulty is reliability of departure. A connection can end cleanly when a user navigates
away, but it can also vanish silently when a laptop sleeps or a network drops, in which case no explicit
"leave" message is ever sent. A presence system must detect these lost connections through timeouts and
heartbeats so that the set does not slowly fill with members who are no longer really there. AnyCable
handles this bookkeeping for you: it maintains the presence set on the server, deduplicates by user id,
and emits join and leave events that your application and your front end can react to.

In this guide you will add presence in two ways. First you will use the server-side presence API to join
and leave the set from an Action Cable channel and broadcast the changes. Then you will use the
declarative Hotwire integration, which tracks presence with a single HTML element and updates the page
without custom JavaScript.

## Step 1: Join the presence set from a channel

Include AnyCable's presence module in the channel and call `join_presence` once you have subscribed to a
stream. Pass a stable user id and any metadata the front end needs:

```ruby
# app/channels/room_channel.rb
class RoomChannel < ApplicationCable::Channel
  include AnyCable::Rails::Channel::Presence

  def subscribed
    room = Room.find(params[:id])
    stream_for room
    join_presence(id: current_user.id, info: { name: current_user.name })
  end
end
```

AnyCable adds the user to the presence set associated with the stream and removes them automatically when
their last connection closes. You can also leave explicitly with `leave_presence(id)`.

## Step 2: React to presence on the client

The AnyCable JavaScript client exposes the same set and emits `join` and `leave` events you can render:

```js
const channel = await cable.subscribeTo("RoomChannel", { id: roomId })

channel.presence.on("join", ({ id, info }) => addAvatar(id, info.name))
channel.presence.on("leave", ({ id }) => removeAvatar(id))

const present = await channel.presence.list()
present.forEach(({ id, info }) => addAvatar(id, info.name))
```

Clients may also `channel.presence.join()` and `channel.presence.leave()` directly when membership is
driven by the browser rather than the server.

## Step 3: Declarative presence with Hotwire

If you use Hotwire, AnyCable can track presence with no JavaScript at all through the
`<turbo-cable-presence-source>` element. It connects to the server, joins the set, and renders a template
of Turbo Stream actions on every join and leave:

```erb
<turbo-cable-presence-source
  signed-stream-name="<%= signed_stream_name(@room) %>"
  presence-id="<%= current_user.id %>"
  ignore-self>
  <template>
    <turbo-stream action="append" target="presence">
      <template><span class="avatar"><%= current_user.name %></span></template>
    </turbo-stream>
  </template>
</turbo-cable-presence-source>

<div data-presence-counter></div>
```

The server deduplicates sessions, so a second tab does not trigger a second join, and an element marked
`data-presence-counter` updates with the live count. The leave action fires only when a user's last
session ends.
