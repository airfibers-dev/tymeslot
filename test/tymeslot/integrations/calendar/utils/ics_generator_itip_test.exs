defmodule Tymeslot.Integrations.Calendar.Utils.IcsGeneratorITipTest do
  @moduledoc """
  The opt-in iTIP variants of `IcsGenerator`: `generate_ics_request/3` and
  `generate_ics_cancel/3`. They are what the booker-facing emails carry when
  `EMAIL_ITIP_INVITES=true`; the publishing functions they sit beside are
  covered by `ics_generator_test.exs` and must keep their behaviour.
  """

  use ExUnit.Case, async: true
  @moduletag :emails

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  # The generator appends the configured email domain to the meeting's uid
  # (`IcsGenerator` `build_event/2`), and `config/test.exs` sets that domain to
  # `tymeslot.app`. The same uid must come out of every variant, or a client
  # treats a reschedule or a cancellation as a different meeting.
  @uid "itip-uid-123@tymeslot.app"

  @details %{
    title: "Discovery Call",
    summary: "Discovery Call",
    description: "A first conversation",
    start_time: ~U[2026-01-15 14:00:00Z],
    end_time: ~U[2026-01-15 15:00:00Z],
    uid: "itip-uid-123",
    organizer_name: "John Organizer",
    organizer_email: "organizer@example.com",
    attendee_name: "Jane Attendee",
    attendee_email: "jane@example.com",
    location: "Video Call",
    ical_sequence: 2
  }

  describe "generate_ics_request/3" do
    test "is an iTIP request: METHOD:REQUEST, STATUS:CONFIRMED, the meeting's SEQUENCE" do
      ics = IcsGenerator.generate_ics_request(@details)

      assert ics =~ "BEGIN:VCALENDAR\r\n"
      assert ics =~ "METHOD:REQUEST\r\n"
      assert ics =~ "STATUS:CONFIRMED\r\n"
      assert ics =~ "SEQUENCE:2\r\n"
      assert ics =~ "UID:#{@uid}\r\n"
      refute ics =~ "METHOD:PUBLISH"
    end

    test "asks the attendee to answer, with the parameters Outlook reads" do
      # The property is folded at 75 octets, so it is read back as a logical
      # content line; that folding still happens is asserted separately below.
      attendee =
        IcsGenerator.generate_ics_request(@details)
        |> ContentLines.split()
        |> ContentLines.find("ATTENDEE")

      assert attendee ==
               "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;" <>
                 "CN=\"Jane Attendee\":mailto:jane@example.com"
    end

    test "folds long content lines at 75 octets, with continuation lines" do
      ics = IcsGenerator.generate_ics_request(@details)

      assert ics =~ "\r\n "
      assert Enum.all?(String.split(ics, "\r\n"), &(byte_size(&1) <= 75))
    end

    test "organizer is not told to skip scheduling" do
      ics = IcsGenerator.generate_ics_request(@details)

      assert ics =~ "ORGANIZER;CN=\"John Organizer\":mailto:organizer@example.com"
      refute ics =~ "SCHEDULE-AGENT"
    end

    test "times are UTC with a Z, so no VTIMEZONE is needed" do
      ics = IcsGenerator.generate_ics_request(@details)

      assert ics =~ "DTSTART:20260115T140000Z\r\n"
      assert ics =~ "DTEND:20260115T150000Z\r\n"
      refute ics =~ "VTIMEZONE"
      refute ics =~ "TZID"
    end

    test "carries the location, tagged with its language" do
      location =
        IcsGenerator.generate_ics_request(@details)
        |> ContentLines.split()
        |> ContentLines.find("LOCATION")

      assert location == "LOCATION;LANGUAGE=en:Video Call"
    end

    test "an explicit sequence wins over the one on the meeting" do
      ics = IcsGenerator.generate_ics_request(@details, "en", 7)

      assert ics =~ "SEQUENCE:7\r\n"
    end

    test "a meeting without a sequence starts at 0" do
      ics = IcsGenerator.generate_ics_request(Map.delete(@details, :ical_sequence))

      assert ics =~ "SEQUENCE:0\r\n"
    end
  end

  describe "generate_ics_cancel/3" do
    test "is a cancellation of the same UID at the bumped sequence" do
      ics = IcsGenerator.generate_ics_cancel(@details, 3)

      assert ics =~ "METHOD:CANCEL\r\n"
      assert ics =~ "STATUS:CANCELLED\r\n"
      assert ics =~ "UID:#{@uid}\r\n"
      assert ics =~ "SEQUENCE:3\r\n"
      refute ics =~ "METHOD:PUBLISH"
    end

    test "keeps the attendee line of the request it withdraws" do
      attendee =
        IcsGenerator.generate_ics_cancel(@details, 3)
        |> ContentLines.split()
        |> ContentLines.find("ATTENDEE")

      assert attendee ==
               "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;" <>
                 "CN=\"Jane Attendee\":mailto:jane@example.com"

      refute IcsGenerator.generate_ics_cancel(@details, 3) =~ "SCHEDULE-AGENT"
    end

    test "shares the UID and times of the request, so a client matches the entry" do
      request = IcsGenerator.generate_ics_request(@details)
      cancel = IcsGenerator.generate_ics_cancel(@details, 3)

      assert request =~ "UID:#{@uid}\r\n"
      assert cancel =~ "UID:#{@uid}\r\n"
      assert cancel =~ "DTSTART:20260115T140000Z\r\n"
    end
  end

  describe "the UID across a meeting's whole life" do
    # A confirmation, a reschedule (an update at a bumped sequence) and a
    # cancellation are three messages about one entry: if the UID moved, the
    # client would add a second event instead of changing the first.
    test "request, update and cancellation all carry the same UID" do
      request = IcsGenerator.generate_ics_request(@details, "en", 2)
      update = IcsGenerator.generate_ics_request(@details, "en", 3)
      cancel = IcsGenerator.generate_ics_cancel(@details, 4)

      uids =
        [request, update, cancel]
        |> Enum.map(fn ics ->
          ics |> ContentLines.split() |> ContentLines.find("UID")
        end)

      assert uids == ["UID:#{@uid}", "UID:#{@uid}", "UID:#{@uid}"]

      assert update =~ "SEQUENCE:3\r\n"
      assert cancel =~ "SEQUENCE:4\r\n"
    end
  end

  describe "the publishing variants are untouched" do
    test "generate_ics_attachment still publishes" do
      attachment = IcsGenerator.generate_ics_attachment(@details)

      assert attachment.data =~ "METHOD:PUBLISH"
      assert attachment.data =~ "SCHEDULE-AGENT=CLIENT"
      refute attachment.data =~ "METHOD:REQUEST"
    end

    test "generate_ics_cancel_attachment still publishes a cancelled status" do
      attachment = IcsGenerator.generate_ics_cancel_attachment(@details, 3)

      assert attachment.data =~ "METHOD:PUBLISH"
      assert attachment.data =~ "STATUS:CANCELLED"
      refute attachment.data =~ "METHOD:CANCEL"
    end
  end
end
