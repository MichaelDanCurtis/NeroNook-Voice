# Link a recording to its calendar meeting · Voice 0.13.1

Open **Nero Voice → Meetings → Link calendar meeting**. Choose **Google Calendar**
or **Mac Calendar**, select the date and choose **Show meetings**. Each occurrence
has its own time and calendar; choose **Link meeting** on the correct row.
If a date has many events, use More meetings / First page.

For a new recording, the selected meeting title supplies the default name.
Choose microphone/call audio as usual, then press **Start recording** explicitly.
For an existing recording, select it in the library first, then link it. One
link belongs to that recording and all of its live/refined/provider transcripts
and private notes. Linked titles/calendar names are included in local library
search and calendar details appear in transcript/notebook Markdown exports.

Use **Refresh link** to verify the same event occurrence and update its title or
time. **Link calendar meeting** can change it; **Unlink** removes the attachment
while retaining the recording, transcripts and notes. A missing or unavailable
event leaves the cached link and files intact, with an explanatory status.
An **Open event** control appears only when the provider supplies a safe HTTPS
event URL; it rechecks the original occurrence before opening it. Native Apple
Calendar events need not have a web URL, so this control can be absent.

## Calendar access

In Nook Settings → Modules → Actions and connections, select Nero Voice and
allow **list_calendar_events** and **read_calendar_event** from the chosen
calendar provider. Updates pin grants to new package contents; allow those same
two reads again after updating either package. Google sign-in and selected
calendars stay in Google's own settings. Mac Calendar uses NeroNook's existing
Calendar access and enabled calendars; enable them in Nook Settings → Calendar
if needed. Choosing an event does not authorize an assistant to read meetings.

Everything is read-only. Linking never edits an event, starts a recording,
sends an invitation, fetches attendees or sends audio to a cloud service.
Links are local metadata. **Ask this meeting** still previews and explicitly
sends transcript excerpts only; calendar details and My thoughts are excluded.
An already-permitted meeting-read tool includes the local link, but Agent and
Fuego meeting-library read grants remain off in this delivery.

## Identity and limits

Links store provider/calendar/event/original occurrence, not a title match.
Recurring meetings that look identical remain distinct. Moved times can refresh
without selecting another occurrence; copies/moves between calendars or changed
provider IDs may need manual relinking. EventKit's bounded original-occurrence
search relies on direct external-ID lookup for detached events moved farther
than -3 / +4 days. This is not universal recurrence relocation support.

The optional version-1 sidecar does not migrate old recording formats. A single
previous sidecar is retained during change/unlink; both are bounded and written
privately. Selected-day reads page at up to six rows / 2 KiB with a short-lived
candidate list; refresh before selecting stale results. No automatic calendar
matching, reminders, Join, attendees, folders or calendar writes are included.

See [shared SDK contract](../../NeroNook/SDK/CALENDAR.md) and
[delivery evidence](../reports/calendar-links-2026-10-13/README.md).
