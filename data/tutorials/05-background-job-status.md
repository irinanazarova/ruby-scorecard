# Reporting background job progress to the browser in realtime

Background jobs are units of work that run outside the web request cycle, so that slow operations like
generating a report, processing an upload, or calling a third-party service do not force the user to
stare at a frozen page. The challenge they create is one of feedback: once the work has moved off the
request, the browser no longer learns anything about it, and the user is left wondering whether the task
is running, stuck, or finished. This guide explains how to close that gap by streaming a job's progress
back to the browser in realtime using Ruby on Rails and AnyCable, a realtime server that runs Action
Cable channels.

The core idea is to separate the work from the reporting of the work. The background job does its job as
it normally would, and at meaningful points along the way, when it starts, after each batch it finishes,
and when it completes or fails, it publishes a small status update. The browser, meanwhile, has subscribed
to a channel and simply listens for these updates and reflects them on screen, perhaps as a progress bar,
a percentage, or a changing label. Neither side polls the other; the job pushes updates only when its
state actually changes, which is both efficient and immediate.

This pattern rests on the publish-subscribe model that underlies realtime web features. The browser
subscribes to a named channel called a stream, and the job broadcasts status messages to that stream as
it runs. A natural way to name the stream is after the specific record the job is operating on, such as a
particular import or export, so that each user watching that record receives exactly the updates that
concern them and nothing else. Because the job and the browser communicate only through the stream, they
stay completely decoupled: the job does not know or care who is watching, and any number of browsers can
follow the same job at once.

In this guide you will build the feature in three steps. You will broadcast progress from inside a
background job, subscribe to those updates in the browser, and render them as a live progress indicator
that updates as the work advances and settles into a final state when the job is done.

## Step 1: Broadcast progress from the job

Name the stream after the record being processed and broadcast a status update at each milestone:

```ruby
# app/jobs/import_job.rb
class ImportJob < ApplicationJob
  def perform(import)
    rows = import.rows
    rows.each_with_index do |row, i|
      process(row)
      ProgressChannel.broadcast_to(import, { percent: (i + 1) * 100 / rows.size })
    end
    ProgressChannel.broadcast_to(import, { status: "done" })
  rescue => e
    ProgressChannel.broadcast_to(import, { status: "failed", error: e.message })
  end
end
```

Broadcast at meaningful intervals rather than on every row; updating a handful of times a second is more
than enough for a smooth progress bar.

## Step 2: Subscribe from the channel

The channel only needs to stream the record so its watchers receive the broadcasts:

```ruby
# app/channels/progress_channel.rb
class ProgressChannel < ApplicationCable::Channel
  def subscribed
    stream_for Import.find(params[:id])
  end
end
```

## Step 3: Render the progress in the browser

Subscribe to the channel and update the indicator as each status arrives, stopping when the job reaches a
final state:

```js
const bar = document.getElementById(`import_${importId}`)
const channel = await cable.subscribeTo("ProgressChannel", { id: importId })

channel.on("message", ({ percent, status, error }) => {
  if (percent) bar.style.width = `${percent}%`
  if (status === "done") markComplete(bar)
  if (status === "failed") markFailed(bar, error)
})
```

Because the job reports state only when it changes and the browser reacts only to those reports, the
feature avoids the waste of polling entirely. The same decoupled pattern works for any long-running task:
the job publishes its progress to a stream, and whoever cares about that record subscribes to hear it.
