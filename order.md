# Resting notch preview priority

Priorities are ascending: the lower the number, the higher the priority. When
multiple previews are active, the lowest numbered item is shown. `None` is the
fallback when no preview is active.

The resting notch has one pair of shoulders and no scroll. Every entry here is
competing for the same strip, so the order is not taste — it follows from four
rules, in this order of force.

## Ranking rules

**R1 — Blocked beats busy.** Anything waiting on the user outranks anything
progressing without them. A stopped agent needs a human; a running one does not.

**R2 — Ephemeral beats persistent, at equal urgency.** An announcement expires
and cannot come back. A steady state can yield for five seconds and resume with
nothing lost. So the short thing goes on top.

**R3 — Physical beats ambient.** Something the user just did with their hands
outranks something that is merely true.

**R4 — Offers rank last.** A suggestion the user did not ask for never displaces
information they did.

## Order

**0. Direct permission request** — not a preview. It takes the red rim, switches
to the Agent tab and opens the panel outright, above this whole ladder. An agent
is halted mid-run and only the user can release it (R1).

1. **Call** — seconds long, needs an answer now, and the caller hangs up.
2. **Notification burst** — an external event with its own timing.
3. **Agent asked you a question** — the agent has stopped and cannot continue
   until answered. Above background work by R1: slot 5 means work is moving,
   this means it isn't.
4. **Agent state change** — the five-second announcement of a transition:
   started, plan ready, done, session closed. Ephemeral, so it preempts the
   steady states below it (R2) and then releases.
5. **Background work in flight** — an Ask or Agent run started in this app, with
   its live verb and elapsed clock.
6. **AirPods connect / disconnect** — a three-second announcement of something
   the user physically just did (R3).
7. **Pomodoro hand-off** — a five-second phase transition the user scheduled.
8. **Agent steady state** — an external CLI session working or planning. Ranked
   below the announcements above by R2: this state can persist for twenty
   minutes, and it should not blank out every short-lived signal for the whole
   run. It resumes the moment they finish.
9. **Music** — ambient and open-ended; yields to anything with an end.
10. **Clipboard suggestion** — an offer, not an event (R4).

## Where this lives in the code

The ladder is `RestingNotchPriority.slot(for:)` in
`NotchFlow/Sources/Capabilities/RestingNotchPriority.swift` — a pure function
over a struct of booleans, so this document is enforced by
`Tests/NotchCapabilityTests/RestingNotchPriorityTests.swift` rather than merely
described by it. `RestingNotchSlot`'s raw values are the ranks above, and one
test walks the whole ladder by activating every slot at once and removing the
winner ten times.

`restingSlot` in `ContentView.swift` is only the adapter: it says what each
condition *is*, and the resolver decides which one wins. Add a slot by adding a
row to the table in the resolver and a case to the enum at the right rank.

## Live activity

Settings → Appearance → "Live activity" does not mute the whole ladder. It
silences the slots that make the island *flex* and leaves the quiet presence
signals alone:

- **Muted:** call, notification, background work, Pomodoro hand-off.
- **Not muted:** both agent announcements and the agent steady state, AirPods,
  music, clipboard.

Agent status is in the second group deliberately: a long CLI run is a state the
user opted into watching, not an interruption. A muted slot falls through to the
next unmuted rank rather than blanking the notch.
