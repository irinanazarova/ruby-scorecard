# Building a realtime chat system in Ruby on Rails

A realtime chat system delivers messages to their recipients the instant they are sent, without anyone
having to reload the page. It is one of the oldest and most instructive problems in web development,
because a working chat touches almost every concern a realtime application has: persisting messages so
they survive a refresh, delivering them live to everyone in a conversation, showing who is currently
present, and signaling when someone is typing. This guide explains how these pieces fit together and how
to build them in Ruby on Rails using AnyCable, a realtime server that runs Action Cable channels.

The foundation of chat is the distinction between durable and ephemeral data, which determines how each
kind of information should be handled. A chat message is durable: it must be saved to the database so
that it appears in the history when someone scrolls up or rejoins later, and it must be delivered
reliably to every participant. A typing indicator is ephemeral: it is true for only a second or two, it
is replaced constantly, and it is not worth storing or guaranteeing. Designing chat well means routing
each kind of data through the appropriate mechanism rather than treating them the same.

Realtime delivery is built on the publish-subscribe pattern. Each conversation corresponds to a named
channel called a stream, every participant's browser subscribes to that stream, and when a message is
created the server broadcasts it to all subscribers. Broadcasting is the right tool for durable messages
because it runs through your application, where the message is first saved and then sent to everyone.
For the ephemeral typing indicator, AnyCable offers a lighter mechanism called whispering, in which one
participant publishes directly to the others without invoking server code or writing to the database.

This guide builds chat in layers, each one a self-contained step. You will start by persisting and
broadcasting messages so a conversation works live across browsers. You will then add a typing indicator
using whispering, and finally show who is in the room using AnyCable's presence support. Each layer
reinforces the same underlying idea, that a realtime feature is a set of streams carrying messages whose
durability you choose deliberately.

## Step 1: Persist and broadcast messages

Subscribe each room to its own stream. When a message is created, save it, then broadcast the rendered
message to everyone on the stream:

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_for Room.find(params[:id]), whisper: true
  end
end

# app/models/message.rb
class Message < ApplicationRecord
  after_create_commit do
    ChatChannel.broadcast_to(room, { html: render_message(self) })
  end
end
```

On the client, append each broadcast to the message list:

```js
const channel = await cable.subscribeTo("ChatChannel", { id: roomId })
channel.on("message", ({ html }) => appendMessage(html))
```

## Step 2: A typing indicator with whispering

A "user is typing" signal is ephemeral, so whisper it rather than broadcasting through the server. The
`whisper: true` flag set in step 1 already permits this:

```js
input.addEventListener("input", () => {
  channel.whisper({ typing: true, name: myName })
})

channel.on("message", ({ typing, name }) => {
  if (typing) showTyping(name)
})
```

No database row is written and no Ruby runs, which is appropriate for a signal that is replaced with
every keystroke.

## Step 3: Show who is in the room

Add presence so the room displays its participants. Include the presence module and join on subscribe:

```ruby
class ChatChannel < ApplicationCable::Channel
  include AnyCable::Rails::Channel::Presence

  def subscribed
    stream_for Room.find(params[:id]), whisper: true
    join_presence(id: current_user.id, info: { name: current_user.name })
  end
end
```

```js
channel.presence.on("join", ({ info }) => addMember(info.name))
channel.presence.on("leave", ({ id }) => removeMember(id))
```

The result combines all three durability choices in one feature: messages are persisted and broadcast,
typing is whispered, and membership is tracked by presence. Each concern uses the mechanism that fits it,
which is what keeps a realtime chat both correct and efficient.
