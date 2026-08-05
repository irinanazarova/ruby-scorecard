// Turbo CORE, deliberately not "@hotwired/turbo-rails".
//
// turbo-rails' bundle defines <turbo-cable-stream-source> itself, wired to Rails' own ActionCable
// client. @anycable/turbo-stream defines the same element — but only if nothing has claimed it:
//
//   customElements.get(name) === void 0 && customElements.define(name, ...)
//
// So importing turbo-rails first means AnyCable's definition is skipped silently. The page keeps a
// stream source that speaks plain Action Cable, subscribing to a "Turbo::StreamsChannel" that does
// not exist in RPC-less mode. Nothing errors; the cable simply stays idle and no step ever fills.
// Import reordering cannot fix it — ES imports are hoisted and run before any body statement.
//
// Turbo core provides drive, frames and stream rendering; the only thing turbo-rails adds here is
// the ActionCable stream source, which is exactly what AnyCable replaces.
import "@hotwired/turbo"
import "controllers"

import cable from "cable"
import { start } from "@anycable/turbo-stream"

// In development the async adapter is used and no cable is built, so Turbo keeps its own transport
// and /test still streams locally with no external service and no credentials.
if (cable) start(cable)
