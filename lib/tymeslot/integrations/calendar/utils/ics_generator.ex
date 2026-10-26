defmodule Tymeslot.Integrations.Calendar.IcsGenerator do
  @moduledoc """
  Module for generating ICS (iCalendar) files for meeting appointments.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Locales
  alias Tymeslot.Payments

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
  (`METHOD:PUBLISH` + `STATUS:CANCELLED`). We deliberately avoid
  `METHOD:CANCEL` here — see the note on `render_vcalendar/3`.

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

  # --- CUSTOM PATCH: iTIP request / cancel for booker-facing emails ---------
  #
  # The `generate_ics_*` functions above deliberately publish (`METHOD:PUBLISH`)
  # and tag ORGANIZER/ATTENDEE with `SCHEDULE-AGENT=CLIENT`, so no recipient
  # server acts on the attachment (issue #41). That is right for a download and
  # for the organiser's copy, but it is also why Outlook shows the booker a
  # paperclip instead of Accept/Decline: Outlook only offers the meeting
  # controls for an iTIP request.
  #
  # These two variants are the opt-in exception. They are used by the
  # booker-facing confirmation, reschedule and cancellation emails when
  # `EMAIL_ITIP_INVITES=true`, and by nothing else. Every other caller keeps
  # the publishing functions above, unchanged.
  #
  # Times are UTC with a `Z`, so no VTIMEZONE is needed and no client has to
  # resolve a TZID it may not know.

  @doc """
  The iCalendar body of an iTIP request (`METHOD:REQUEST`): the organiser asks
  the attendee, who is expected to answer (`RSVP=TRUE`).

  Same `UID` and `SEQUENCE` as the publishing variant for the same meeting, so
  a client that saw one supersedes the other rather than adding a second entry.
  """
  @spec generate_ics_request(map(), String.t(), non_neg_integer()) :: String.t()
  def generate_ics_request(meeting_details, locale \\ "en", sequence \\ nil) do
    sequence = sequence || Map.get(meeting_details, :ical_sequence) || 0

    generate_itip_ics(meeting_details, :request, sequence, locale)
  end

  @doc """
  The iCalendar body of an iTIP cancellation (`METHOD:CANCEL`) for the same
  `UID`, at `sequence` — pass the revision *after* the last request sent, so a
  client holding the invitation accepts the cancellation as newer.
  """
  @spec generate_ics_cancel(map(), non_neg_integer(), String.t()) :: String.t()
  def generate_ics_cancel(meeting_details, sequence, locale \\ "en") do
    generate_itip_ics(meeting_details, :cancel, sequence, locale)
  end

  defp generate_itip_ics(meeting_details, method, sequence, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details
      |> build_event()
      |> render_itip_vcalendar(method, sequence)
    end)
  end

  # Same properties and the same line folding as `render_vcalendar/3`; what
  # differs is the method, the scheduling parameters on ORGANIZER/ATTENDEE, and
  # the absence of `SCHEDULE-AGENT=CLIENT`, which would tell the client not to
  # schedule at all.
  defp render_itip_vcalendar(event, method, sequence) do
    lang = language_param()
    summary_text = Format.escape_text(event.summary || dgettext("emails", "Meeting"))
    description_text = Format.escape_text(event.description)
    location_text = Format.escape_text(event.location)

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "METHOD:#{itip_method(method)}",
      "PRODID:-//Tymeslot//Tymeslot 1.0//EN",
      "CALSCALE:GREGORIAN",
      "BEGIN:VEVENT",
      "UID:#{event.uid}",
      "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}",
      "DTSTART#{format_ical_time(event.dtstart)}",
      "DTEND#{format_ical_time(event.dtend)}",
      if(is_integer(sequence), do: "SEQUENCE:#{sequence}"),
      "SUMMARY#{tag_language(summary_text, lang)}:#{summary_text}",
      "DESCRIPTION#{tag_language(description_text, lang)}:#{description_text}",
      "LOCATION#{tag_language(location_text, lang)}:#{location_text}",
      build_conference_line(event.conference),
      "ORGANIZER#{cn_param(event.organizer_name)}:mailto:#{event.organizer_email}",
      itip_attendee_line(event.attendee_email, event.attendee_name),
      "STATUS:#{status_for(method, event.status)}",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> Enum.reject(&is_nil/1)
    |> ContentLines.join()
  end

  defp itip_method(:request), do: "REQUEST"
  defp itip_method(:cancel), do: "CANCEL"

  # RFC 5545 §3.2.16: ROLE, PARTSTAT and RSVP are the parameters a client reads
  # to decide whether to offer Accept/Decline. A cancellation carries the same
  # attendee line as the request it withdraws.
  defp itip_attendee_line(email, name) when is_binary(email) and email != "" do
    "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE#{cn_param(name)}:" <>
      "mailto:#{Format.sanitize_ical_value(email)}"
  end

  defp itip_attendee_line(_email, _name), do: nil

  defp build_attachment(meeting_details, method, sequence, locale, filename) do
    ics_content = generate_ics_with(meeting_details, method, sequence, locale)

    # Bare `text/calendar`, no inline params. Swoosh splits the attachment
    # content_type on "/", so a value like "text/calendar; method=PUBLISH"
    # lands the params inside the subtype and the MIME encoder emits an
    # ambiguous Content-Type that strict gateways defer (Proxmox Mail Gateway
    # since PSA-2026-00005-1). The method is already carried in the body
    # (METHOD:PUBLISH) and the part is base64-encoded, so a charset param is
    # moot on the wire.
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
      organizer_name: Map.get(meeting_details, :organizer_name),
      organizer_email:
        Map.get(
          meeting_details,
          :organizer_email,
          Application.get_env(:tymeslot, :email)[:from_email]
        ),
      attendee: format_attendees(meeting_details),
      attendee_name: Map.get(meeting_details, :attendee_name),
      attendee_email: Map.get(meeting_details, :attendee_email),
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

  # Tymeslot emails always advertise METHOD:PUBLISH (not REQUEST/CANCEL). The
  # organiser's calendar is already updated via the CalDAV/OAuth write path and
  # attendee RSVP is handled by booking URLs in the email body — iTIP on the
  # wire would cause recipient-side mail servers (Zimbra, Nextcloud/Sabre,
  # Apple iCloud Mail) to auto-import the attachment and emit extra
  # notifications. See issue #41.
  #
  # `SCHEDULE-AGENT=CLIENT` on ORGANIZER/ATTENDEE is defence-in-depth per
  # RFC 6638 §7.1 for the same reason.
  #
  # The document is built as content lines and written through
  # `ContentLines.join/1`, as the CalDAV writer's is: CRLF line endings and
  # folding to 75 octets (RFC 5545 §3.1).
  defp render_vcalendar(event, method, sequence) do
    lang = language_param()
    summary_text = Format.escape_text(event.summary || dgettext("emails", "Meeting"))
    description_text = Format.escape_text(event.description)
    location_text = Format.escape_text(event.location)

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      if(method != :none, do: "METHOD:PUBLISH"),
      "PRODID:-//Tymeslot//Tymeslot 1.0//EN",
      "CALSCALE:GREGORIAN",
      "BEGIN:VEVENT",
      "UID:#{event.uid}",
      "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}",
      "DTSTART#{format_ical_time(event.dtstart)}",
      "DTEND#{format_ical_time(event.dtend)}",
      if(is_integer(sequence), do: "SEQUENCE:#{sequence}"),
      "SUMMARY#{tag_language(summary_text, lang)}:#{summary_text}",
      "DESCRIPTION#{tag_language(description_text, lang)}:#{description_text}",
      "LOCATION#{tag_language(location_text, lang)}:#{location_text}",
      build_conference_line(event.conference),
      "ORGANIZER;#{event.organizer}",
      event.attendee && "ATTENDEE;#{event.attendee}",
      "STATUS:#{status_for(method, event.status)}",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> Enum.reject(&is_nil/1)
    |> ContentLines.join()
  end

  # RFC 7986 §5.11 — `CONFERENCE` advertises an online-meeting access URI so
  # clients can render a native "Join" affordance. We keep `LOCATION` and the
  # description fallback too, for clients that predate RFC 7986. The value is a
  # URI (not text), so it is not text-escaped; we only strip CR/LF to prevent
  # property injection. `LABEL` is a quoted parameter value.
  defp build_conference_line(nil), do: nil

  defp build_conference_line(url) do
    label = dgettext("emails", "Join the video call")

    ~s(CONFERENCE;VALUE=URI;FEATURE=VIDEO;LABEL="#{escape_param_value(label)}":#{Format.sanitize_ical_value(url)})
  end

  defp escape_param_value(value) do
    value
    |> String.replace(~r/[\r\n]/, " ")
    |> String.replace("\"", "'")
  end

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

  defp status_for(:cancel, _status), do: "CANCELLED"
  defp status_for(_method, status), do: status

  defp format_organizer(meeting_details) do
    organizer_name = Map.get(meeting_details, :organizer_name)

    organizer_email =
      Map.get(
        meeting_details,
        :organizer_email,
        Application.get_env(:tymeslot, :email)[:from_email]
      )

    "SCHEDULE-AGENT=CLIENT#{cn_param(organizer_name)}:mailto:" <>
      Format.sanitize_ical_value(organizer_email)
  end

  defp format_attendees(meeting_details) do
    attendee_email = Map.get(meeting_details, :attendee_email)

    case attendee_email do
      email when is_binary(email) and email != "" ->
        attendee_name = Map.get(meeting_details, :attendee_name)

        "SCHEDULE-AGENT=CLIENT#{cn_param(attendee_name)}:mailto:" <>
          Format.sanitize_ical_value(email)

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
         true <- Payments.show_branding?(Map.get(meeting_details, :organizer_user_id)) do
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

  defp format_ical_time(%Date{} = date), do: ";VALUE=DATE:#{Calendar.strftime(date, "%Y%m%d")}"

  defp format_ical_time(datetime),
    do: ":" <> Format.format_datetime(DateTime.shift_zone!(datetime, "Etc/UTC"))
end
