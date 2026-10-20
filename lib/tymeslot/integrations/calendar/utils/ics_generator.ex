defmodule Tymeslot.Integrations.Calendar.IcsGenerator do
  @moduledoc """
  Module for generating ICS (iCalendar) files for meeting appointments.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Locales
  alias Tymeslot.Payments.Subscriptions

  @doc """
  Generates an ICS file content for a meeting/appointment.

  ## Parameters
    - meeting_details: Map containing meeting information
    - locale: Locale for translated strings (default: "en")
  """
  @spec generate_ics(map(), String.t()) :: String.t()
  def generate_ics(meeting_details, locale \\ "en") do
    generate_ics_with(meeting_details, :none, nil, locale)
  end

  @doc """
  Generates a Swoosh email attachment with ICS content.

  The SEQUENCE comes from the payload's `:ical_sequence`, which every detail
  map built by `Tymeslot.Emails.AppointmentBuilder` carries and which records
  the revision of the last calendar entry sent for the meeting. A first
  invitation therefore sends `SEQUENCE:0`, identical in meaning to the omitted
  property it replaces. An invitation re-sent for a revision already announced
  once (a booking approved after it was rescheduled back into the gate) sends
  the higher value, so the recipient's calendar supersedes the entry it holds
  instead of weighing two entries of equal revision against their DTSTAMP.
  """
  @spec generate_ics_attachment(map(), String.t(), String.t()) :: Swoosh.Attachment.t()
  def generate_ics_attachment(meeting_details, locale \\ "en", filename \\ "meeting.ics") do
    sequence = Map.get(meeting_details, :ical_sequence) || 0

    build_attachment(meeting_details, :request, sequence, locale, filename)
  end

  @doc """
  Generates an ICS attachment for an event update with the given SEQUENCE number.
  SEQUENCE > 0 signals to calendar clients that this is an update to an existing event.
  """
  @spec generate_ics_update_attachment(map(), non_neg_integer(), String.t(), String.t()) ::
          Swoosh.Attachment.t()
  def generate_ics_update_attachment(
        meeting_details,
        sequence,
        locale \\ "en",
        filename \\ "meeting.ics"
      ) do
    build_attachment(meeting_details, :request, sequence, locale, filename)
  end

  @doc """
  Generates an ICS attachment that cancels an existing event
  (`METHOD:CANCEL` + `STATUS:CANCELLED`).

  CUSTOM PATCH (hostfix7): upstream sends `METHOD:PUBLISH` here; this fork
  sends a real iTIP CANCEL so Outlook/Exchange remove the event from the
  recipient's calendar. See the note on `render_vcalendar/3`.

  The `sequence` should be the next value after the last sent invitation so
  calendar clients recognise the cancellation as more recent than the event
  they already have on file.
  """
  @spec generate_ics_cancel_attachment(map(), non_neg_integer(), String.t(), String.t()) ::
          Swoosh.Attachment.t()
  def generate_ics_cancel_attachment(
        meeting_details,
        sequence,
        locale \\ "en",
        filename \\ "meeting.ics"
      ) do
    build_attachment(meeting_details, :cancel, sequence, locale, filename)
  end

  defp build_attachment(meeting_details, method, sequence, locale, filename) do
    ics_content = generate_ics_with(meeting_details, method, sequence, locale)

    # Bare `text/calendar`, no inline params. Swoosh splits the attachment
    # content_type on "/", so a value like "text/calendar; method=REQUEST"
    # lands the params inside the subtype and the MIME encoder emits an
    # ambiguous Content-Type that strict gateways defer (Proxmox Mail Gateway
    # since PSA-2026-00005-1). The method is carried in the body
    # (METHOD:REQUEST / METHOD:CANCEL) and the part is base64-encoded, so a
    # charset param is moot on the wire.
    %Swoosh.Attachment{
      filename: filename,
      content_type: "text/calendar",
      data: ics_content
    }
  end

  defp generate_ics_with(meeting_details, method, sequence, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details
      |> build_event()
      |> render_vcalendar(method, sequence)
    end)
  end

  defp build_event(meeting_details) do
    %{
      summary: Map.get(meeting_details, :title, dgettext("emails", "Meeting")),
      description: build_ics_description(meeting_details),
      dtstart: dtstart(meeting_details),
      dtend: dtend(meeting_details),
      location: determine_location(meeting_details),
      uid:
        "#{Map.get(meeting_details, :uid, UUID.uuid4())}@#{Application.get_env(:tymeslot, :email)[:domain]}",
      organizer: format_organizer(meeting_details),
      attendee: format_attendees(meeting_details),
      conference: conference_uri(meeting_details),
      status: Map.get(meeting_details, :status, "CONFIRMED")
    }
  end

  # An all-day event has dates and no instants: RFC 5545 §3.3.4 date-only
  # values, with the exclusive end date the iCal convention already uses.
  defp dtstart(%{all_day: true, start_date: %Date{} = start_date}), do: start_date
  defp dtstart(meeting_details), do: meeting_details.start_time

  defp dtend(%{all_day: true, end_date: %Date{} = end_date}), do: end_date
  defp dtend(meeting_details), do: meeting_details.end_time

  defp conference_uri(meeting_details) do
    case Map.get(meeting_details, :meeting_url) do
      url when is_binary(url) and url != "" -> url
      _other -> nil
    end
  end

  # CUSTOM PATCH (hostfix7): this fork sends METHOD:REQUEST for invitations and
  # updates and METHOD:CANCEL for cancellations. Upstream always advertises
  # METHOD:PUBLISH (issue #41: iTIP on the wire makes Zimbra, Nextcloud/Sabre
  # and iCloud Mail auto-import the attachment and emit extra notifications).
  # Here the bookers are on Exchange/Outlook/Gmail and need an actionable
  # invite with Accept/Decline and automatic calendar placement.
  #
  # `SCHEDULE-AGENT=CLIENT` is removed from ORGANIZER/ATTENDEE. ORGANIZER stays
  # the real organiser, so RSVP replies go to them. The ATTENDEE carries
  # PARTSTAT=NEEDS-ACTION;RSVP=TRUE so the client shows the response buttons.
  #
  # `generate_ics/2` (method :none) emits no METHOD line, as before.
  defp render_vcalendar(event, method, sequence) do
    attendee_line = if event.attendee, do: "ATTENDEE#{event.attendee}\n", else: ""
    sequence_line = if is_integer(sequence), do: "SEQUENCE:#{sequence}\n", else: ""
    method_line = method_line(method)
    status = status_for(method, event.status)
    lang = language_param()
    conference_line = build_conference_line(event.conference)

    summary_text = escape_ical_text(event.summary || dgettext("emails", "Meeting"))
    description_text = escape_ical_text(event.description)
    location_text = escape_ical_text(event.location)

    fold_lines("""
    BEGIN:VCALENDAR
    VERSION:2.0
    #{method_line}PRODID:-//Tymeslot//Tymeslot 1.0//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:#{event.uid}
    DTSTAMP:#{format_datetime_utc(DateTime.utc_now())}
    DTSTART#{format_ical_time(event.dtstart)}
    DTEND#{format_ical_time(event.dtend)}
    #{sequence_line}SUMMARY#{tag_language(summary_text, lang)}:#{summary_text}
    DESCRIPTION#{tag_language(description_text, lang)}:#{description_text}
    LOCATION#{tag_language(location_text, lang)}:#{location_text}
    #{conference_line}ORGANIZER#{event.organizer}
    #{attendee_line}STATUS:#{status}
    END:VEVENT
    END:VCALENDAR
    """)
  end

  defp method_line(:request), do: "METHOD:REQUEST\n"
  defp method_line(:cancel), do: "METHOD:CANCEL\n"
  defp method_line(_none), do: ""

  # RFC 7986 §5.11 — `CONFERENCE` advertises an online-meeting access URI so
  # clients can render a native "Join" affordance. We keep `LOCATION` and the
  # description fallback too, for clients that predate RFC 7986. The value is a
  # URI (not text), so it is not text-escaped; we only strip CR/LF to prevent
  # property injection. `LABEL` is a quoted parameter value.
  defp build_conference_line(nil), do: ""

  defp build_conference_line(url) do
    label = dgettext("emails", "Join the video call")

    ~s(CONFERENCE;VALUE=URI;FEATURE=VIDEO;LABEL="#{escape_param_value(label)}":#{sanitize_uri(url)}\n)
  end

  defp escape_param_value(value) do
    value
    |> String.replace(~r/[\r\n]/, " ")
    |> String.replace("\"", "'")
  end

  defp sanitize_uri(url), do: String.replace(url, ~r/[\r\n]/, "")

  # RFC 5545 §3.2.10 — `LANGUAGE` carries the BCP-47 language tag of the
  # property's human-readable text. The configured locale codes ("en", "de",
  # "fr", "it", "uk", "cs", "pl", "pt") are already valid BCP-47 primary subtags. We read the
  # locale active for this render (set by `generate_ics_with/4`) so it cannot
  # drift from the surrounding email translation.
  defp language_param do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    if locale in Locales.supported_codes(), do: ";LANGUAGE=#{locale}", else: ""
  end

  # Only tag properties that actually carry text — an empty SUMMARY/LOCATION
  # has no language to declare.
  defp tag_language("", _lang), do: ""
  defp tag_language(_text, lang), do: lang

  # RFC 5545 §3.1 — content lines must not exceed 75 octets (excluding line
  # terminator). Fold by inserting CRLF + a single SPACE continuation marker.
  # First segment may be up to 75 octets; each continuation segment up to 74
  # octets (the leading SPACE occupies one octet of the 75-octet allowance).
  # We split at UTF-8 character boundaries so multi-byte codepoints are never
  # torn in half.
  defp fold_lines(ical_string) do
    ical_string
    |> String.split("\n")
    |> Enum.map_join("\n", &fold_line/1)
  end

  defp fold_line(line) do
    fold_line_acc(line, _first = true, _acc = [])
  end

  defp fold_line_acc(<<>>, _first, acc), do: acc |> Enum.reverse() |> Enum.join("\r\n ")

  defp fold_line_acc(rest, first, acc) do
    limit = if first, do: 75, else: 74

    {chunk, remaining} = take_octets(rest, limit)
    fold_line_acc(remaining, false, [chunk | acc])
  end

  # Takes up to `max_bytes` octets from `binary`, never splitting a UTF-8
  # multi-byte codepoint. Returns `{taken, rest}`.
  defp take_octets(binary, max_bytes) when byte_size(binary) <= max_bytes do
    {binary, ""}
  end

  defp take_octets(binary, max_bytes) do
    # Walk forward from max_bytes to find a UTF-8 codepoint boundary.
    split_at = safe_utf8_split(binary, max_bytes)
    <<chunk::binary-size(^split_at), rest::binary>> = binary
    {chunk, rest}
  end

  # Returns the largest byte offset ≤ `pos` at which `binary` can be split
  # without tearing a UTF-8 multi-byte sequence. UTF-8 continuation bytes
  # have the bit pattern 10xxxxxx (0x80–0xBF); back up past them to land on
  # a leading byte.
  defp safe_utf8_split(binary, pos) do
    pos = min(pos, byte_size(binary))
    retreat_to_boundary(binary, pos)
  end

  defp retreat_to_boundary(_binary, 0), do: 0

  defp retreat_to_boundary(binary, pos) do
    byte = :binary.at(binary, pos - 1)

    if continuation_byte?(byte) do
      retreat_to_boundary(binary, pos - 1)
    else
      pos
    end
  end

  # UTF-8 continuation bytes: 10xxxxxx
  defp continuation_byte?(byte), do: byte >= 0x80 and byte <= 0xBF

  defp status_for(:cancel, _status), do: "CANCELLED"
  defp status_for(_method, status), do: status

  # CUSTOM PATCH (hostfix7): no SCHEDULE-AGENT=CLIENT. Returns the parameter
  # list plus value, starting with ";" (or ":" when there is no CN), so the
  # caller writes "ORGANIZER" directly in front of it.
  defp format_organizer(meeting_details) do
    organizer_name = Map.get(meeting_details, :organizer_name)

    organizer_email =
      Map.get(
        meeting_details,
        :organizer_email,
        Application.get_env(:tymeslot, :email)[:from_email]
      )

    "#{cn_param(organizer_name)}:mailto:#{organizer_email}"
  end

  # CUSTOM PATCH (hostfix7): actionable attendee. No SCHEDULE-AGENT=CLIENT;
  # PARTSTAT=NEEDS-ACTION and RSVP=TRUE make Outlook/Gmail show Accept/Decline.
  defp format_attendees(meeting_details) do
    attendee_email = Map.get(meeting_details, :attendee_email)

    case attendee_email do
      email when is_binary(email) and email != "" ->
        attendee_name = Map.get(meeting_details, :attendee_name)

        ";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE#{cn_param(attendee_name)}:mailto:#{email}"

      _other ->
        nil
    end
  end

  defp cn_param(name) when is_binary(name) and name != "" do
    quoted_name =
      name
      |> String.replace(~r/[\r\n]/, " ")
      |> String.replace("\"", "'")

    ";CN=\"#{quoted_name}\""
  end

  defp cn_param(_other), do: ""

  defp build_ics_description(meeting_details) do
    parts = [
      Map.get(meeting_details, :description),
      build_organizer_note_section(meeting_details),
      build_attendee_message_section(meeting_details),
      build_video_url_section(meeting_details),
      build_custom_answers_section(meeting_details),
      build_branding_section(meeting_details)
    ]

    parts
    |> Enum.filter(&(&1 && String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  # Credited to the organiser by name, as the attendee's message is to the
  # attendee, so the reader of the guest's copy can tell the two apart.
  defp build_organizer_note_section(meeting_details) do
    case Map.get(meeting_details, :organizer_note) do
      note when is_binary(note) and note != "" ->
        "#{dgettext("emails", "Message from %{name}:", name: meeting_details.organizer_name)}\n#{String.trim(note)}"

      _other ->
        nil
    end
  end

  defp build_attendee_message_section(meeting_details) do
    case Map.get(meeting_details, :attendee_message) do
      message when is_binary(message) and message != "" ->
        attendee_label = Map.get(meeting_details, :attendee_name, dgettext("emails", "attendee"))

        "#{dgettext("emails", "Message from %{name}:", name: attendee_label)}\n#{String.trim(message)}"

      _other ->
        nil
    end
  end

  defp build_video_url_section(meeting_details) do
    case Map.get(meeting_details, :meeting_url) do
      url when is_binary(url) and url != "" ->
        "#{dgettext("emails", "Video meeting:")} #{url}"

      _other ->
        nil
    end
  end

  # The free-tier footer: the description is the one field every calendar
  # client shows, so it is where the event says how it was scheduled. Read the
  # URL first so an instance without one never consults the subscription
  # manager.
  defp build_branding_section(meeting_details) do
    with url when is_binary(url) <- Application.get_env(:tymeslot, :ics_branding_url),
         true <- Subscriptions.show_branding?(Map.get(meeting_details, :organizer_user_id)) do
      dgettext("emails", "Scheduled with %{brand}: %{url}", brand: "Tymeslot", url: url)
    else
      _no_branding -> nil
    end
  end

  defp determine_location(meeting_details) do
    meeting_url = Map.get(meeting_details, :meeting_url)
    location = Map.get(meeting_details, :location)

    cond do
      is_binary(meeting_url) and meeting_url != "" ->
        dgettext("emails", "Video Call")

      is_binary(location) and location != "" ->
        location

      true ->
        ""
    end
  end

  defp build_custom_answers_section(meeting_details) do
    snap = Map.get(meeting_details, :custom_fields_snapshot)
    ans = Map.get(meeting_details, :custom_field_answers, %{})

    case snap do
      list when is_list(list) and list != [] ->
        Enum.map_join(list, "\n", fn d ->
          label = d["label"]
          value = AnswerRenderer.render(d, Map.get(ans || %{}, d["id"]))
          "#{label}: #{value}"
        end)

      _other ->
        nil
    end
  end

  defp escape_ical_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "")
  end

  defp escape_ical_text(nil), do: ""

  defp format_ical_time(%Date{} = date), do: ";VALUE=DATE:#{Calendar.strftime(date, "%Y%m%d")}"
  defp format_ical_time(datetime), do: ":#{format_datetime_utc(datetime)}"

  defp format_datetime_utc(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
