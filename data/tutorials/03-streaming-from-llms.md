# Streaming text from a language model, one token at a time

Streaming is the technique of delivering a response to the user incrementally, in small pieces, as it is
produced, rather than waiting for the complete result and sending it all at once. It is the reason a
modern artificial intelligence chat interface appears to type its answer in front of you, word by word,
instead of pausing for several seconds and then revealing a finished paragraph. Streaming matters because
a large language model generates text sequentially, and a full answer can take many seconds to complete,
so showing the first words the moment they exist transforms the experience from a long blank wait into a
responsive conversation. This guide explains how streaming works, what happens at each stage, and how to
stream a language model's output to a web browser in Ruby on Rails using AnyCable, a realtime server that
runs Action Cable channels.

To understand streaming you first need to understand how a language model produces text. A language model
generates its output as a sequence of tokens, where a token is a small unit of text, often a single word
or a fragment of one, and the model emits these tokens one after another in order. The process of
generating this sequence is called inference, and it is inherently incremental, because each token is
chosen based on all the tokens that came before it. Most model providers expose the sequence as a stream
over the network, meaning your application receives a series of small partial messages as they are
generated rather than one large message at the end.

Delivering those partial messages to the user relies on the publish-subscribe pattern that underlies
realtime web features. In this pattern a browser subscribes to a named channel, called a stream, and a
publisher sends messages to every client subscribed to that channel. The server's responsibility is to
forward each token to the right user as it arrives, and the browser's responsibility is to append each
fragment to the text already on screen, so that the answer grows smoothly in place until it is complete.

Because calling the model and waiting for its tokens is slow, that work belongs in a background job
rather than in a web request, which keeps the web server free during the long generation. In this guide
you will create a channel the browser subscribes to, run the model call inside a background job that
broadcasts each token as it streams in, and accumulate the tokens in the browser so the response renders
progressively until the model signals that it has finished.

## Step 1: A channel for one answer

Subscribe each answer to its own stream, named after the message record being generated, so a browser
receives exactly the tokens for the answer it is waiting on:

```ruby
# app/channels/answer_channel.rb
class AnswerChannel < ApplicationCable::Channel
  def subscribed
    stream_for Message.find(params[:id])
  end
end
```

## Step 2: Stream tokens from a background job

Run the model call in a job. As each token arrives from the provider's streaming API, broadcast it; when
the model finishes, broadcast a terminal marker so the browser knows to stop:

```ruby
# app/jobs/answer_job.rb
class AnswerJob < ApplicationJob
  def perform(message)
    client.stream_chat(message.prompt) do |token|
      AnswerChannel.broadcast_to(message, { token: token })
    end
    AnswerChannel.broadcast_to(message, { done: true })
  end
end
```

Enabling `ANYCABLE_BROADCAST_BATCHING` lets AnyCable aggregate the many small broadcasts a single
generation produces, reducing overhead when tokens arrive in rapid bursts.

## Step 3: Accumulate tokens in the browser

Subscribe to the channel and append each fragment to the target element until the `done` marker arrives:

```js
const target = document.getElementById(`answer_${messageId}`)
const channel = await cable.subscribeTo("AnswerChannel", { id: messageId })

channel.on("message", ({ token, done }) => {
  if (done) return channel.disconnect()
  target.textContent += token
})
```

The connection stays open and idle while the model thinks, then fills in the answer as fast as the tokens
arrive. Because the slow work lives in the job and the transport is a stream, the web server handles
nothing but the initial subscription, and the same pattern scales from one user to many.
