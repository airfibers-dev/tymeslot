defmodule Tymeslot.Integrations.Calendar.Utils.IcsGeneratorITipTest do
  @moduledoc """
  The opt-in iTIP variants of `IcsGenerator`: `generate_ics_request/3` and
  `generate_ics_cancel/3`. They are what the booker-facing emails carry when
  `EMAIL_ITIP_INVITES=true`; the publishing functions they sit beside are
  covered by `ics_generator_test.exs` and must keep their behaviour.
  """

  use ExUnit.Case, async: true
  @moduletag :emails

  alias Tymeslot.Integrations.Calendar.IcsGenerator

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
      assert ics =~ "UID:itip-uid-123\r\n"
      refute ics =~ "METHOD:PUBLISH"
    end

    test "asks the attendee to answer, with the parameters Outlook reads" do
      ics = IcsGenerator.generate_ics_request(@details)

      assert ics =~
               "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;" <>
                 "CN=\"Jane Attendee\":mailto:jane@example.com"
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

    test "carries the location" do
      assert IcsGenerator.generate_ics_request(@details) =~ "LOCATION:Video Call\r\n"
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
      assert ics =~ "UID:itip-uid-123\r\n"
      assert ics =~ "SEQUENCE:3\r\n"
      refute ics =~ "METHOD:PUBLISH"
    end

    test "keeps the attendee line of the request it withdraws" do
      ics = IcsGenerator.generate_ics_cancel(@details, 3)

      assert ics =~ "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE"
      refute ics =~ "SCHEDULE-AGENT"
    end

    test "shares the UID and times of the request, so a client matches the entry" do
      request = IcsGenerator.generate_ics_request(@details)
      cancel = IcsGenerator.generate_ics_cancel(@details, 3)

      assert request =~ "UID:itip-uid-123\r\n"
      assert cancel =~ "UID:itip-uid-123\r\n"
      assert cancel =~ "DTSTART:20260115T140000Z\r\n"
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
