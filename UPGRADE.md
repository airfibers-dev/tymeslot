# Upgrading this fork

This fork carries Airfibers' patches on top of upstream Tymeslot. Each patch
lives on its own topic branch, rebased onto the upstream release it targets,
and an integration branch merges them for a build. Nothing is ever committed
to a topic branch that belongs to another topic.

## Branch model

| Branch | Holds |
|---|---|
| `patch/teams-host-attendee` | Teams `host_email` on `EventDetails`, organiser invited as attendee |
| `patch/ews-dup-guard` | `calendar_event_sync.ex`: skip the EWS write once the Teams room exists |
| `patch/ews-fixes` | Exchange timezone months + `MaxEntriesReturned`, FindItem diagnostics, 30/180-day sync window |
| `patch/itip` | Opt-in iTIP `REQUEST`/`CANCEL` invites for booker and guest emails (`EMAIL_ITIP_INVITES`) |
| `patch/build-docker` | Only if a build needs it: Dockerfile changes for the offline dependency fetch |
| `custom/vX.Y.Z` | Integration branch: `vX.Y.Z` + the four topic branches merged, tagged `X.Y.Z-customN` |

Rules:

- A patch touching `calendar_event_sync.ex` belongs to exactly one topic
  branch. Teams and EWS share that file; the dup-guard is the only patch that
  edits it.
- iTIP code stays in `lib/tymeslot/mailer/itip_message.ex`,
  `lib/tymeslot/emails/shared/itip_invite.ex` and the `appointment_*`
  templates, and never touches Teams, EWS or sync files.
- `custom/vX.Y.Z` is rebuilt from scratch on every upgrade; it is never the
  place a fix is written.

## Per-release upgrade

`scripts/upgrade.sh` does the mechanical part:

```bash
git fetch --all --tags
scripts/upgrade.sh v1.31.0 v1.32.0     # OLD_TAG NEW_TAG
```

It creates `patch/*` from `OLD_TAG`, cherry-picks the commits listed in its
`TOPICS` table, rebases each onto `NEW_TAG` and stops at the first conflict
with the branch and files named. Resolve the conflict on that branch, run
`git rebase --continue`, then re-run the script: it skips branches already on
`NEW_TAG`.

Then, by hand:

```bash
git checkout -B custom/v1.32.0 v1.32.0
for b in patch/teams-host-attendee patch/ews-dup-guard patch/ews-fixes patch/itip; do
  git merge --no-ff "$b"
done
git tag 1.32.0-custom1
```

The cherry-pick list in `scripts/upgrade.sh` must be updated when a patch is
added or amended: it names commits, not branches.

## Conflict hotspots

- **`lib/tymeslot/meetings/calendar_event_sync.ex`** — upstream adds
  `flag_if_unauthorized/2`, the `CalendarManagement` alias and the `:refused`
  branch; the dup-guard adds `skip_ews_write?/1` and its three call sites.
  Both must survive. The skip path returns `:ok` before any provider call, so
  it can never swallow an `:unauthorized` or `:refused` result.
- **`lib/tymeslot/emails/templates/appointment_{confirmation,rescheduled,cancellation}.ex`**
  — upstream reworks the organiser copies (host-managed wording,
  `counterpart_section/2`, dashboard links). The iTIP patch only appends
  `ITipInvite.put_itip_body/4` to the booker and guest pipelines. Keep
  upstream's organiser changes; re-append the iTIP call.
- **`lib/tymeslot/emails/shared/meeting/attendee.ex`** — upstream added
  `counterpart_section/2` and `guests_section/2`. The booker's name and email
  still come from `AppointmentBuilder.participant_details/2`, which the iTIP
  patch does not touch.
- **`lib/tymeslot/notifications/email/*`** — not patched, but the place to
  check that a new email flow does not route a host-managed meeting through
  the iTIP path (`ITipInvite.deliverable?/2` refuses `:host_managed`).

## Tests

Run on the build server, never as root (`smtp_config_test.exs` needs a
non-root user for its unreadable-CA case):

```bash
docker run --rm --user 1000:1000 --network tymeslot-test -v "$PWD":/app -w /app \
  -e MIX_ENV=test -e HEX_HOME=/tmp/hex -e MIX_HOME=/tmp/mix \
  -e DATABASE_HOST=tymeslot-test-pg \
  hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20260918-slim \
  bash -lc 'mix deps.get && mix format --check-formatted &&
            MIX_ENV=test mix compile --warnings-as-errors &&
            MIX_ENV=test mix ecto.create ecto.migrate && MIX_ENV=test mix test'
```

Focused runs while resolving a conflict:

```bash
MIX_ENV=test mix test test/tymeslot/meetings/calendar_event_sync_test.exs
MIX_ENV=test mix test test/tymeslot/integrations/calendar/exchange
MIX_ENV=test mix test test/tymeslot/emails test/tymeslot/mailer
```

## Build, inspect, deploy

```bash
docker build -f Dockerfile.docker -t tymeslot:1.31.0-custom1 .
docker inspect --format '{{.Config.Labels}} {{index .Config.Labels "org.opencontainers.image.revision"}}' \
  tymeslot:1.31.0-custom1
docker inspect --format '{{.Created}}' tymeslot:1.31.0-custom1
git rev-parse custom/v1.31.0
```

The revision label must equal the commit `custom/v1.31.0` points at. If it
does not, the image was built from a stale context; rebuild before deploying.

## Database

1.31.0 adds nine migrations. All are additive (new tables, columns and
indexes; no destructive change), and the release runs them on startup. Take a
backup before the first start of the new image:

```bash
docker exec tymeslot-postgres pg_dump -U postgres tymeslot > tymeslot-pre-1.31.0.sql
```

## Rollback

Keep the previous image tag until the new one has run for a day:

```bash
docker tag tymeslot:1.30.0-custom1 tymeslot:previous   # before deploying
# rollback
docker compose down && TYMESLOT_IMAGE=tymeslot:previous docker compose up -d
```

The migrations are additive, so the previous image runs against the migrated
schema. Restore the dump only if a migration itself must be undone.
